import AppKit

// Lintel is a background app (LSUIElement): no Dock icon, no main menu bar of its own.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
    withExtendedLifetime(delegate) {}
}
