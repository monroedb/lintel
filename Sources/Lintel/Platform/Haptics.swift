import AppKit
import LintelCore

/// Trackpad haptics, debounced so a burst of triggers produces a single tick
/// (setting "Haptic feedback").
@MainActor
final class Haptics {
    private let settings: SettingsStore
    private var gate = HapticGate()
    /// Ticks actually performed.
    private(set) var performed = 0
    private(set) var dropped = 0

    init(settings: SettingsStore) {
        self.settings = settings
    }

    func perform(_ pattern: NSHapticFeedbackManager.FeedbackPattern = .alignment) {
        guard settings[Keys.haptics] else { return }
        guard gate.shouldFire(now: ProcessInfo.processInfo.systemUptime) else {
            dropped += 1
            return
        }
        performed += 1
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }

    /// Ruler ticks: `alignment` for a minute, the stronger
    /// `levelChange` for a 5-minute mark. Not debounced here: the ruler already limits them to one
    /// per 25 ms, and the 0.12 s gate would drop most of them.
    private(set) var lightTicks = 0
    private(set) var strongTicks = 0

    func tick(strong: Bool) {
        guard settings[Keys.haptics] else { return }
        if strong { strongTicks += 1 } else { lightTicks += 1 }
        NSHapticFeedbackManager.defaultPerformer.perform(strong ? .levelChange : .alignment, performanceTime: .now)
    }
}
