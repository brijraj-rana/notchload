import Darwin
import Foundation

/// Keeps Quit and Force Quit away from processes the Mac cannot do without, and from Notchload itself.
public enum ProcessGuard {
    public static let protectedNames: Set<String> = ["kernel_task", "launchd", "WindowServer", "loginwindow"]

    public static func canQuit(pid: Int, name: String, ownPID: Int = Int(getpid())) -> Bool {
        guard pid > 1, pid != ownPID else { return false }
        return !protectedNames.contains(name.trimmingCharacters(in: .whitespaces))
    }

    public enum Outcome: Equatable {
        case sent
        case protected          // refused by the guard
        case changed            // the pid now belongs to a different process
        case failed(Int32)      // errno from kill, usually EPERM for a process owned by someone else
    }

    /// The executable name of a running process, or nil if it cannot be read (gone, or not ours to inspect).
    public static func currentName(of pid: Int) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(Int32(pid), &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return URL(fileURLWithPath: String(cString: buffer)).lastPathComponent
    }

    /// Whether the pid still belongs to the process the row was sampled from. Pids are reused.
    public static func stillMatches(pid: Int, name: String, currentName: String?) -> Bool {
        guard let currentName else { return true }      // unreadable: let kill decide, it will refuse what it must
        return currentName == name
    }

    /// Sends SIGTERM, or SIGKILL when forced, after checking the guard and that the pid is still the same process.
    @discardableResult
    public static func signal(pid: Int, name: String, force: Bool, ownPID: Int = Int(getpid())) -> Outcome {
        guard canQuit(pid: pid, name: name, ownPID: ownPID) else { return .protected }
        guard stillMatches(pid: pid, name: name, currentName: currentName(of: pid)) else { return .changed }
        return kill(pid_t(pid), force ? SIGKILL : SIGTERM) == 0 ? .sent : .failed(errno)
    }
}
