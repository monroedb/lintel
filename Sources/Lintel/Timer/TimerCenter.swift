import Foundation
import LintelCore
import Observation

/// What the islands, menus and Settings show of the timer, and the entry point for their actions.
/// `TimerFeature` owns the behaviour and publishes its state here;
/// the hub owns this object (`hub.timer`) so island views reach it like `hub.nowPlaying`.
@MainActor
@Observable
final class TimerCenter {
    enum Action: Equatable {
        case start(seconds: Double)
        case pause
        case resume
        case togglePause
        /// "+1 min" (links may add other amounts).
        case add(seconds: Double)
        case restart
        /// Cancel (running or paused) or stop (ringing or done).
        case cancel
        /// Open the custom-duration window.
        case custom
        /// Start from the Ruler picker (Start Timer, Return, a quick-preset pill): also remembered as
        /// the picker's last used duration.
        case pick(minutes: Int)

        static var addMinute: Action { .add(seconds: TimerPolicy().addStep) }
    }

    /// The timer, or nil.
    private(set) var state: TimerState?
    /// The alert while it rings.
    private(set) var alert: TimerAlert?
    /// Rings played since launch; each one shakes the bell once.
    private(set) var ringCount = 0
    /// Timers switched on in Settings.
    private(set) var enabled = true
    /// Settings › Timer › Picker style, the quick presets and the ruler's last used minutes,
    /// published by `TimerFeature`.
    private(set) var pickerStyle: TimerPickerStyle = .ruler
    private(set) var presets: [Int] = TimerQuickPresets.standard.minutes
    private(set) var rulerMinutes = TimerRulerScale.defaultMinutes

    /// The open island's timer page shows the Ruler picker (no timer, Timers on, Ruler style).
    var showsRuler: Bool { enabled && state == nil && pickerStyle == .ruler }

    /// Receives every action (set by `TimerFeature`).
    @ObservationIgnored var onAction: ((Action) -> Void)?
    /// Called when the live activity's identity changes (nil: no timer).
    @ObservationIgnored var onLiveChange: ((String?) -> Void)?

    /// Identity of the timer live activity (changes with every user change and at the end).
    var liveIdentity: String? { state?.identity }
    var isRinging: Bool { alert != nil }

    func perform(_ action: Action) { onAction?(action) }

    /// The island dismissed the timer (vertical swipe): that stops an ended timer, like swiping an
    /// alert away; a running or paused one is only hidden by the island.
    func dismissedFromIsland() {
        if state?.isFinished == true { perform(.cancel) }
    }

    // MARK: Written by TimerFeature

    func publish(state newState: TimerState?, alert newAlert: TimerAlert?, enabled isEnabled: Bool) {
        let previousIdentity = liveIdentity
        if state != newState { state = newState }
        if alert != newAlert { alert = newAlert }
        if enabled != isEnabled { enabled = isEnabled }
        if liveIdentity != previousIdentity { onLiveChange?(liveIdentity) }
    }

    func publishPicker(style: TimerPickerStyle, presets newPresets: [Int], rulerMinutes minutes: Int) {
        if pickerStyle != style { pickerStyle = style }
        if presets != newPresets { presets = newPresets }
        if rulerMinutes != minutes { rulerMinutes = minutes }
    }

    func rang() { ringCount &+= 1 }
}
