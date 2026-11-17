import Combine
import Darwin
import Foundation
import IOKit

public struct ProcRow: Identifiable, Equatable {
    public let id: Int
    public let name: String
    public let cpu: Double        // percent of one core, can exceed 100
    public let memBytes: UInt64

    public init(id: Int, name: String, cpu: Double, memBytes: UInt64) {
        self.id = id
        self.name = name
        self.cpu = cpu
        self.memBytes = memBytes
    }
}

public struct Snapshot {
    public var cpu: Double = 0                 // 0...1 across all cores
    public var cores: [Double] = []            // 0...1 per core
    public var history: [Double] = Array(repeating: 0, count: 60)
    public var load: [Double] = [0, 0, 0]

    public var memTotal: UInt64 = ProcessInfo.processInfo.physicalMemory
    public var memApp: UInt64 = 0
    public var memWired: UInt64 = 0
    public var memCompressed: UInt64 = 0
    public var memPressure: Int = 1            // 1 normal, 2 warning, 4 critical
    public var swapUsed: UInt64 = 0

    public var gpu: Double? = nil              // 0...1
    public var netDown: Double = 0             // bytes per second
    public var netUp: Double = 0
    public var thermal: ProcessInfo.ThermalState = .nominal

    public init() {}

    public var memUsed: UInt64 { memApp + memWired + memCompressed }
    public var memFraction: Double { memTotal == 0 ? 0 : min(1, Double(memUsed) / Double(memTotal)) }
}

/// Samples system load once a second. All mutation happens on the main thread.
public final class Metrics: ObservableObject {
    @Published public var snap = Snapshot()
    @Published public var processes: [ProcRow] = []

    /// The process list costs a `ps` spawn, so it only runs while the panel is open.
    public var wantsProcesses = false {
        didSet { if wantsProcesses && !oldValue { sampleProcesses() } }
    }

    public let efficiencyCores: Int = {
        var n: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.perflevel1.logicalcpu", &n, &size, nil, 0) == 0 ? Int(n) : 0
    }()

    private var timer: Timer?
    private var tick = 0
    private var prevTicks: [[UInt32]] = []
    private var prevNet: [String: (UInt32, UInt32)] = [:]
    private var prevNetTime = Date()
    private var psRunning = false
    private let psQueue = DispatchQueue(label: "notchload.ps", qos: .utility)

    public init() {}

    public func start() {
        sample()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.sample() }
        t.tolerance = 0.1
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func sample() {
        var s = snap
        sampleCPU(&s)
        sampleMemory(&s)
        sampleNetwork(&s)
        var la = [Double](repeating: 0, count: 3)
        if getloadavg(&la, 3) == 3 { s.load = la }
        s.thermal = ProcessInfo.processInfo.thermalState
        if tick % 2 == 0 { s.gpu = Self.gpuUtilization() }
        snap = s
        if wantsProcesses && tick % 2 == 0 { sampleProcesses() }
        tick += 1
    }

    // MARK: CPU

    private func sampleCPU(_ s: inout Snapshot) {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount) == KERN_SUCCESS,
              let info else { return }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                          vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride))
        }

        let states = Int(CPU_STATE_MAX)
        var ticks: [[UInt32]] = []
        for i in 0..<Int(cpuCount) {
            ticks.append((0..<states).map { UInt32(bitPattern: info[i * states + $0]) })
        }
        defer { prevTicks = ticks }
        guard prevTicks.count == ticks.count else { return }

        var cores: [Double] = []
        var busyAll: UInt64 = 0
        var totalAll: UInt64 = 0
        for (now, before) in zip(ticks, prevTicks) {
            let d = zip(now, before).map { UInt64($0 &- $1) }
            let total = d.reduce(0, +)
            let busy = total - d[Int(CPU_STATE_IDLE)]
            cores.append(total == 0 ? 0 : Double(busy) / Double(total))
            busyAll += busy
            totalAll += total
        }
        s.cores = cores
        s.cpu = totalAll == 0 ? 0 : Double(busyAll) / Double(totalAll)
        s.history.removeFirst()
        s.history.append(s.cpu)
    }

    // MARK: Memory

    private func sampleMemory(_ s: inout Snapshot) {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        if kr == KERN_SUCCESS {
            // Same breakdown Activity Monitor uses for "Memory Used".
            let page = UInt64(getpagesize())
            let internalPages = UInt64(stats.internal_page_count)
            let purgeable = UInt64(stats.purgeable_count)
            s.memApp = (internalPages > purgeable ? internalPages - purgeable : 0) * page
            s.memWired = UInt64(stats.wire_count) * page
            s.memCompressed = UInt64(stats.compressor_page_count) * page
        }

        var level: Int32 = 1
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 {
            s.memPressure = Int(level)
        }

        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0 {
            s.swapUsed = swap.xsu_used
        }
    }

    // MARK: Network

    private func sampleNetwork(_ s: inout Snapshot) {
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0 else { return }
        defer { freeifaddrs(ifap) }

        var now: [String: (UInt32, UInt32)] = [:]
        var p = ifap
        while let a = p {
            let ifa = a.pointee
            if let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK), let data = ifa.ifa_data {
                let name = String(cString: ifa.ifa_name)
                if name.hasPrefix("en") {
                    let d = data.assumingMemoryBound(to: if_data.self).pointee
                    now[name] = (d.ifi_ibytes, d.ifi_obytes)
                }
            }
            p = ifa.ifa_next
        }

        let time = Date()
        let dt = time.timeIntervalSince(prevNetTime)
        if dt > 0, !prevNet.isEmpty {
            var down: UInt64 = 0
            var up: UInt64 = 0
            for (name, cur) in now {
                guard let old = prevNet[name] else { continue }
                // Counters are 32-bit and wrap; wrapping subtraction keeps the delta right.
                down += UInt64(cur.0 &- old.0)
                up += UInt64(cur.1 &- old.1)
            }
            s.netDown = Double(down) / dt
            s.netUp = Double(up) / dt
        }
        prevNet = now
        prevNetTime = time
    }

    // MARK: GPU

    private static func gpuUtilization() -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        var best: Double?
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            guard let raw = IORegistryEntryCreateCFProperty(entry, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? [String: Any],
                  let pct = (raw["Device Utilization %"] as? NSNumber)?.doubleValue else { continue }
            best = max(best ?? 0, pct / 100)
        }
        return best
    }

    // MARK: Processes

    private func sampleProcesses() {
        guard !psRunning else { return }
        psRunning = true
        psQueue.async { [weak self] in
            let rows = Self.topProcesses(limit: 5)
            DispatchQueue.main.async {
                guard let self else { return }
                self.psRunning = false
                if let rows { self.processes = rows }
            }
        }
    }

    private static func topProcesses(limit: Int) -> [ProcRow]? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-Aceo", "pid=,pcpu=,rss=,comm=", "-r"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        return parseProcesses(text, limit: limit)
    }

    /// Parses `ps -Aceo pid=,pcpu=,rss=,comm= -r` output, which is already sorted by CPU.
    public static func parseProcesses(_ text: String, limit: Int) -> [ProcRow] {
        var rows: [ProcRow] = []
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count == 4, let pid = Int(parts[0]), let cpu = Double(parts[1]), let rssKB = UInt64(parts[2]) else { continue }
            let name = parts[3].trimmingCharacters(in: .whitespaces)
            if name == "ps" { continue }
            rows.append(ProcRow(id: pid, name: name, cpu: cpu, memBytes: rssKB * 1024))
            if rows.count == limit { break }
        }
        return rows
    }
}
