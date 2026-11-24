import AppKit
import LintelCore
import Observation

/// Keyboard for the Ruler picker without stealing focus (the same rule as the Shelf page). The island
/// panel never becomes key, so an invisible, non-activating 1 × 1 pt panel under the notch takes the
/// keyboard only while an island is open on the ruler with the pointer inside it. A non-activating
/// panel takes keys without activating Lintel, so the frontmost app and its menu bar stay; ordering
/// it out hands key focus back to that app's window.
@MainActor
final class TimerRulerKeyboard {
    private weak var feature: TimerFeature?
    private var panel: RulerKeyPanel?
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    private var focusTask: Task<Void, Never>?
    private var trackedModels: Set<ObjectIdentifier> = []
    private var trackingCenter = false
    /// A key that isn't the ruler's handed the keyboard back until the pointer leaves the island.
    private(set) var gaveBack = false
    /// Times the panel took and gave back the keyboard, and the last keys.
    private(set) var takes = 0
    private(set) var releases = 0
    private(set) var keys: [String] = []

    var isHeld: Bool { panel?.isVisible == true }
    var isKey: Bool { panel?.isKeyWindow == true }

    init(feature: TimerFeature) {
        self.feature = feature
    }

    func start() {
        // Checked on the next turn of the run loop, after the islands have followed the same move.
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseUp]
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.update() } }
        }) { monitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.update() } }
            return event
        }) { monitors.append(monitor) }
        // Another app came to the front: its keystrokes must reach it.
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let other = app?.processIdentifier != ProcessInfo.processInfo.processIdentifier
            MainActor.assumeIsolated {
                guard other, let self, self.isHeld else { return }
                self.gaveBack = true
                self.update()
            }
        })
        update()
    }

    /// The island open on the ruler with the pointer inside, if any.
    var focusedIsland: IslandController? {
        guard let feature, feature.center.showsRuler else { return nil }
        return feature.coordinator?.controllers.values.first {
            $0.model.phase == .expanded && $0.model.expandedContent == .timer && $0.pointerInside
        }
    }

    func update() {
        track()
        let island = focusedIsland
        if island == nil { gaveBack = false }
        let wants = RulerKeyboard.wantsFocus(rulerOpen: island != nil, pointerInside: island != nil, gaveBack: gaveBack)
        if wants != isHeld { set(wants, near: island) }
        if wants, focusTask == nil {
            // While it holds the keyboard, re-check 10 times a second (the island can close or a timer
            // start without the pointer moving).
            focusTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(100))
                    guard let self, !Task.isCancelled else { return }
                    self.update()
                    if !self.isHeld { break }
                }
                self?.focusTask = nil
            }
        }
    }

    private func handle(_ event: NSEvent) {
        let flags = event.modifierFlags
        let action = RulerKeyAction.from(keyCode: event.keyCode, shift: flags.contains(.shift), command: flags.contains(.command),
                                         option: flags.contains(.option), control: flags.contains(.control))
        keys.append("\(event.keyCode)\(flags.contains(.shift) ? "⇧" : "")→\(action)")
        if keys.count > 20 { keys.removeFirst(keys.count - 20) }
        guard let island = focusedIsland else {
            update()
            return
        }
        switch action {
        case .close:
            island.performClose()
        case .other:
            gaveBack = true
        case .step, .previousFive, .nextFive, .start:
            island.model.timerRuler.key(action)
        }
        update()
    }

    private func set(_ held: Bool, near island: IslandController?) {
        if held {
            let panel = self.panel ?? makePanel()
            if let island, let screen = NSScreen.screens.first(where: { $0.displayUUID == island.plan.screenUUID }) {
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

    private func makePanel() -> RulerKeyPanel {
        let panel = RulerKeyPanel(contentRect: CGRect(x: 0, y: 0, width: 1, height: 1),
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
        panel.onKey = { [weak self] event in self?.handle(event) }
        self.panel = panel
        return panel
    }

    /// Follows each island's phase and page and whether the ruler shows, so the keyboard also goes
    /// back when the island closes or a timer starts under a still pointer.
    private func track() {
        guard let feature else { return }
        for island in feature.coordinator?.controllers.values ?? [:].values {
            let model = island.model
            let key = ObjectIdentifier(model)
            guard !trackedModels.contains(key) else { continue }
            trackedModels.insert(key)
            withObservationTracking {
                _ = model.phase
                _ = model.expandedContent
            } onChange: { [weak self] in
                Task { @MainActor [weak self] in
                    self?.trackedModels.remove(key)
                    self?.update()
                }
            }
        }
        if !trackingCenter {
            trackingCenter = true
            let center = feature.center
            withObservationTracking {
                _ = center.showsRuler
            } onChange: { [weak self] in
                Task { @MainActor [weak self] in
                    self?.trackingCenter = false
                    self?.update()
                }
            }
        }
    }
}

/// The key-catching panel. Every key equivalent stops here, so ⌘Q, ⌘W and the like never reach
/// Lintel's menus by accident; keys that aren't the ruler's hand the keyboard back.
final class RulerKeyPanel: NSPanel {
    var onKey: ((NSEvent) -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) { onKey?(event) }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return true }
        onKey?(event)
        return true
    }
}
