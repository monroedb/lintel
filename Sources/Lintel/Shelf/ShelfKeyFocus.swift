import AppKit
import LintelCore
import Quartz

/// Keyboard for the Shelf page (Space for Quick Look) without making the island key.
/// An invisible, non-activating 1 × 1 pt panel under the hardware notch
/// becomes key only while the Shelf wants the keyboard. A non-activating panel takes keyboard input
/// without activating Lintel, so the menu bar and the frontmost app stay as they were; ordering it
/// out hands key focus back to the frontmost app's window.
@MainActor
final class ShelfKeyboardFocus {
    private var panel: ShelfKeyPanel?
    var onKey: ((ShelfKey) -> Void)?
    /// Times the panel took and gave back the keyboard.
    private(set) var takes = 0
    private(set) var releases = 0

    var isHeld: Bool { panel?.isVisible == true }
    var isKey: Bool { panel?.isKeyWindow == true }

    func set(_ wanted: Bool, screen: NSScreen?) {
        if wanted {
            guard !isHeld else { return }
            let panel = self.panel ?? makePanel()
            if let screen {
                panel.setFrameOrigin(CGPoint(x: screen.frame.midX, y: screen.frame.maxY - 1))
            }
            panel.orderFrontRegardless()
            panel.makeKey()
            takes += 1
        } else if isHeld {
            panel?.orderOut(nil)
            releases += 1
        }
    }

    private func makePanel() -> ShelfKeyPanel {
        let panel = ShelfKeyPanel(contentRect: CGRect(x: 0, y: 0, width: 1, height: 1),
                                  styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.sharingType = .none
        panel.onKey = { [weak self] key in self?.onKey?(key) }
        self.panel = panel
        return panel
    }
}

/// The key-catching panel. Every key equivalent stops here, so ⌘Q, ⌘W and the like never reach
/// Lintel's own menus by accident; unhandled keys hand the keyboard back.
final class ShelfKeyPanel: NSPanel {
    var onKey: ((ShelfKey) -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        onKey?(Self.key(for: event))
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return true }
        onKey?(Self.key(for: event))
        return true
    }

    private static func key(for event: NSEvent) -> ShelfKey {
        ShelfKey.from(keyCode: event.keyCode, characters: event.charactersIgnoringModifiers,
                      command: event.modifierFlags.contains(.command))
    }
}

/// Quick Look for Shelf items: Quick Look's own preview view in
/// Lintel's floating, non-activating HUD panel. The system Quick Look panel finds its data through the
/// active app's windows, and Lintel never activates; this panel never takes the keyboard either, so
/// Space, ←, → and Escape keep going to the Shelf's key panel.
@MainActor
final class ShelfQuickLook: NSObject, NSWindowDelegate {
    weak var feature: ShelfFeature?
    private(set) var ids: [String] = []
    private var urls: [URL] = []
    private(set) var index = 0
    private(set) var shows = 0
    private var panel: ShelfPreviewPanel?
    private var preview: QLPreviewView?

    var isOpen: Bool { panel?.isVisible == true }
    var currentID: String? { isOpen && ids.indices.contains(index) ? ids[index] : nil }
    var frame: CGRect? { isOpen ? panel?.frame : nil }

    func show(ids requested: [String], start: String, on screen: NSScreen?) {
        guard let feature else { return }
        var ids: [String] = [], urls: [URL] = []
        for id in requested {
            guard let url = feature.previewURL(for: id) else { continue }
            ids.append(id)
            urls.append(url)
        }
        guard let index = ids.firstIndex(of: start) else { return }
        self.ids = ids
        self.urls = urls
        self.index = index
        let panel = self.panel ?? makePanel()
        if !panel.isVisible, let screen = screen ?? NSScreen.main {
            // Centred under the island, clear of the open card.
            let size = CGSize(width: 760, height: 520)
            let visible = screen.visibleFrame
            panel.setFrame(CGRect(x: screen.frame.midX - size.width / 2, y: min(visible.maxY, screen.frame.maxY - 190) - size.height,
                                  width: size.width, height: size.height), display: false)
        }
        display()
        panel.orderFrontRegardless()
        shows += 1
    }

    func close() {
        guard isOpen else { return }
        panel?.orderOut(nil)
        feature?.updateKeyboardFocus()
    }

    func move(by delta: Int) {
        guard isOpen, !ids.isEmpty else { return }
        index = ((index + delta) % ids.count + ids.count) % ids.count
        display()
        feature?.setHover(ids[index])
    }

    /// Items were removed or changed: drop what can't be shown any more.
    func itemsChanged() {
        guard isOpen, let feature else { return }
        let current = currentID
        let remaining = ids.filter { feature.item($0)?.state.isUsable == true }
        guard remaining != ids else { return }
        guard let start = current.flatMap({ remaining.contains($0) ? $0 : nil }) ?? remaining.first else {
            close()
            return
        }
        show(ids: remaining, start: start, on: panel?.screen)
    }

    private func display() {
        guard ids.indices.contains(index) else { return }
        preview?.previewItem = urls[index] as NSURL
        panel?.title = feature?.item(ids[index])?.name ?? urls[index].lastPathComponent
    }

    private func makePanel() -> ShelfPreviewPanel {
        let panel = ShelfPreviewPanel(contentRect: CGRect(x: 0, y: 0, width: 760, height: 520),
                                      styleMask: [.titled, .closable, .resizable, .utilityWindow, .hudWindow, .nonactivatingPanel],
                                      backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.delegate = self
        let preview = QLPreviewView(frame: panel.contentLayoutRect, style: .normal)
        preview?.autoresizingMask = [.width, .height]
        preview?.autostarts = true
        panel.contentView = preview
        self.preview = preview
        self.panel = panel
        return panel
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated { feature?.updateKeyboardFocus() }
    }
}

/// The preview panel never becomes key, so the keyboard stays with the Shelf's key panel.
final class ShelfPreviewPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
