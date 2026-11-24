import AppKit
import LintelCore

/// Keeps every island's panels in the dedicated window-server space, or leaves them to the public
/// behaviour:
///
/// * held while the capability is on and available, so Space switches and full-screen transitions
///   slide the desktops underneath a still island;
/// * back in the normal Spaces while the session is locked (the lock screen covers them, as before);
/// * nothing here reacts to Space changes: the panels are never re-created or re-ordered for one.
@MainActor
final class IslandSpaces {
    private let settings: SettingsStore
    let provider: WindowSpaceProvider
    /// Panels per island controller.
    private var panels: [ObjectIdentifier: [NSWindow]] = [:]
    private var locked = false
    private(set) var mode: IslandSpaceMode = .allSpaces
    private(set) var reason: IslandSpaceReason = .switchedOff
    /// Mode changes with their cause.
    private(set) var log: [String] = []

    init(settings: SettingsStore, provider: WindowSpaceProvider) {
        self.settings = settings
        self.provider = provider
    }

    // MARK: Panels

    func adopt(_ windows: [NSWindow], for island: AnyObject) {
        panels[ObjectIdentifier(island)] = windows
        if mode == .dedicatedSpace, provider.hold(windows.map(\.windowNumber)) { return }
        apply("adopt")
    }

    func release(for island: AnyObject) {
        guard let windows = panels.removeValue(forKey: ObjectIdentifier(island)) else { return }
        provider.release(windows.map(\.windowNumber))
    }

    /// Adds the panels again (displays changed); a no-op for panels already in the space.
    func reassert() {
        guard mode == .dedicatedSpace else { return }
        if !provider.hold(allWindowNumbers) { apply("reassert failed") }
    }

    private var allWindowNumbers: [Int] { panels.values.flatMap { $0.map(\.windowNumber) } }

    // MARK: Inputs

    func setLocked(_ isLocked: Bool) {
        guard locked != isLocked else { return }
        locked = isLocked
        apply(isLocked ? "locked" : "unlocked")
    }

    func settingChanged() {
        provider.reload()
        apply("setting")
    }

    /// Quit: the panels leave the space and the space is destroyed.
    func stop() {
        provider.invalidate()
        mode = .allSpaces
    }

    // MARK: Applying

    private func apply(_ cause: String) {
        var decision = IslandSpacePolicy.decide(switchedOn: settings[Keys.windowSpaceCapability],
                                                available: provider.isAvailable, locked: locked)
        let numbers = allWindowNumbers
        if decision.mode == .dedicatedSpace, !provider.hold(numbers) {
            decision = (.allSpaces, .unavailable)
        }
        if decision.mode == .allSpaces { provider.release(numbers) }
        if decision.mode != mode || decision.reason != reason {
            log.append(String(format: "%.3f ", ProcessInfo.processInfo.systemUptime)
                       + "\(cause): \(mode.rawValue) → \(decision.mode.rawValue) (\(decision.reason.rawValue))")
            if log.count > 40 { log.removeFirst(log.count - 40) }
        }
        mode = decision.mode
        reason = decision.reason
    }
}
