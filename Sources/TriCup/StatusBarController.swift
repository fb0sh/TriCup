import AppKit
import TriCupCore

/// Owns the `NSStatusItem`, its icon, tooltip and right-click menu.
final class StatusBarController: NSObject, NSMenuDelegate {
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
        menu.delegate = self
        menu.autoenablesItems = false
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
        if let image = iconImage(for: name) {
            image.isTemplate = true
            image.size = NSSize(width: 22, height: 20)
            button.image = image
        }
        button.toolTip = "TriCup — \(controller.state.title)：\(controller.state.detail)"
    }

    /// Loads the packaged PNG from the app bundle's Resources; falls back to an
    /// SF Symbol when the resource is unavailable (e.g. `swift run`).
    private func iconImage(for name: String) -> NSImage? {
        if let url = Bundle.main.url(forResource: name, withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        let symbol: String
        switch name {
        case "empty": symbol = "cup.and.saucer"
        case "half": symbol = "cup.and.saucer.fill"
        default: symbol = "cup.and.saucer.fill"
        }
        return NSImage(systemSymbolName: symbol, accessibilityDescription: name)
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
        // Present the menu natively through the status item. The menu is only
        // attached while showing (right click); clearing it afterwards keeps
        // left-click state cycling working and gives the native look/position.
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    func menuDidClose(_ menu: NSMenu) {
        statusItem.menu = nil
    }

    @objc private func selectState(_ sender: NSMenuItem) {
        guard let state = CupState(rawValue: sender.tag) else { return }
        // Defer so the native menu fully closes before any modal work (install
        // authorization / alerts) runs.
        DispatchQueue.main.async { [weak self] in
            self?.changeTo(state)
        }
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
                NSLog("TriCup: helper install failed: %@", String(describing: error))
                showError("无法安装 Helper", "\(error)")
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
            showError("无法切换状态", "\(error)")
        }
        refresh()
    }

    /// Shows a modal alert so install/enable failures are not missed (system
    /// notifications may be suppressed).
    private func showError(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc private func uninstallHelperSelected() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.controller.state == .full {
                if case .failure(let error) = self.controller.setState(.empty) {
                    self.showError("无法恢复电源设置，已取消卸载 Helper", "\(error)")
                    self.refresh()
                    return
                }
            }
            do {
                try self.installer.uninstall()
            } catch {
                NSLog("TriCup: helper uninstall failed: %@", String(describing: error))
                self.showError("卸载 Helper 失败", "\(error)")
            }
            self.refresh()
        }
    }

    @objc private func toggleLoginItem() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let enable = !self.loginItemManager.isEnabled
            do {
                try self.loginItemManager.setEnabled(enable)
            } catch {
                self.showError("无法更新登录项", "\(error)")
            }
            self.refresh()
        }
    }

    @objc private func quitSelected() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            // Best-effort: returning to empty releases the lease before quitting.
            if self.controller.state != .empty {
                _ = self.controller.setState(.empty)
            }
            NSApp.terminate(nil)
        }
    }
}
