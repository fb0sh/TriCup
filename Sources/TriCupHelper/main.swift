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

let ownerUID = ConsoleUser.uid()
let server = SocketLeaseServer(
    socketPath: HelperPaths.socketPath,
    manager: manager,
    ownerUID: ownerUID
) { peer in
    if let owner = ownerUID, peer.uid != owner {
        return false
    }
    return true
}

do {
    try server.start()
} catch {
    NSLog("TriCupHelper: failed to start socket server: %@", String(describing: error))
    exit(1)
}

RunLoop.current.run()
