import AppKit
import TriCupCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBar: StatusBarController?
    private var system: SystemPowerManager?
    private var lid: LidSleepClient?
    private var healthTimer: Timer?
    private var wakeObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let assertions = AssertionPowerManager()
        let lidClient = LidSleepClient()
        let systemManager = SystemPowerManager(
            assertions: assertions,
            lid: lidClient,
            reader: PMSetSleepStateReader()
        )
        let controller = CupController(power: systemManager)
        let installer = HelperInstaller()
        let battery = BatteryMonitor()
        let lowBatteryGuard = LowBatteryGuard()
        let loginItemManager = LoginItemManager()
        let bar = StatusBarController(
            controller: controller,
            installer: installer,
            battery: battery,
            lowBatteryGuard: lowBatteryGuard,
            loginItemManager: loginItemManager,
            system: systemManager
        )

        systemManager.onUnexpectedDisconnect = { [weak bar] _, uncertain in
            bar?.handleUnexpectedDisconnect(uncertain: uncertain)
        }

        self.lid = lidClient
        self.system = systemManager
        self.statusBar = bar

        Notifier.shared.requestAuthorization()

        healthTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.checkFullModeHealth()
        }

        // Re-apply the current state after the system wakes from sleep, so a
        // half/full choice keeps working without the user re-selecting it.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleWake()
        }
    }

    private func handleWake() {
        guard let system = system, let bar = statusBar else { return }
        _ = system.reassertCurrentState()
        bar.handleWake()
    }

    /// While full, poll the helper connection; a dead helper forces a drop to
    /// empty and never re-acquires the lease automatically.
    private func checkFullModeHealth() {
        guard let system = system, let lid = lid, let bar = statusBar else { return }
        bar.evaluateLowBattery()
        if bar.currentState == .full && !lid.checkAlive() {
            system.handleLidDisconnect()
        }
    }
}
