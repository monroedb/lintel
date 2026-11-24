import AppKit
import LintelCore

/// Installs `NSApp.mainMenu` from `AppMenuSpec`. macOS doesn't show it (Lintel is a background app), but
/// AppKit routes key equivalents through it while Lintel is active, so ⌘Q, ⌘W, ⌘, and the editing
/// shortcuts work in Settings and About.
@MainActor
enum MainMenu {
    static func install(showAbout: @escaping () -> Void, showSettings: @escaping () -> Void) {
        let main = NSMenu(title: "Main")
        for section in AppMenuSpec.sections {
            let menu = NSMenu(title: section.title)
            for spec in section.items {
                guard let spec else {
                    menu.addItem(.separator())
                    continue
                }
                menu.addItem(item(spec, showAbout: showAbout, showSettings: showSettings))
            }
            let top = NSMenuItem(title: section.title, action: nil, keyEquivalent: "")
            top.submenu = menu
            main.addItem(top)
            if section.title == "Window" { NSApp.windowsMenu = menu }
        }
        NSApp.mainMenu = main
    }

    private static func item(_ spec: AppMenuItemSpec, showAbout: @escaping () -> Void,
                             showSettings: @escaping () -> Void) -> NSMenuItem {
        let item: NSMenuItem
        switch spec.command {
        case .about: item = ClosureMenuItem(title: spec.title, key: spec.key, handler: showAbout)
        case .settings: item = ClosureMenuItem(title: spec.title, key: spec.key, handler: showSettings)
        default: item = NSMenuItem(title: spec.title, action: selector(spec.command), keyEquivalent: spec.key)
        }
        var flags: NSEvent.ModifierFlags = []
        if spec.modifiers.contains(.command) { flags.insert(.command) }
        if spec.modifiers.contains(.option) { flags.insert(.option) }
        if spec.modifiers.contains(.shift) { flags.insert(.shift) }
        item.keyEquivalentModifierMask = flags
        return item
    }

    /// Standard actions, sent to the first responder (the application handles the app commands).
    private static func selector(_ command: AppMenuCommand) -> Selector? {
        switch command {
        case .quit: return #selector(NSApplication.terminate(_:))
        case .hide: return #selector(NSApplication.hide(_:))
        case .hideOthers: return #selector(NSApplication.hideOtherApplications(_:))
        case .showAll: return #selector(NSApplication.unhideAllApplications(_:))
        case .undo: return Selector(("undo:"))
        case .redo: return Selector(("redo:"))
        case .cut: return #selector(NSText.cut(_:))
        case .copy: return #selector(NSText.copy(_:))
        case .paste: return #selector(NSText.paste(_:))
        case .selectAll: return #selector(NSText.selectAll(_:))
        case .minimize: return #selector(NSWindow.performMiniaturize(_:))
        case .close: return #selector(NSWindow.performClose(_:))
        case .about, .settings: return nil
        }
    }
}
