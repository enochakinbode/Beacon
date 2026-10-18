import XCTest
@testable import Beacon

final class TrafficClassifierTests: XCTestCase {
    private func local(_ remote: String, iface: String = "en0",
                       localIP: String = "192.168.1.20", localPort: UInt16 = 50000) -> Bool {
        TrafficClassifier.isLocal(interface: iface, localIP: localIP, localPort: localPort, remoteIP: remote)
    }

    func test_publicRemotes_areInternet() {
        XCTAssertFalse(local("17.57.146.182"))
        XCTAssertFalse(local("8.8.8.8"))
        XCTAssertFalse(local("172.32.0.1"), "just outside 172.16/12")
        XCTAssertFalse(local("100.128.0.1"), "just outside 100.64/10")
        XCTAssertFalse(local("2606:4700:4700::1111"))
        XCTAssertFalse(local("::ffff:8.8.8.8"))
    }

    func test_privateAndSpecialRemotes_areLocal() {
        for ip in ["127.0.0.1", "10.1.2.3", "172.20.10.1", "192.168.0.1",
                   "169.254.1.1", "100.100.1.1", "224.0.0.251", "255.255.255.255",
                   "::1", "fe80::1%lo0", "fe80::f8c1:8bff:fe2f:c21%awdl0",
                   "fd7a:115c:a1e0::1", "ff02::fb", "::ffff:192.168.1.1"] {
            XCTAssertTrue(local(ip), ip)
        }
    }

    func test_localInterfaces_areLocalRegardlessOfRemote() {
        XCTAssertTrue(local("8.8.8.8", iface: "lo0"))
        XCTAssertTrue(local("8.8.8.8", iface: "awdl0"))
        XCTAssertTrue(local("8.8.8.8", iface: "llw0"))
        XCTAssertTrue(local("8.8.8.8", iface: "bridge100"))
        XCTAssertFalse(local("8.8.8.8", iface: "utun3"))
        XCTAssertFalse(local("8.8.8.8", iface: ""))
    }

    func test_wildcardRemote_usesLocalSideAndDiscoveryPorts() {
        XCTAssertTrue(local("*", localIP: "*", localPort: 5353), "mDNS")
        XCTAssertTrue(local("*", localIP: "*", localPort: 1900), "SSDP")
        XCTAssertTrue(local("*", localIP: "127.0.0.1", localPort: 8080))
        XCTAssertFalse(local("*", localIP: "*", localPort: 3722), "unknown → internet")
    }

    func test_garbage_isInternet() {
        XCTAssertFalse(TrafficClassifier.isLocalAddress("not-an-ip"))
    }
}

final class InternetSplitTests: XCTestCase {
    /// One PID moving bytes over an internet flow and a loopback flow: the
    /// internet slice is the process delta minus the loopback flow's delta.
    func test_processDeltaMinusLocalFlows() {
        let tracker = ProcessTracker()
        let t0 = Date(), t1 = t0.addingTimeInterval(1)
        func conn(_ remote: String, _ iface: String, _ lport: UInt16, _ i: UInt64, _ o: UInt64) -> ConnectionSample {
            ConnectionSample(pid: 7, proto: "tcp4", localIP: "192.168.1.5", localPort: lport,
                             remoteIP: remote, remotePort: 443, bytesIn: i, bytesOut: o, interface: iface)
        }
        _ = tracker.ingest(snapshot: [ProcessSample(pid: 7, processName: "App", bytesIn: 0, bytesOut: 0)],
                           connections: [conn("8.8.8.8", "en0", 1, 0, 0), conn("127.0.0.1", "lo0", 2, 0, 0)],
                           snapshotTime: t0)
        let usages = tracker.ingest(
            snapshot: [ProcessSample(pid: 7, processName: "App", bytesIn: 10_000, bytesOut: 1_000)],
            connections: [conn("8.8.8.8", "en0", 1, 4_000, 400), conn("127.0.0.1", "lo0", 2, 6_000, 600)],
            snapshotTime: t1)
        let app = usages.first { $0.pids.contains(7) }!
        XCTAssertEqual(app.totalBytesIn, 10_000)
        XCTAssertEqual(app.internetBytesIn, 4_000)
        XCTAssertEqual(app.internetBytesOut, 400)
        XCTAssertEqual(app.internetDownloadSpeed, 4_000, accuracy: 0.001)
        XCTAssertTrue(tracker.lastTickInternetBytes == (4_000, 400))
    }

    /// A local flow that opens mid-tick under an already-tracked PID counts its
    /// whole cumulative total as this tick's local delta.
    func test_newLocalFlow_underKnownPid_isSubtracted() {
        let tracker = ProcessTracker()
        let t0 = Date(), t1 = t0.addingTimeInterval(1)
        _ = tracker.ingest(snapshot: [ProcessSample(pid: 8, processName: "Dev", bytesIn: 0, bytesOut: 0)],
                           connections: [], snapshotTime: t0)
        let usages = tracker.ingest(
            snapshot: [ProcessSample(pid: 8, processName: "Dev", bytesIn: 5_000, bytesOut: 500)],
            connections: [ConnectionSample(pid: 8, proto: "tcp4", localIP: "127.0.0.1", localPort: 3000,
                                           remoteIP: "127.0.0.1", remotePort: 51000,
                                           bytesIn: 5_000, bytesOut: 500, interface: "lo0")],
            snapshotTime: t1)
        let app = usages.first { $0.pids.contains(8) }!
        XCTAssertEqual(app.totalBytesIn, 5_000)
        XCTAssertEqual(app.internetBytesIn, 0)
        XCTAssertEqual(app.internetBytesOut, 0)
    }
}

final class DailyUsageStoreTests: XCTestCase {
    private var url: URL!
    private let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    override func setUp() {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("daily-\(UUID().uuidString).json")
    }

    override func tearDown() { try? FileManager.default.removeItem(at: url) }

    func test_accumulatesAndRollsOverAtMidnight() {
        let day1 = Date(timeIntervalSince1970: 1_760_000_000)      // 2025-10-09 08:53 UTC
        let store = DailyUsageStore(storeURL: url, calendar: utc, now: day1, autosave: false)
        store.ingest(internetIn: 1_000, internetOut: 100, now: day1)
        store.ingest(internetIn: 500, internetOut: 50, now: day1.addingTimeInterval(60))
        XCTAssertEqual(store.today.internetBytes, 1_650)

        let day2 = day1.addingTimeInterval(24 * 3600)
        store.ingest(internetIn: 0, internetOut: 0, now: day2)
        XCTAssertEqual(store.today.internetBytes, 0, "a new day starts from zero even with no traffic")
        XCTAssertEqual(store.history.map(\.internetBytes), [1_650])
    }

    func test_persistsTodayAcrossRelaunch() {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let a = DailyUsageStore(storeURL: url, calendar: utc, now: now, autosave: false)
        a.ingest(internetIn: 2_000, internetOut: 200, now: now)
        a.saveBlocking()

        let b = DailyUsageStore(storeURL: url, calendar: utc, now: now.addingTimeInterval(10), autosave: false)
        XCTAssertEqual(b.today.internetBytesIn, 2_000)
        XCTAssertEqual(b.today.internetBytesOut, 200)

        let nextDay = DailyUsageStore(storeURL: url, calendar: utc,
                                      now: now.addingTimeInterval(24 * 3600), autosave: false)
        XCTAssertEqual(nextDay.today.internetBytes, 0)
        XCTAssertEqual(nextDay.history.count, 1)
    }
}

final class LifetimeUsageInternetDecodingTests: XCTestCase {
    /// Rows written before the internet split existed must still load, with the
    /// internet counters starting at zero.
    func test_legacyRow_decodesWithZeroInternet() throws {
        let json = """
        {"id":"a","displayName":"A","totalBytesIn":10,"totalBytesOut":5,
         "firstSeen":0,"lastSeen":0}
        """.data(using: .utf8)!
        let row = try JSONDecoder().decode(LifetimeUsage.self, from: json)
        XCTAssertEqual(row.totalBytes, 15)
        XCTAssertEqual(row.totalBytes(in: .internet), 0)
        XCTAssertEqual(row.totalBytes(in: .all), 15)
    }

    func test_roundTrip_keepsInternetCounters() throws {
        let row = LifetimeUsage(id: "b", displayName: "B", bundleIdentifier: nil, bundlePath: nil,
                                totalBytesIn: 100, totalBytesOut: 50, firstSeen: Date(), lastSeen: Date(),
                                internetBytesIn: 60, internetBytesOut: 20)
        let back = try JSONDecoder().decode(LifetimeUsage.self, from: JSONEncoder().encode(row))
        XCTAssertEqual(back.internetBytesIn, 60)
        XCTAssertEqual(back.internetBytesOut, 20)
    }
}
