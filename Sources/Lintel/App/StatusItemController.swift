import AppKit
import LintelCore

/// Menu-bar item with Lintel's own glyph and a small menu. Settings › General › "Show in menu bar"
/// hides and shows it at once. Hiding keeps the item (`isVisible`), so it comes back in the same
/// place; while it's hidden, Settings is reached from the island's right-click menu or by opening
/// Lintel again (AppDelegate.applicationShouldHandleReopen).
///
/// macOS keeps the item's visibility itself (`NSStatusItem VisibleCC …` in the settings domain, restored
/// at launch), and on macOS 26+ the system's own menu-bar settings hide items too. So Lintel never forces
/// the item visible at launch (that could undo a hide made outside Lintel): it only hides it when the
/// switch is off, and the switch follows the item when it starts hidden or is hidden or shown outside
/// Lintel.
@MainActor
final class StatusItemController: NSObject {
    private let item: NSStatusItem
    private let settings: SettingsStore
    private let openSettings: () -> Void
    private let showAbout: () -> Void
    private var appearanceObservation: NSKeyValueObservation?
    private var visibilityObservation: NSKeyValueObservation?
    private var settingsObserver: NSObjectProtocol?
    /// Whether the item has been in the menu bar this session: only then does its button carry the
    /// menu bar's appearance (an item hidden since launch reports Lintel's own appearance).
    private var appearanceFromMenuBar: Bool
    /// Called when the menu bar switches between light and dark content.
    var onMenuBarAppearanceChange: (() -> Void)?

    init(settings: SettingsStore, openSettings: @escaping () -> Void, showAbout: @escaping () -> Void) {
        self.settings = settings
        self.openSettings = openSettings
        self.showAbout = showAbout
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        // Before the menu bar first draws it, so a hidden item never flashes at launch.
        if !settings[Keys.showMenuBarItem] { item.isVisible = false }
        self.item = item
        appearanceFromMenuBar = item.isVisible
        super.init()
        item.button?.image = Brand.statusItemImage()
        item.button?.toolTip = "Lintel"
        item.button?.setAccessibilityLabel("Lintel")
        item.menu = makeMenu()
        appearanceObservation = item.button?.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.onMenuBarAppearanceChange?() }
        }
        visibilityObservation = item.observe(\.isVisible, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.visibilityDidChange() }
        }
        settingsObserver = NotificationCenter.default.addObserver(forName: .lintelSettingDidChange, object: settings,
                                                                  queue: .main) { [weak self] note in
            let key = note.userInfo?["key"] as? String
            MainActor.assumeIsolated { self?.settingDidChange(key) }
        }
        // Started hidden by macOS (AppKit restored a hidden item): the switch shows it as off.
        followItem()
    }

    /// Whether the item is in the menu bar (Settings › General › "Show in menu bar").
    var isShown: Bool { item.isVisible }

    private func settingDidChange(_ key: String?) {
        guard key == nil || key == "*" || key == Keys.showMenuBarItem.name else { return }
        let show = settings[Keys.showMenuBarItem]
        guard item.isVisible != show else { return }
        item.isVisible = show
        Log.app.notice("Menu bar item \(show ? "shown" : "hidden", privacy: .public)")
    }

    private func visibilityDidChange() {
        if item.isVisible, !appearanceFromMenuBar {
            appearanceFromMenuBar = true
            onMenuBarAppearanceChange?()
        }
        followItem()
    }

    /// The switch follows the item when its visibility changed outside Lintel.
    private func followItem() {
        guard settings[Keys.showMenuBarItem] != item.isVisible else { return }
        Log.app.notice("Menu bar item \(self.item.isVisible ? "shown" : "hidden", privacy: .public) by macOS; the switch follows")
        settings[Keys.showMenuBarItem] = item.isVisible
    }

    /// Whether the menu bar draws light content on a dark backdrop. macOS adapts the menu bar to what
    /// is behind it (the desktop picture), so this is a coarse, permission-free backdrop signal. Unknown
    /// (nil) while the item hasn't been in the menu bar this session; once it has, a hidden item keeps
    /// the appearance it last had there.
    var menuBarIsDark: Bool? {
        guard appearanceFromMenuBar, let appearance = item.button?.effectiveAppearance else { return nil }
        guard let match = appearance.bestMatch(from: [.aqua, .darkAqua, .vibrantLight, .vibrantDark]) else { return nil }
        return match == .darkAqua || match == .vibrantDark
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(title: "About Lintel", key: "") { [weak self] in self?.showAbout() })
        menu.addItem(.separator())
        TimerMenu.statusMenuItems().forEach(menu.addItem)
        menu.addItem(ClosureMenuItem(title: "Settings…", key: ",") { [weak self] in self?.openSettings() })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Quit Lintel", key: "q") { NSApp.terminate(nil) })
        return menu
    }
}
