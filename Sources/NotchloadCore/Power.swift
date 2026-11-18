import Foundation
import IOKit.ps

public struct Battery: Equatable {
    public enum Source: Equatable {
        case battery        // running on battery
        case charging       // plugged in and charging
        case pluggedIn      // plugged in, not charging (full, or held by charge limiting)
    }

    public var level: Double            // 0...1
    public var source: Source
    public var minutesRemaining: Int?   // to empty on battery, to full while charging; nil while macOS is still estimating

    public init(level: Double, source: Source, minutesRemaining: Int?) {
        self.level = level
        self.source = source
        self.minutesRemaining = minutesRemaining
    }

    /// Reads one IOKit power source description. Returns nil for anything that is not an internal battery.
    public static func parse(_ info: [String: Any]) -> Battery? {
        guard info["Type"] as? String == "InternalBattery" else { return nil }
        if let present = info["Is Present"] as? Bool, !present { return nil }
        guard let current = (info["Current Capacity"] as? NSNumber)?.doubleValue,
              let maximum = (info["Max Capacity"] as? NSNumber)?.doubleValue, maximum > 0 else { return nil }

        let onAC = info["Power Source State"] as? String == "AC Power"
        let charging = info["Is Charging"] as? Bool ?? false
        let source: Source = onAC ? (charging ? .charging : .pluggedIn) : .battery

        var minutes: Int?
        switch source {
        case .battery: minutes = (info["Time to Empty"] as? NSNumber)?.intValue
        case .charging: minutes = (info["Time to Full Charge"] as? NSNumber)?.intValue
        case .pluggedIn: minutes = nil
        }
        // IOKit reports -1 (and briefly 0) while it is still working the estimate out.
        if let m = minutes, m <= 0 { minutes = nil }

        return Battery(level: min(1, max(0, current / maximum)), source: source, minutesRemaining: minutes)
    }

    /// The internal battery, or nil on a Mac without one.
    public static func current() -> Battery? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let info = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                  let battery = parse(info) else { continue }
            return battery
        }
        return nil
    }
}

public struct Disk: Equatable {
    public var free: UInt64
    public var total: UInt64

    public init(free: UInt64, total: UInt64) {
        self.free = free
        self.total = total
    }

    public var usedFraction: Double {
        total == 0 ? 0 : min(1, max(0, 1 - Double(free) / Double(total)))
    }

    /// The startup disk. Free space is the figure Finder shows, which counts space macOS can reclaim.
    public static func startup() -> Disk? {
        let url = URL(fileURLWithPath: "/")
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey,
                                                             .volumeAvailableCapacityKey, .volumeTotalCapacityKey]),
              let total = values.volumeTotalCapacity, total > 0 else { return nil }
        var free = values.volumeAvailableCapacityForImportantUsage ?? 0
        if free <= 0 { free = Int64(values.volumeAvailableCapacity ?? 0) }
        return Disk(free: UInt64(max(0, free)), total: UInt64(total))
    }
}
