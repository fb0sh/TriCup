import Foundation
#if canImport(Darwin)
import Darwin
#endif
import TriCupCore

// TriCupHelper: a root LaunchDaemon whose only job is the closed-lid lease.
// It restores any residual lease on start, then serves enable/disable/status
// over a Unix domain socket. It never executes client-supplied commands.

let setting = PMSetSleepDisabledSetting()
let store = FileLeaseStore(url: URL(fileURLWithPath: HelperPaths.leaseFilePath))
let manager = LeaseManager(setting: setting, store: store)

do {
    try manager.recoverOnStartup()
} catch {
    // Keep running: a residual record makes LeaseManager reject new leases,
    // which is exactly the "no new full lease during recovery" behaviour.
    NSLog("TriCupHelper: residual lease recovery failed: %@", String(describing: error))
}

let server = SocketLeaseServer(
    socketPath: HelperPaths.socketPath,
    manager: manager,
    ownerProvider: { ConsoleUser.uid() },
    enableLockDirectory: HelperPaths.helperDirectory + "/enable.lock"
) { peer in
    // Validate against the *current* console user on every connection, so this
    // keeps working across boot/login and fast user switching.
    guard let owner = ConsoleUser.uid() else { return false }
    return peer.uid == owner
}

do {
    try server.start()
} catch {
    NSLog("TriCupHelper: failed to start socket server: %@", String(describing: error))
    exit(1)
}

RunLoop.current.run()
