import AppKit

/// Borderless, non-activating panel used for the island content and for its backdrop effects.
///
/// Content at `CGShieldingWindowLevel() + 1`, backdrop at
/// `CGShieldingWindowLevel()`; joins all spaces, stationary, ignored by window cycling, allowed
/// over full-screen spaces; never key or main so the island never steals focus.
final class IslandPanel: NSPanel {
    enum Role { case content, backdrop }

    let role: Role

    init(frame: NSRect, role: Role) {
        self.role = role
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .none
        level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + (role == .content ? 1 : 0))
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        // Clicks pass through until the pointer is inside the island (managed by the controller).
        ignoresMouseEvents = true
        acceptsMouseMovedEvents = role == .content
        if role == .backdrop { colorSpace = .extendedSRGB }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
