import AppKit
import TriCupCore

/// Owns the `NSStatusItem`, its icon, tooltip and right-click menu.
final class StatusBarController: NSObject {
    private let statusItem: NSStatusItem
    private let controller: CupController
    private let installer: HelperInstaller
    private let battery: BatteryStatusProviding
    private let lowBatteryGuard: LowBatteryGuard
    private let loginItemManager: LoginItemManager
    private let menu = NSMenu()
    private var stateItems: [NSMenuItem] = []
    private var uninstallItem: NSMenuItem?
    private var loginItem: NSMenuItem?

    init(
        controller: CupController,
        installer: HelperInstaller,
        battery: BatteryStatusProviding,
        lowBatteryGuard: LowBatteryGuard,
        loginItemManager: LoginItemManager
    ) {
        self.controller = controller
        self.installer = installer
        self.battery = battery
        self.lowBatteryGuard = lowBatteryGuard
        self.loginItemManager = loginItemManager
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        configureButton()
        buildMenu()
        refresh()
    }

    var currentState: CupState { controller.state }

    /// Reconciles the UI after the helper connection dropped unexpectedly. The
    /// power backend has already dropped to empty; this just reflects it.
    func handleUnexpectedDisconnect() {
        controller.synchronize(to: .empty)
        refresh()
        Notifier.shared.post(
            title: "TriCup",
            body: "与 Helper 的连接已断开，已退出满杯（合盖保护失效）。"
        )
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(handleClick(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func buildMenu() {
        stateItems.removeAll()
        for state in CupState.allCases {
            let item = NSMenuItem(title: state.title, action: #selector(selectState(_:)), keyEquivalent: "")
            item.target = self
            item.tag = state.rawValue
            menu.addItem(item)
            stateItems.append(item)
        }
        menu.addItem(.separator())

        let login = NSMenuItem(
            title: "登录时启动",
            action: #selector(toggleLoginItem),
            keyEquivalent: ""
        )
        login.target = self
        menu.addItem(login)
        loginItem = login

        let uninstall = NSMenuItem(
            title: "卸载 Helper…",
            action: #selector(uninstallHelperSelected),
            keyEquivalent: ""
        )
        uninstall.target = self
        menu.addItem(uninstall)
        uninstallItem = uninstall

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 TriCup", action: #selector(quitSelected), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private func refresh() {
        updateIcon()
        updateChecks()
        uninstallItem?.isHidden = !installer.isInstalled
        loginItem?.state = loginItemManager.isEnabled ? .on : .off
    }

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        let name: String
        switch controller.state {
        case .empty: name = "empty"
        case .half: name = "half"
        case .full: name = "full"
        }
        if let url = Bundle.module.url(forResource: name, withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            image.isTemplate = true
            image.size = NSSize(width: 22, height: 20)
            button.image = image
        }
        button.toolTip = "TriCup — \(controller.state.title)：\(controller.state.detail)"
    }

    private func updateChecks() {
        for item in stateItems {
            item.state = (CupState(rawValue: item.tag) == controller.state) ? .on : .off
        }
    }

    @objc private func handleClick(_ sender: Any?) {
        let event = NSApp.currentEvent
        let isRightClick = event?.type == .rightMouseUp
            || (event?.modifierFlags.contains(.control) ?? false)
        if isRightClick {
            showMenu()
        } else {
            changeTo(controller.state.next)
        }
    }

    private func showMenu() {
        refresh()
        guard let button = statusItem.button else { return }
        _ = menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    @objc private func selectState(_ sender: NSMenuItem) {
        guard let state = CupState(rawValue: sender.tag) else { return }
        changeTo(state)
    }

    /// Installs the helper on first full-mode entry (one admin authorization),
    /// then applies the change. Failure leaves the previous state untouched.
    private func changeTo(_ target: CupState) {
        if target == .full && lowBatteryGuard.blocksFull(battery.current()) {
            Notifier.shared.post(
                title: "TriCup",
                body: "电量 ≤\(lowBatteryGuard.threshold)%，未进入满杯。"
            )
            refresh()
            return
        }
        if target == .full && !installer.isInstalled {
            do {
                try installer.install()
            } catch {
                Notifier.shared.post(title: "TriCup", body: "无法安装 Helper：\(error)")
                refresh()
                return
            }
        }
        applyChange { controller.setState(target) }
    }

    /// Called periodically: if we are full and the battery has dropped to the
    /// threshold on battery power, exit to empty and notify.
    func evaluateLowBattery() {
        guard controller.state == .full else { return }
        guard lowBatteryGuard.shouldExitFull(battery.current()) else { return }
        _ = controller.setState(.empty)
        refresh()
        Notifier.shared.post(
            title: "TriCup",
            body: "电量 ≤\(lowBatteryGuard.threshold)%，已自动退出满杯。"
        )
    }

    /// Applies a state change and always refreshes; logs any failure so the
    /// icon keeps reflecting the actually-effective state.
    private func applyChange(_ change: () -> Result<CupState, Error>) {
        let result = change()
        if case .failure(let error) = result {
            NSLog("TriCup: failed to apply state change: %@", String(describing: error))
        }
        refresh()
    }

    @objc private func uninstallHelperSelected() {
        if controller.state == .full {
            if case .failure(let error) = controller.setState(.empty) {
                Notifier.shared.post(
                    title: "TriCup",
                    body: "无法恢复电源设置，已取消卸载 Helper：\(error)"
                )
                refresh()
                return
            }
        }
        do {
            try installer.uninstall()
        } catch {
            Notifier.shared.post(title: "TriCup", body: "卸载 Helper 失败：\(error)")
        }
        refresh()
    }

    @objc private func toggleLoginItem() {
        let enable = !loginItemManager.isEnabled
        do {
            try loginItemManager.setEnabled(enable)
        } catch {
            Notifier.shared.post(title: "TriCup", body: "无法更新登录项：\(error)")
        }
        refresh()
    }

    @objc private func quitSelected() {
        // Best-effort: returning to empty releases the lease before quitting.
        if controller.state != .empty {
            _ = controller.setState(.empty)
        }
        NSApp.terminate(nil)
    }
}
