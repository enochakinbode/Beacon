import Foundation

/// Internet bytes moved on one local calendar day, across every process.
struct DayUsage: Codable, Equatable {
    /// Local-calendar day key, `yyyy-MM-dd`.
    let day: String
    var internetBytesIn: UInt64
    var internetBytesOut: UInt64

    var internetBytes: UInt64 { saturatingAdd(internetBytesIn, internetBytesOut) }
}

/// Per-day internet totals — what the menu-bar title shows ("today").
///
/// Fed once per tick with `ProcessTracker.lastTickInternetBytes`, i.e. every
/// process's internet traffic, hidden apps included: this is the machine's
/// real internet usage, not a view of the list. Rolls over at local midnight
/// on the first tick of the new day.
///
/// Main-thread confined (ingest runs from the snapshot callback on main). The
/// whole table is a few dozen rows, so encoding is trivial; only the disk write
/// is pushed off main. Persisted to `daily-usage.json` every 30 s when dirty and
/// on quit; keeps the last `retainedDays` days.
///
/// Same limitation as `LifetimeUsageStore`: bytes moved while Beacon isn't
/// running are never seen, so "today" covers only the time it was running.
final class DailyUsageStore {
    static let shared: DailyUsageStore = {
        // Touch the lifetime store first: its init performs the one-time
        // NetworkUsageMonitor → Beacon folder migration, which only runs while
        // `Beacon/` doesn't exist yet. Creating the folder here first would
        // orphan a pre-rebrand user's history.
        _ = LifetimeUsageStore.shared
        let support = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )) ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = support.appendingPathComponent("Beacon", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return DailyUsageStore(storeURL: dir.appendingPathComponent("daily-usage.json"))
    }()

    private(set) var today: DayUsage
    /// Previous days, oldest first. Excludes `today`.
    private(set) var history: [DayUsage] = []

    private let storeURL: URL
    private let calendar: Calendar
    private let retainedDays = 90
    private var dirty = false
    private var saveTimer: Timer?
    private let writeQueue = DispatchQueue(label: "computer.lighthouse.beacon.daily", qos: .utility)

    private static let currentSchema = 1

    init(storeURL: URL, calendar: Calendar = .current, now: Date = Date(), autosave: Bool = true) {
        self.storeURL = storeURL
        self.calendar = calendar
        self.today = DayUsage(day: Self.dayKey(for: now, calendar: calendar),
                              internetBytesIn: 0, internetBytesOut: 0)
        load(now: now)
        if autosave {
            // Main run loop; 30 s with generous tolerance so it coalesces with
            // other wakeups and stays invisible in the idle-CPU budget.
            let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in self?.saveIfDirty() }
            timer.tolerance = 10
            RunLoop.main.add(timer, forMode: .common)
            saveTimer = timer
        }
    }

    deinit { saveTimer?.invalidate() }

    // MARK: - Ingest

    /// Add one tick's internet bytes. Rolls `today` into `history` first if the
    /// local date changed since the last tick.
    func ingest(internetIn: UInt64, internetOut: UInt64, now: Date = Date()) {
        rollOverIfNeeded(now: now)
        guard internetIn > 0 || internetOut > 0 else { return }
        today.internetBytesIn = saturatingAdd(today.internetBytesIn, internetIn)
        today.internetBytesOut = saturatingAdd(today.internetBytesOut, internetOut)
        dirty = true
    }

    /// Clear every day, including today. Paired with "Reset All-Time Data".
    func resetAll(now: Date = Date()) {
        today = DayUsage(day: Self.dayKey(for: now, calendar: calendar), internetBytesIn: 0, internetBytesOut: 0)
        history.removeAll()
        dirty = true
        saveIfDirty()
    }

    private func rollOverIfNeeded(now: Date) {
        let key = Self.dayKey(for: now, calendar: calendar)
        guard key != today.day else { return }
        if today.internetBytes > 0 { history.append(today) }
        if history.count > retainedDays { history.removeFirst(history.count - retainedDays) }
        today = DayUsage(day: key, internetBytesIn: 0, internetBytesOut: 0)
        dirty = true
    }

    static func dayKey(for date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    // MARK: - Persistence

    private struct PersistedWrapper: Codable {
        let schema: Int
        let days: [DayUsage]
    }

    private func load(now: Date) {
        guard let data = try? Data(contentsOf: storeURL) else { return }
        guard let wrapped = try? JSONDecoder().decode(PersistedWrapper.self, from: data) else {
            // Corrupt / truncated: move aside rather than overwrite on next save.
            let backup = storeURL.appendingPathExtension("corrupt")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: storeURL, to: backup)
            return
        }
        var days = wrapped.days.sorted { $0.day < $1.day }
        if let last = days.last, last.day == today.day {
            today = last
            days.removeLast()
        }
        history = Array(days.suffix(retainedDays))
    }

    private func encoded() -> Data? {
        let days = history + (today.internetBytes > 0 || !history.isEmpty ? [today] : [])
        return try? JSONEncoder().encode(PersistedWrapper(schema: Self.currentSchema, days: days))
    }

    private func saveIfDirty() {
        guard dirty, let data = encoded() else { return }
        dirty = false
        let url = storeURL
        writeQueue.async { [weak self] in
            do { try data.write(to: url, options: .atomic) }
            catch { DispatchQueue.main.async { [weak self] in self?.dirty = true } }
        }
    }

    /// Synchronous flush for app quit. Main thread.
    func saveBlocking() {
        guard let data = encoded() else { return }
        writeQueue.sync {
            if (try? data.write(to: storeURL, options: .atomic)) != nil { dirty = false }
        }
    }
}
