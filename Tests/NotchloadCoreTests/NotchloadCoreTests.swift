import XCTest
@testable import NotchloadCore

final class NotchloadCoreTests: XCTestCase {
    func testParsesProcessList() {
        let text = """
          412  64.2 1945600 Xcode
          158  21.7  317440 WindowServer
         9001   9.9    1024 ps
           77   3.0   20480 Google Chrome Helper (Renderer)
        garbage line
        """
        let rows = Metrics.parseProcesses(text, limit: 5)
        XCTAssertEqual(rows.map(\.name), ["Xcode", "WindowServer", "Google Chrome Helper (Renderer)"])
        XCTAssertEqual(rows[0], ProcRow(id: 412, name: "Xcode", cpu: 64.2, memBytes: 1_945_600 * 1024))
    }

    func testProcessListRespectsLimit() {
        let text = (1...10).map { "\($0) 1.0 100 proc\($0)" }.joined(separator: "\n")
        XCTAssertEqual(Metrics.parseProcesses(text, limit: 3).count, 3)
    }

    func testFormatting() {
        XCTAssertEqual(Fmt.percent(0.346), "35%")
        XCTAssertEqual(Fmt.gb(16 * 1_073_741_824), "16.0")
        XCTAssertEqual(Fmt.mem(512 * 1_048_576), "512 MB")
        XCTAssertEqual(Fmt.mem(1536 * 1_048_576), "1.5 GB")
        XCTAssertEqual(Fmt.rate(300 * 1024), "300 KB/s")
        XCTAssertEqual(Fmt.rate(2.5 * 1_048_576), "2.5 MB/s")
    }

    func testMemoryFraction() {
        var snap = Snapshot()
        snap.memTotal = 16
        snap.memApp = 4
        snap.memWired = 2
        snap.memCompressed = 2
        XCTAssertEqual(snap.memUsed, 8)
        XCTAssertEqual(snap.memFraction, 0.5)
    }

    func testLiveSampleIsSane() {
        let metrics = Metrics()
        metrics.start()
        RunLoop.main.run(until: Date().addingTimeInterval(2.3))
        let snap = metrics.snap
        XCTAssertEqual(snap.cores.count, ProcessInfo.processInfo.processorCount)
        XCTAssert((0...1).contains(snap.cpu))
        XCTAssert(snap.cores.allSatisfy { (0...1).contains($0) })
        XCTAssertGreaterThan(snap.memUsed, 0)
        XCTAssertLessThanOrEqual(snap.memUsed, snap.memTotal)
    }

    // MARK: Culprit

    private func feed(_ tracker: inout CulpritTracker, _ cpu: Double, seconds: Int) {
        for _ in 0..<seconds { tracker.feed(cpu: cpu) }
    }

    func testSustainedLoadNeedsThirtySeconds() {
        var tracker = CulpritTracker()
        feed(&tracker, 0.95, seconds: 29)
        XCTAssertFalse(tracker.sustained)
        XCTAssertTrue(tracker.feed(cpu: 0.85))
    }

    func testShortSpikeDoesNotTrigger() {
        var tracker = CulpritTracker()
        feed(&tracker, 0.99, seconds: 20)
        feed(&tracker, 0.30, seconds: 1)
        feed(&tracker, 0.99, seconds: 20)
        XCTAssertFalse(tracker.sustained)
    }

    func testDipBetweenThresholdsNeitherCountsNorResets() {
        var tracker = CulpritTracker()
        feed(&tracker, 0.90, seconds: 20)
        feed(&tracker, 0.78, seconds: 3)
        feed(&tracker, 0.90, seconds: 9)
        XCTAssertFalse(tracker.sustained)
        XCTAssertTrue(tracker.feed(cpu: 0.90))
    }

    func testLetsGoOnlyAfterLoadStaysLow() {
        var tracker = CulpritTracker()
        feed(&tracker, 0.95, seconds: 30)
        feed(&tracker, 0.75, seconds: 60)       // lower, but not low enough to let go
        XCTAssertTrue(tracker.sustained)
        feed(&tracker, 0.40, seconds: 4)
        XCTAssertTrue(tracker.sustained)
        feed(&tracker, 0.95, seconds: 1)        // a rebound starts the count again
        feed(&tracker, 0.40, seconds: 4)
        XCTAssertTrue(tracker.sustained)
        XCTAssertFalse(tracker.feed(cpu: 0.40))
        // And it takes a full stretch to come back.
        feed(&tracker, 0.95, seconds: 29)
        XCTAssertFalse(tracker.sustained)
    }

    func testCulpritIsNamedOnlyWhileSustained() {
        var tracker = CulpritTracker()
        let xcode = ProcRow(id: 10, name: "Xcode", cpu: 310, memBytes: 0)
        XCTAssertNil(tracker.observe(top: xcode))
        feed(&tracker, 0.95, seconds: 30)
        XCTAssertEqual(tracker.observe(top: xcode), "Xcode")
        feed(&tracker, 0.10, seconds: 5)
        XCTAssertNil(tracker.culprit)
        XCTAssertNil(tracker.observe(top: xcode))
    }

    func testCulpritNameDoesNotFlicker() {
        var tracker = CulpritTracker()
        feed(&tracker, 0.95, seconds: 30)
        let xcode = ProcRow(id: 10, name: "Xcode", cpu: 310, memBytes: 0)
        let swift = ProcRow(id: 11, name: "swift-frontend", cpu: 420, memBytes: 0)
        XCTAssertEqual(tracker.observe(top: xcode), "Xcode")
        XCTAssertEqual(tracker.observe(top: swift), "Xcode")        // one sample is not enough
        XCTAssertEqual(tracker.observe(top: xcode), "Xcode")
        XCTAssertEqual(tracker.observe(top: swift), "Xcode")        // the count started over
        XCTAssertEqual(tracker.observe(top: swift), "swift-frontend")
    }

    func testNobodyIsBlamedForSpreadOutLoad() {
        var tracker = CulpritTracker()
        feed(&tracker, 0.95, seconds: 30)
        let small = ProcRow(id: 12, name: "mdworker", cpu: 22, memBytes: 0)
        XCTAssertNil(tracker.observe(top: small))
        XCTAssertNil(tracker.observe(top: nil))
        let big = ProcRow(id: 13, name: "ffmpeg", cpu: 50, memBytes: 0)
        XCTAssertEqual(tracker.observe(top: big), "ffmpeg")
        XCTAssertEqual(tracker.observe(top: small), "ffmpeg")
        XCTAssertNil(tracker.observe(top: small))
    }

    func testCulpritDisplayName() {
        XCTAssertEqual(CulpritTracker.displayName("Google Chrome Helper (Renderer)"), "Google Chrome")
        XCTAssertEqual(CulpritTracker.displayName("Slack Helper"), "Slack")
        XCTAssertEqual(CulpritTracker.displayName("Xcode"), "Xcode")
        XCTAssertEqual(CulpritTracker.displayName("Helper Tool"), "Helper Tool")
        XCTAssertEqual(CulpritTracker.displayName("My Helper App"), "My Helper App")
    }

    /// With the bar lowered to nothing, the sampler must reach for the process list on its own, panel closed.
    func testSustainedLoadSamplesProcessesWithPanelClosed() {
        var config = CulpritTracker.Config()
        config.enter = 0
        config.exit = -1
        config.enterSeconds = 4
        config.minProcessCPU = 0
        let metrics = Metrics(culprit: config)
        metrics.start()
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))
        XCTAssertTrue(metrics.processes.isEmpty, "nothing is sampled before load is sustained")
        let deadline = Date().addingTimeInterval(6)
        while metrics.culprit == nil && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertFalse(metrics.processes.isEmpty)
        XCTAssertEqual(metrics.culprit, metrics.processes.first?.name)
    }

    func testIdleSamplerNeverSpawnsProcessList() {
        let metrics = Metrics()
        metrics.start()
        RunLoop.main.run(until: Date().addingTimeInterval(2.3))
        XCTAssertTrue(metrics.processes.isEmpty)
        XCTAssertNil(metrics.culprit)
    }

    // MARK: Quit guard

    func testGuardRefusesSystemProcessesAndSelf() {
        XCTAssertFalse(ProcessGuard.canQuit(pid: 0, name: "kernel_task", ownPID: 500))
        XCTAssertFalse(ProcessGuard.canQuit(pid: 1, name: "launchd", ownPID: 500))
        XCTAssertFalse(ProcessGuard.canQuit(pid: 0, name: "anything", ownPID: 500))
        XCTAssertFalse(ProcessGuard.canQuit(pid: 1, name: "anything", ownPID: 500))
        XCTAssertFalse(ProcessGuard.canQuit(pid: -1, name: "anything", ownPID: 500))
        XCTAssertFalse(ProcessGuard.canQuit(pid: 158, name: "WindowServer", ownPID: 500))
        XCTAssertFalse(ProcessGuard.canQuit(pid: 201, name: "loginwindow", ownPID: 500))
        XCTAssertFalse(ProcessGuard.canQuit(pid: 88, name: "kernel_task", ownPID: 500))
        XCTAssertFalse(ProcessGuard.canQuit(pid: 158, name: " WindowServer ", ownPID: 500))
        XCTAssertFalse(ProcessGuard.canQuit(pid: 500, name: "Notchload", ownPID: 500))
        XCTAssertFalse(ProcessGuard.canQuit(pid: Int(getpid()), name: "xctest"))
        XCTAssertTrue(ProcessGuard.canQuit(pid: 412, name: "Xcode", ownPID: 500))
    }

    func testSignalRefusesProtectedTargetsWithoutSending() {
        XCTAssertEqual(ProcessGuard.signal(pid: 1, name: "launchd", force: true), .protected)
        XCTAssertEqual(ProcessGuard.signal(pid: 0, name: "kernel_task", force: false), .protected)
        XCTAssertEqual(ProcessGuard.signal(pid: Int(getpid()), name: "xctest", force: true), .protected)
    }

    func testPidReuseIsCaught() {
        XCTAssertTrue(ProcessGuard.stillMatches(pid: 412, name: "Xcode", currentName: "Xcode"))
        XCTAssertFalse(ProcessGuard.stillMatches(pid: 412, name: "Xcode", currentName: "Safari"))
        XCTAssertTrue(ProcessGuard.stillMatches(pid: 412, name: "Xcode", currentName: nil))
    }

    func testSignalQuitsARealProcessAndRefusesAMismatchedName() throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sleep")
        task.arguments = ["30"]
        try task.run()
        let pid = Int(task.processIdentifier)
        XCTAssertEqual(ProcessGuard.currentName(of: pid), "sleep")
        XCTAssertEqual(ProcessGuard.signal(pid: pid, name: "Xcode", force: true), .changed)
        XCTAssertTrue(task.isRunning)
        XCTAssertEqual(ProcessGuard.signal(pid: pid, name: "sleep", force: false), .sent)
        task.waitUntilExit()
        XCTAssertEqual(task.terminationReason, .uncaughtSignal)
        XCTAssertEqual(task.terminationStatus, SIGTERM)
    }

    // MARK: Battery and disk

    func testParsesBatteryOnBatteryPower() {
        let info: [String: Any] = [
            "Type": "InternalBattery", "Is Present": true, "Current Capacity": 82, "Max Capacity": 100,
            "Power Source State": "Battery Power", "Is Charging": false, "Time to Empty": 281, "Time to Full Charge": 0,
        ]
        XCTAssertEqual(Battery.parse(info), Battery(level: 0.82, source: .battery, minutesRemaining: 281))
    }

    func testParsesChargingAndFullBattery() {
        var info: [String: Any] = [
            "Type": "InternalBattery", "Current Capacity": 46, "Max Capacity": 100,
            "Power Source State": "AC Power", "Is Charging": true, "Time to Empty": 0, "Time to Full Charge": 72,
        ]
        XCTAssertEqual(Battery.parse(info), Battery(level: 0.46, source: .charging, minutesRemaining: 72))
        info["Time to Full Charge"] = -1
        XCTAssertEqual(Battery.parse(info), Battery(level: 0.46, source: .charging, minutesRemaining: nil))
        info["Is Charging"] = false
        info["Current Capacity"] = 100
        XCTAssertEqual(Battery.parse(info), Battery(level: 1, source: .pluggedIn, minutesRemaining: nil))
    }

    func testEstimateStillCalculatingIsNil() {
        let info: [String: Any] = [
            "Type": "InternalBattery", "Current Capacity": 60, "Max Capacity": 100,
            "Power Source State": "Battery Power", "Is Charging": false, "Time to Empty": -1,
        ]
        XCTAssertEqual(Battery.parse(info)?.minutesRemaining, nil)
        XCTAssertEqual(Battery.parse(info)?.source, .battery)
    }

    func testNoBatteryOnADesktop() {
        XCTAssertNil(Battery.parse([:]))
        XCTAssertNil(Battery.parse(["Type": "UPS", "Current Capacity": 90, "Max Capacity": 100]))
        XCTAssertNil(Battery.parse(["Type": "InternalBattery", "Is Present": false, "Current Capacity": 0, "Max Capacity": 100]))
        XCTAssertNil(Battery.parse(["Type": "InternalBattery", "Current Capacity": 50, "Max Capacity": 0]))
    }

    func testLiveBatteryAndDiskAreSane() throws {
        if let battery = Battery.current() {
            XCTAssert((0...1).contains(battery.level))
            if let minutes = battery.minutesRemaining { XCTAssertGreaterThan(minutes, 0) }
        }
        let disk = try XCTUnwrap(Disk.startup())
        XCTAssertGreaterThan(disk.total, 0)
        XCTAssertLessThanOrEqual(disk.free, disk.total)
        XCTAssert((0...1).contains(disk.usedFraction))
    }

    func testPanelOpenSamplesBatteryAndDisk() {
        let metrics = Metrics()
        metrics.panelOpen = true
        let deadline = Date().addingTimeInterval(3)
        while metrics.snap.disk == nil && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertNotNil(metrics.snap.disk)
        XCTAssertEqual(metrics.snap.battery == nil, Battery.current() == nil)
    }

    func testDiskAndClockFormatting() {
        XCTAssertEqual(Fmt.disk(212_400_000_000), "212 GB")
        XCTAssertEqual(Fmt.disk(9_240_000_000), "9.2 GB")
        XCTAssertEqual(Fmt.disk(1_250_000_000_000), "1.25 TB")
        XCTAssertEqual(Fmt.clock(minutes: 281), "4:41")
        XCTAssertEqual(Fmt.clock(minutes: 72), "1:12")
        XCTAssertEqual(Fmt.clock(minutes: 5), "0:05")
        XCTAssertEqual(Disk(free: 25, total: 100).usedFraction, 0.75)
        XCTAssertEqual(Disk(free: 0, total: 0).usedFraction, 0)
    }
}
