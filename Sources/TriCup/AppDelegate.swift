import AppKit
import TriCupCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBar: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let power = AssertionPowerManager()
        let controller = CupController(power: power)
        statusBar = StatusBarController(controller: controller)
    }
}
