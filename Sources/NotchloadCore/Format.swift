import Foundation

/// Number formatting shared by the tab and the panel.
public enum Fmt {
    public static func percent(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }

    public static func gb(_ bytes: UInt64) -> String {
        String(format: "%.1f", Double(bytes) / 1_073_741_824)
    }

    public static func mem(_ bytes: UInt64) -> String {
        let mb = Double(bytes) / 1_048_576
        return mb >= 1024 ? String(format: "%.1f GB", mb / 1024) : String(format: "%.0f MB", mb)
    }

    public static func rate(_ bytesPerSec: Double) -> String {
        let kb = bytesPerSec / 1024
        if kb >= 1024 { return String(format: "%.1f MB/s", kb / 1024) }
        return String(format: "%.0f KB/s", kb)
    }
}
