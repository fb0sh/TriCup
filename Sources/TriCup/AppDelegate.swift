import AppKit
import TriCupCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBar: StatusBarController?
    private var system: SystemPowerManager?
    private var lid: LidSleepClient?
    private var healthTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let assertions = AssertionPowerManager()
        let lidClient = LidSleepClient()
        let systemManager = SystemPowerManager(assertions: assertions, lid: lidClient)
        let controller = CupController(power: systemManager)
        let bar = StatusBarController(controller: controller)

        systemManager.onUnexpectedDisconnect = { [weak bar] _ in
            bar?.handleUnexpectedDisconnect()
        }

        self.lid = lidClient
        self.system = systemManager
        self.statusBar = bar

        Notifier.shared.requestAuthorization()

        healthTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.checkFullModeHealth()
        }
    }

    /// While full, poll the helper connection; a dead helper forces a drop to
    /// empty and never re-acquires the lease automatically.
    private func checkFullModeHealth() {
        guard let system = system, let lid = lid, let bar = statusBar else { return }
        if bar.currentState == .full && !lid.checkAlive() {
            system.handleLidDisconnect()
        }
    }
}
