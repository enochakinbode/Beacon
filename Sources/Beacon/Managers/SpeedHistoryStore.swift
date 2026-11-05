import Foundation

/// Per-app time-series of (download, upload) speed for the app chart, which
/// shows today only: per-minute averages, last 24 hours (1440 buckets),
/// persisted to disk. Nothing older than a day is kept. (Earlier builds also
/// kept a 1 Hz in-memory tier and a 30-day per-hour tier; an old file's `hour`
/// key is ignored and dropped on the next save.)
final class SpeedHistoryStore {
    static let shared = SpeedHistoryStore()

    /// `down` / `up` are all-traffic speeds; `netDown` / `netUp` the
    /// internet-only slice. `series(forId:scope:)` returns samples whose
    /// `down` / `up` already hold the requested scope's values, so chart code
    /// never has to pick.
    struct Sample: Equatable {
        let t: Date
        let down: Double
        let up: Double
        var netDown: Double = 0
        var netUp: Double = 0

        func scoped(_ scope: TrafficScope) -> Sample {
            scope == .internet
                ? Sample(t: t, down: netDown, up: netUp, netDown: netDown, netUp: netUp)
                : self
        }
    }

    // MARK: - Buckets

    /// Averaged bucket: sum + count so we can compute the mean speed over the
    /// bucket's window. `internal` (not `private`) so the pure append logic can be
    /// unit-tested via `@testable import`.
    struct Bucket: Codable {
        let start: Date
        var downSum: Double
        var upSum: Double
        var count: Int
        /// Internet-only sums. Absent from files written before the internet
        /// split; those buckets decode as 0 (see `init(from:)` below).
        var netDownSum: Double = 0
        var netUpSum: Double = 0
        var downAvg: Double { count > 0 ? downSum / Double(count) : 0 }
        var upAvg: Double { count > 0 ? upSum / Double(count) : 0 }
        var netDownAvg: Double { count > 0 ? netDownSum / Double(count) : 0 }
        var netUpAvg: Double { count > 0 ? netUpSum / Double(count) : 0 }

        var sample: Sample {
            Sample(t: start, down: downAvg, up: upAvg, netDown: netDownAvg, netUp: netUpAvg)
        }
    }

    private var minute: [String: [Bucket]] = [:]
    private let minuteCap = 1440     // 24 h × 60

    private let secondsPerMinute: TimeInterval = 60
    private let oneDay: TimeInterval = 24 * 3600

    // MARK: - Persistence

    /// Concurrent with barrier writes. The chart panels call `series()` from the
    /// main thread every tick; on a serial queue those reads serialized behind
    /// the 1 Hz ingest AND the periodic full-store JSON encode, so an open chart
    /// could stall the main thread for the duration of an encode. Reads now run
    /// concurrently and only mutation takes the barrier — and the encode itself
    /// happens OFF this queue entirely (see the autosave handler), so a reader
    /// can never queue behind it.
    private let queue = DispatchQueue(label: "computer.lighthouse.beacon.speedhistory", qos: .utility, attributes: .concurrent)
    /// Where the JSON encode + disk write run, so they never occupy `queue` (and
    /// thus never make a main-thread `series()` read wait behind them).
    private let encodeQueue = DispatchQueue(label: "computer.lighthouse.beacon.speedhistory-encode", qos: .utility)
    private let storeURL: URL
    /// Mutation counter (bumped under the barrier) vs the generation last flushed
    /// to disk. Replaces a `dirty` flag so a save that races a concurrent ingest
    /// can't mark the newer, unflushed mutation as saved.
    private var generation: UInt64 = 0
    private var savedGeneration: UInt64 = 0
    private var saveTimer: DispatchSourceTimer?

    private struct Persisted: Codable {
        var minute: [String: [Bucket]]
    }

    private init() {
        let support = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )) ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = support.appendingPathComponent("Beacon", isDirectory: true)
        // See LifetimeUsageStore: one-time migration of the pre-rebrand
        // "NetworkUsageMonitor" folder so history survives the rename.
        let legacyDir = support.appendingPathComponent("NetworkUsageMonitor", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path),
           FileManager.default.fileExists(atPath: legacyDir.path) {
            try? FileManager.default.moveItem(at: legacyDir, to: dir)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.storeURL = dir.appendingPathComponent("speed-history.json")
        load()
        startAutosaveTimer()
    }

    // MARK: - Ingest

    /// Feed one snapshot of per-app usages. Called once per tick (~1 Hz) from
    /// the view model immediately after `ProcessTracker` aggregation.
    func ingest(_ apps: [AppNetworkUsage]) {
        let now = Date()
        let minuteStart = floor(now, to: secondsPerMinute)
        // Fold window = 2× the bucket width: a backward clock step smaller than
        // this folds losslessly into the current bucket; a larger one rebases so
        // the chart can't freeze. Computed here, outside the async body, so the
        // tier constant doesn't need `self.` inside.
        let minuteFold = 2 * secondsPerMinute
        queue.async(flags: .barrier) {
            for app in apps {
                self.accumulate(
                    into: &self.minute, id: app.id, bucketStart: minuteStart,
                    down: app.downloadSpeed, up: app.uploadSpeed,
                    netDown: app.internetDownloadSpeed, netUp: app.internetUploadSpeed,
                    cap: self.minuteCap,
                    foldWindow: minuteFold
                )
            }
            self.generation &+= 1
        }
    }

    private func accumulate(
        into store: inout [String: [Bucket]],
        id: String, bucketStart: Date,
        down: Double, up: Double, netDown: Double, netUp: Double,
        cap: Int, foldWindow: TimeInterval
    ) {
        store[id] = Self.appendingSample(store[id] ?? [], bucketStart: bucketStart,
                                         down: down, up: up, netDown: netDown, netUp: netUp,
                                         cap: cap, foldWindow: foldWindow)
    }

    /// Pure, testable bucket append. Folds one sample into `bucketStart`'s bucket
    /// and trims to `cap`. Keeps the array's `start` values **monotonically
    /// non-decreasing** even when the wall clock steps backward (NTP correction /
    /// manual set / VM clock jump).
    ///
    /// Why this matters: the old `==` check appended a brand-new bucket whenever
    /// `bucketStart != last.start`, so a backward step inserted an out-of-order
    /// (older) bucket at the tail. That breaks the graph's monotonic time axis and,
    /// worse, makes the `count > cap` trim `removeFirst` evict the *front* (which
    /// is no longer the oldest), silently dropping good history.
    ///
    /// Two backward regimes, split at `foldWindow`:
    /// * **Small step** (NTP jitter, ≤ `foldWindow` behind the tail): fold into
    ///   the most recent bucket — lossless, no axis disturbance.
    /// * **Large step** (manual clock change / VM restore): folding would freeze
    ///   the series — every sample lands in that one tail bucket until the clock
    ///   re-passes its start (an hour-long "frozen chart" for an hour's step). So
    ///   instead REBASE: drop buckets whose start is now in the future (per the
    ///   new clock those timestamps haven't happened yet) and resume recording at
    ///   `bucketStart`. The axis stays monotonic and the chart keeps moving.
    static func appendingSample(
        _ arr: [Bucket], bucketStart: Date, down: Double, up: Double,
        netDown: Double = 0, netUp: Double = 0, cap: Int,
        foldWindow: TimeInterval = 120
    ) -> [Bucket] {
        var arr = arr
        func fold(_ b: inout Bucket) {
            b.downSum += down
            b.upSum += up
            b.netDownSum += netDown
            b.netUpSum += netUp
            b.count += 1
        }
        let fresh = Bucket(start: bucketStart, downSum: down, upSum: up, count: 1,
                           netDownSum: netDown, netUpSum: netUp)
        if var last = arr.last, last.start >= bucketStart {
            if last.start.timeIntervalSince(bucketStart) <= foldWindow {
                fold(&last)
                arr[arr.count - 1] = last
            } else {
                // Large backward step — rebase onto the new clock.
                arr.removeAll { $0.start > bucketStart }
                if var tail = arr.last, tail.start == bucketStart {
                    fold(&tail)
                    arr[arr.count - 1] = tail
                } else {
                    arr.append(fresh)
                }
            }
        } else {
            arr.append(fresh)
        }
        if arr.count > cap { arr.removeFirst(arr.count - cap) }
        return arr
    }

    private func floor(_ date: Date, to seconds: TimeInterval) -> Date {
        let t = date.timeIntervalSince1970
        return Date(timeIntervalSince1970: (t / seconds).rounded(.down) * seconds)
    }

    // MARK: - Query

    /// Today's per-minute series for one app (since local midnight), with
    /// `down` / `up` holding `scope`'s speeds (see `Sample.scoped`). Empty if
    /// we have no data for that id today yet.
    func series(forId id: String, scope: TrafficScope = .all, now: Date = Date()) -> [Sample] {
        let cutoff = Calendar.current.startOfDay(for: now)
        let samples: [Sample] = queue.sync {
            (minute[id] ?? []).filter { $0.start >= cutoff }.map(\.sample)
        }
        return scope == .all ? samples : samples.map { $0.scoped(scope) }
    }

    // MARK: - Persistence impl

    private func load() {
        guard let data = try? Data(contentsOf: storeURL) else { return }
        guard let decoded = try? JSONDecoder().decode(Persisted.self, from: data) else {
            // File exists but didn't decode — corrupt/truncated. Move it aside
            // so the next save doesn't silently overwrite recoverable history
            // with an empty store. History is non-critical, but a `.corrupt`
            // copy aids diagnosis and avoids a quiet data loss.
            let backup = storeURL.appendingPathExtension("corrupt")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: storeURL, to: backup)
            return
        }
        // Drop anything already past its retention window (e.g. the app was
        // closed for a week) so we don't show stale gaps.
        let now = Date()
        minute = decoded.minute.mapValues { $0.filter { now.timeIntervalSince($0.start) <= self.oneDay } }
        pruneEmptyAndDeadApps(now: now)
    }

    private func startAutosaveTimer() {
        let timer = DispatchSource.makeTimerSource(queue: encodeQueue)
        timer.schedule(deadline: .now() + 60, repeating: 60)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            // Snapshot under the barrier (a COW dictionary copy — microseconds),
            // then encode + write on encodeQueue so the store stays readable for
            // the whole duration of the encode.
            var payload: Persisted?
            var gen: UInt64 = 0
            self.queue.sync(flags: .barrier) {
                guard self.generation != self.savedGeneration else { return }
                self.pruneEmptyAndDeadApps(now: Date())
                payload = Persisted(minute: self.minute)
                gen = self.generation
            }
            guard let snapshot = payload else { return }
            // Already on encodeQueue (the timer's target) — encode inline.
            self.write(snapshot, upTo: gen, synchronously: true)
        }
        saveTimer = timer
        timer.resume()
    }

    /// Eviction: apps whose newest minute bucket is over 24h old (or that
    /// have none) are dropped. Nothing outlives a day.
    private func pruneEmptyAndDeadApps(now: Date) {
        for (id, arr) in minute {
            if let last = arr.last, now.timeIntervalSince(last.start) <= oneDay { continue }
            minute[id] = nil
        }
    }

    /// Synchronous flush — blocks the caller until the encode + atomic write
    /// completes. Used on app quit: an async save would still be queued when
    /// `terminate()` runs, losing the last window of history (mirrors
    /// `LifetimeUsageStore.saveBlocking`).
    func saveBlocking() {
        var payload: Persisted?
        var gen: UInt64 = 0
        queue.sync(flags: .barrier) {
            guard generation != savedGeneration else { return }
            payload = Persisted(minute: minute)
            gen = generation
        }
        guard let snapshot = payload else { return }
        write(snapshot, upTo: gen, synchronously: true)
    }

    /// Encode + atomically write `snapshot`, then mark everything up to `gen` as
    /// flushed. Only advances `savedGeneration` on a *successful* write so a
    /// failed flush (disk full, sandbox hiccup) is retried on the next autosave
    /// instead of silently dropping that window's history — mirrors the
    /// deliberately-correct retry contract in LifetimeUsageStore. Runs on
    /// `encodeQueue` (or the caller's thread on the quit path) — never on `queue`,
    /// so readers can't stall behind the encode.
    private func write(_ snapshot: Persisted, upTo gen: UInt64, synchronously: Bool = false) {
        let work = { [weak self] in
            guard let self = self else { return }
            do {
                let data = try JSONEncoder().encode(snapshot)
                try data.write(to: self.storeURL, options: .atomic)
                self.queue.async(flags: .barrier) {
                    self.savedGeneration = max(self.savedGeneration, gen)
                }
            } catch {
                // Non-fatal — savedGeneration stays behind so the next autosave retries.
            }
        }
        if synchronously { work() } else { encodeQueue.async(execute: work) }
    }

    deinit {
        saveTimer?.cancel()
    }
}

extension SpeedHistoryStore.Bucket {
    /// Hand-written (in an extension, so the memberwise init survives) only to
    /// tolerate the internet sums being absent from pre-split history files.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        start = try c.decode(Date.self, forKey: .start)
        downSum = try c.decode(Double.self, forKey: .downSum)
        upSum = try c.decode(Double.self, forKey: .upSum)
        count = try c.decode(Int.self, forKey: .count)
        netDownSum = try c.decodeIfPresent(Double.self, forKey: .netDownSum) ?? 0
        netUpSum = try c.decodeIfPresent(Double.self, forKey: .netUpSum) ?? 0
    }
}
