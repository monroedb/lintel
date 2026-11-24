import Foundation
import LintelCore

/// Settings › General › "Show in menu bar": on by default,
/// stored in the settings domain (so it survives restarts and reinstalls), and every change is
/// announced under the key's name, which is what the menu-bar item listens for.
@MainActor
func runMenuBarItemChecks() {
    check(Keys.showMenuBarItem.name == "app.showMenuBarItem" && Keys.showMenuBarItem.defaultValue,
          "the menu-bar item is shown by default (app.showMenuBarItem)")
    check(!Keys.placementKeyNames.contains(Keys.showMenuBarItem.name), "showing or hiding the item doesn't re-plan the islands")

    let suite = "lintel-checks-menubar-\(ProcessInfo.processInfo.processIdentifier)"
    guard let defaults = UserDefaults(suiteName: suite) else {
        check(false, "scratch defaults suite")
        return
    }
    let center = NotificationCenter()
    let recorder = AnnouncedKeys()
    let observer = center.addObserver(forName: .lintelSettingDidChange, object: nil, queue: nil) { note in
        recorder.keys.append(note.userInfo?["key"] as? String ?? "?")
    }
    var announced: [String] { recorder.keys }
    let store = SettingsStore(defaults: defaults, center: center)
    check(store[Keys.showMenuBarItem] && !store.hasValue(for: Keys.showMenuBarItem), "nothing stored → shown")
    store[Keys.showMenuBarItem] = false
    check((defaults.object(forKey: Keys.showMenuBarItem.name) as? NSNumber)?.boolValue == false,
          "hiding stores false under app.showMenuBarItem")
    check(announced == [Keys.showMenuBarItem.name], "the change is announced under the key's name")
    check(SettingsStore(defaults: defaults, center: NotificationCenter())[Keys.showMenuBarItem] == false,
          "a new store over the same domain (a restart) still reads hidden")
    store[Keys.showMenuBarItem] = true
    check(store[Keys.showMenuBarItem] && announced.count == 2, "shown again, announced again")
    store.externalChange()
    check(announced.last == "*", "an outside change is announced as \"*\" (the item re-reads the key)")
    for (text, expected) in [("NO", false), ("0", false), ("YES", true), ("maybe", true)] {
        defaults.set(text, forKey: Keys.showMenuBarItem.name)
        check(store[Keys.showMenuBarItem] == expected, "launch-argument value \(text) → \(expected ? "shown" : "hidden")")
    }
    center.removeObserver(observer)
    defaults.removePersistentDomain(forName: suite)
}

/// Keys announced by a settings store (posted synchronously on the checks' thread).
private final class AnnouncedKeys: @unchecked Sendable {
    var keys: [String] = []
}
