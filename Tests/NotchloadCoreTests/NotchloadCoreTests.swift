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
}
