import AppKit
import LintelCore
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    init(settings: SettingsStore, loginItems: LoginItemService) {
        let root = SettingsRootView(settings: settings, loginItems: loginItems)
        let hosting = NSHostingController(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Lintel Settings"
        // The title bar keeps the system's background: with a transparent one, a page's title (shown in
        // the toolbar) was drawn straight over the rows scrolling under it. Now the toolbar draws its own
        // blurred bar with a divider, and rows scroll under it.
        window.toolbarStyle = .unified
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: 720, height: 560))
        window.minSize = NSSize(width: 640, height: 460)
        window.isReleasedWhenClosed = false
        if let frame = Self.lastFrame { window.setFrame(frame, display: false) } else { window.center() }
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("not used") }

    /// Called when the window closes.
    var onClose: (() -> Void)?
    /// Where the window was when it was released: a new one opens there (as the kept one did).
    private static var lastFrame: NSRect?

    func present() {
        NSApp.activate()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    var isVisible: Bool { window?.isVisible == true }

    func windowWillClose(_ notification: Notification) {
        if let frame = window?.frame { Self.lastFrame = frame }
        onClose?()
    }
}

extension SettingsStore {
    /// SwiftUI binding for a settings key.
    func binding<Value: SettingValue>(_ key: SettingKey<Value>) -> Binding<Value> {
        Binding(get: { self[key] }, set: { self[key] = $0 })
    }
}
