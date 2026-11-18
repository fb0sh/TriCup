import AppKit
import TriCupCore

/// Owns the `NSStatusItem`, its icon, tooltip and right-click menu.
final class StatusBarController: NSObject {
    private let statusItem: NSStatusItem
    private let controller: CupController
    private let menu = NSMenu()
    private var stateItems: [NSMenuItem] = []

    init(controller: CupController) {
        self.controller = controller
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        configureButton()
        buildMenu()
        refresh()
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
        let quit = NSMenuItem(title: "退出 TriCup", action: #selector(quitSelected), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private func refresh() {
        updateIcon()
        updateChecks()
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
            applyChange { controller.cycle() }
        }
    }

    private func showMenu() {
        updateChecks()
        guard let button = statusItem.button else { return }
        _ = menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    @objc private func selectState(_ sender: NSMenuItem) {
        guard let state = CupState(rawValue: sender.tag) else { return }
        applyChange { controller.setState(state) }
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

    @objc private func quitSelected() {
        NSApp.terminate(nil)
    }
}
