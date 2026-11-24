import AppKit
import LintelCore

/// The timer's menu items: the island's context menu and the menu bar's
/// **Timer** submenu, which is rebuilt each time it opens.
@MainActor
enum TimerMenu {
    /// Adds the timer items to an island's context menu (before "Settings…").
    static func append(to menu: NSMenu, island: IslandController) {
        guard island.settings[Keys.timerEnabled] else { return }
        let center = island.hub.timer
        if let last = menu.items.last, !last.isSeparatorItem { menu.addItem(.separator()) }
        controlItems(center).forEach(menu.addItem)
        let start = NSMenuItem(title: center.state == nil ? "Start Timer" : "Start New Timer", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: start.title)
        presetItems(center).forEach(submenu.addItem)
        start.submenu = submenu
        menu.addItem(start)
        menu.addItem(.separator())
    }

    /// Header and controls of the current timer (empty without one).
    static func controlItems(_ center: TimerCenter) -> [NSMenuItem] {
        guard let state = center.state else { return [] }
        let header = NSMenuItem(title: TimerFormat.menuHeader(state, ringing: center.isRinging, now: Date()) {
            $0.formatted(date: .omitted, time: .shortened)
        }, action: nil, keyEquivalent: "")
        header.isEnabled = false
        var items = [header]
        switch state.phase {
        case .running: items.append(ClosureMenuItem(title: "Pause Timer", key: "") { center.perform(.pause) })
        case .paused: items.append(ClosureMenuItem(title: "Resume Timer", key: "") { center.perform(.resume) })
        case .finished: items.append(ClosureMenuItem(title: "Stop Timer", key: "") { center.perform(.cancel) })
        }
        items.append(ClosureMenuItem(title: "Add 1 Minute", key: "") { center.perform(.addMinute) })
        items.append(ClosureMenuItem(title: "Restart Timer", key: "") { center.perform(.restart) })
        if !state.isFinished {
            items.append(ClosureMenuItem(title: "Cancel Timer", key: "") { center.perform(.cancel) })
        }
        return items
    }

    /// The quick presets (Settings › Timer, default 3, 5 and 10 minutes),
    /// then Custom….
    static func presetItems(_ center: TimerCenter) -> [NSMenuItem] {
        var items: [NSMenuItem] = center.presets.map { minutes in
            ClosureMenuItem(title: TimerFormat.presetMenuTitle(minutes: minutes), key: "") {
                center.perform(.start(seconds: Double(minutes * 60)))
            }
        }
        if !items.isEmpty { items.append(.separator()) }
        items.append(ClosureMenuItem(title: "Custom…", key: "") { center.perform(.custom) })
        return items
    }

    // MARK: Menu-bar item

    private static var statusItems: [NSMenuItem] = []
    private static let statusDelegate = StatusSubmenuDelegate()

    /// "Timer ▸" and a separator for the menu-bar menu; hidden while Timers are switched off.
    static func statusMenuItems() -> [NSMenuItem] {
        let item = NSMenuItem(title: "Timer", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Timer")
        submenu.delegate = statusDelegate
        item.submenu = submenu
        statusItems = [item, .separator()]
        setStatusItemsVisible(TimerFeature.shared?.settings[Keys.timerEnabled] ?? true)
        return statusItems
    }

    static func setStatusItemsVisible(_ visible: Bool) {
        statusItems.forEach { $0.isHidden = !visible }
    }

    static var statusItemsVisible: Bool { statusItems.first.map { !$0.isHidden } ?? false }

    /// Fills the menu-bar submenu when it opens: controls, then the presets directly.
    fileprivate static func fillStatusSubmenu(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let center = TimerFeature.shared?.center else { return }
        let controls = controlItems(center)
        controls.forEach(menu.addItem)
        if !controls.isEmpty {
            menu.addItem(.separator())
            let caption = NSMenuItem(title: "Start New Timer", action: nil, keyEquivalent: "")
            caption.isEnabled = false
            menu.addItem(caption)
        }
        presetItems(center).forEach(menu.addItem)
    }
}

private final class StatusSubmenuDelegate: NSObject, NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        MainActor.assumeIsolated { TimerMenu.fillStatusSubmenu(menu) }
    }
}
