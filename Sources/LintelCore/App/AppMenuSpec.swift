/// Lintel's application menu. Lintel is a background app, so macOS never draws this menu bar, but AppKit
/// still routes key equivalents through `NSApp.mainMenu` while Lintel is active (Settings or About
/// in front). Without it ⌘Q, ⌘W, ⌘, and the editing shortcuts did nothing there.
public enum AppMenuCommand: String, CaseIterable, Sendable {
    case about, settings, hide, hideOthers, showAll, quit
    case undo, redo, cut, copy, paste, selectAll
    case minimize, close
}

public struct AppMenuModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let command = AppMenuModifiers(rawValue: 1)
    public static let option = AppMenuModifiers(rawValue: 2)
    public static let shift = AppMenuModifiers(rawValue: 4)
}

public struct AppMenuItemSpec: Equatable, Sendable {
    public let command: AppMenuCommand
    public let title: String
    /// Key equivalent ("" for none).
    public let key: String
    public let modifiers: AppMenuModifiers

    public init(_ command: AppMenuCommand, _ title: String, key: String = "", modifiers: AppMenuModifiers = .command) {
        self.command = command
        self.title = title
        self.key = key
        self.modifiers = key.isEmpty ? [] : modifiers
    }
}

public struct AppMenuSection: Equatable, Sendable {
    public let title: String
    /// nil entries are separators.
    public let items: [AppMenuItemSpec?]
}

public enum AppMenuSpec {
    public static let sections: [AppMenuSection] = [
        AppMenuSection(title: "Lintel", items: [
            AppMenuItemSpec(.about, "About Lintel"),
            nil,
            AppMenuItemSpec(.settings, "Settings…", key: ","),
            nil,
            AppMenuItemSpec(.hide, "Hide Lintel", key: "h"),
            AppMenuItemSpec(.hideOthers, "Hide Others", key: "h", modifiers: [.command, .option]),
            AppMenuItemSpec(.showAll, "Show All"),
            nil,
            AppMenuItemSpec(.quit, "Quit Lintel", key: "q"),
        ]),
        AppMenuSection(title: "Edit", items: [
            AppMenuItemSpec(.undo, "Undo", key: "z"),
            AppMenuItemSpec(.redo, "Redo", key: "z", modifiers: [.command, .shift]),
            nil,
            AppMenuItemSpec(.cut, "Cut", key: "x"),
            AppMenuItemSpec(.copy, "Copy", key: "c"),
            AppMenuItemSpec(.paste, "Paste", key: "v"),
            AppMenuItemSpec(.selectAll, "Select All", key: "a"),
        ]),
        AppMenuSection(title: "Window", items: [
            AppMenuItemSpec(.minimize, "Minimize", key: "m"),
            AppMenuItemSpec(.close, "Close", key: "w"),
        ]),
    ]

    public static var items: [AppMenuItemSpec] { sections.flatMap { $0.items.compactMap { $0 } } }

    public static func item(for command: AppMenuCommand) -> AppMenuItemSpec? {
        items.first { $0.command == command }
    }
}
