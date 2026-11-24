import Foundation

// When Lintel may do repeating work: event-driven detection
// instead of steady polls, and nothing that only matters to the eye while nobody can see it.

/// Full-screen detection in bursts. A full-screen space only comes or goes with a space change or an
/// app activation (or quit, a display change, Mission Control leaving, wake, unlock); from such a
/// trigger the window list is polled at 4 Hz until full screen has been seen the same on two
/// consecutive polls (space switches animate) and `settleWindow` has passed since the last trigger.
/// Between bursts nothing is polled (it was a steady 4 Hz poll).
public struct FullScreenBurst: Equatable, Sendable {
    public static let pollInterval = 0.25
    public static let settleWindow = 2.0

    /// Uptime until which the burst goes on at least.
    public private(set) var until: Double = 0

    public init() {}

    public mutating func trigger(now: Double) {
        until = now + Self.settleWindow
    }

    /// After a poll: whether the burst may end. Mission Control hides the full-screen app, so a burst
    /// ends while it shows (a new one starts when it leaves).
    public func ends(now: Double, settled: Bool, missionControl: Bool) -> Bool {
        missionControl || (now >= until && settled)
    }
}

/// The Mission Control watcher looks 30 times a second only while Mission Control could open on the
/// user's input (its keys, a trackpad swipe, a hot corner, its Dock icon): after `restAfter` seconds
/// without input — unless Mission Control's windows are up — it looks once a second, and an event
/// tap brings back 30 Hz on the next input event, before the system acts on it.
public enum MissionControlRest {
    public static let restAfter = 4.0
    /// While resting the watcher still looks once a second: Mission Control opened by a script or
    /// a Shortcut, with no input at all, is seen within a second (its launcher announces nothing
    /// on macOS 27). Any input brings back the 30 Hz looks at once.
    public static let restingInterval = 1.0
    /// The idle check runs once every this many looks (once a second at 30 Hz).
    public static let looksPerCheck = 30

    public static func shouldRest(secondsSinceInput: Double, overlay: Bool, bar: Bool, knownWindows: Int) -> Bool {
        !overlay && !bar && knownWindows == 0 && secondsSinceInput >= restAfter
    }

    /// Event types (CGEventType raw values) that a program posts only to act for the user: key
    /// presses, mouse button presses, scrolling, the media and Mission Control keys
    /// (system-defined), trackpad gestures.
    public static let deliberateTypes: Set<UInt32> = [10, 1, 3, 25, 22, 14, 18, 19, 20, 29, 30, 31, 32, 33, 34, 37]

    /// Whether an event wakes the resting watcher: any input from the hardware (source PID 0), and
    /// deliberate input a program posts (a tool sending ⌃↑, a script's key). Not the null events and
    /// modifier or pointer echoes some apps post by themselves (one on the user's Mac posts null
    /// events). A tap the system switched off for being slow (0xFFFFFFFE) can't see input meanwhile,
    /// so that counts as input; "disabled by user input" (0xFFFFFFFF) is what switching the tap off
    /// ourselves sends, and counting it as input made the tap switch itself off again and again.
    public static func wakes(eventType: UInt32, sourcePID: Int64) -> Bool {
        if eventType == 0 || eventType == 0xFFFF_FFFF { return false }
        if eventType == 0xFFFF_FFFE { return true }
        return sourcePID == 0 || deliberateTypes.contains(eventType)
    }
}

/// Whether an island shows a media waveform: the live waveform's audio tap runs only while some
/// island does.
public enum MediaWaveformDemand {
    /// - Parameters:
    ///   - onScreen: the island isn't hidden by a rule and the displays are awake and unlocked.
    ///   - focusGlyphReplaces: a Focus glyph takes the compact waveform's place.
    ///   - compactWaveform: the compact waveform isn't switched off in Settings.
    public static func shows(onScreen: Bool, tucked: Bool, expanded: Bool, expandedContent: ExpandedContent,
                             displayed: CompactPresentation, focusGlyphReplaces: Bool, compactWaveform: Bool) -> Bool {
        guard onScreen, !tucked else { return false }
        // The open player has its own waveform.
        if expanded { return expandedContent == .media || expandedContent == .both }
        switch displayed {
        case .live(let kinds):
            // The timer's countdown or the calendar ring takes the trailing slot.
            return kinds.contains(.media) && !kinds.contains(.timer) && !kinds.contains(.calendar)
                && !focusGlyphReplaces && compactWaveform
        case .peek(let kind):
            return kind == .media && compactWaveform
        default:
            return false
        }
    }
}

/// Live waveform bars move only when the change can be seen: a Core Animation commit (a message to
/// the window server) for every level set, ~30 a second, is skipped when no bar would move by
/// `minimumStep` points (half a pixel on a 2× display).
public enum WaveformStep {
    public static let minimumStep = 0.25

    public static func isVisible(_ heights: [Double], from shown: [Double]) -> Bool {
        guard heights.count == shown.count else { return true }
        return zip(heights, shown).contains { abs($0 - $1) >= minimumStep }
    }
}

/// How often the Focus provider's timer fires (nil = no timer). The status center is polled only
/// when it can be trusted (entitlement and access); the database is read when its file watchers
/// fire, with a cheap check of the files' size and date every `databaseSafety` seconds in case a
/// watcher missed a change, or a retry every `databaseRetry` seconds while it can't be read.
public enum FocusPolling {
    public static let status = 0.25
    public static let access = 5.0
    public static let databaseRetry = 5.0
    public static let databaseSafety = 10.0

    public static func interval(detection: FocusDetection, databaseConfigured: Bool, databaseReadable: Bool,
                                entitled: Bool, authorized: Bool) -> Double? {
        if detection == .system { return status }
        if databaseConfigured { return databaseReadable ? databaseSafety : databaseRetry }
        // Access is only worth re-checking when it could be used (with the entitlement).
        return entitled && !authorized ? access : nil
    }
}
