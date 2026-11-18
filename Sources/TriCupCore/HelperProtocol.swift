import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Fixed locations used by the privileged helper. Paths are absolute and owned
/// by root at install time (see ADR-0001).
public enum HelperPaths {
    public static let socketPath = "/var/run/com.fb0sh.tricup.sock"
    public static let leaseFilePath = "/Library/Application Support/TriCup/lease.json"
    public static let uninstallingFlagPath = "/Library/Application Support/TriCup/uninstalling"
    public static let helperDirectory = "/Library/Application Support/TriCup"
    public static let helperBinaryPath = "/Library/PrivilegedHelperTools/com.fb0sh.tricup.helper"
    public static let launchDaemonPlistPath = "/Library/LaunchDaemons/com.fb0sh.tricup.helper.plist"
    public static let launchDaemonLabel = "com.fb0sh.tricup.helper"
}

/// Minimal information about a connected peer, used for the auxiliary checks
/// described in ADR-0001. The real trust boundary is the same UID: these checks
/// only reject cross-user or obviously bogus connections.
public struct HelperPeerInfo {
    public let uid: uid_t
    public let pid: pid_t
    public let executablePath: String?

    public init(uid: uid_t, pid: pid_t, executablePath: String?) {
        self.uid = uid
        self.pid = pid
        self.executablePath = executablePath
    }
}

/// The console user's UID (owner of `/dev/console`), used to restrict the
/// socket to the logged-in user.
public enum ConsoleUser {
    public static func uid() -> uid_t? {
        var info = stat()
        guard stat("/dev/console", &info) == 0 else { return nil }
        return info.st_uid
    }
}
