import Foundation

/// Text of the timer.
public enum TimerFormat {
    /// `M:SS` under an hour (`4:59`, `24:59`, `0:09`), `H:MM:SS` from an hour.
    public static func clock(_ seconds: Int) -> String {
        let value = max(0, seconds)
        let hours = value / 3600, minutes = value % 3600 / 60, secs = value % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, secs) }
        return String(format: "%d:%02d", minutes, secs)
    }

    /// A duration in words: `25 min`, `1 h 30 min`, `90 s` → `1 min 30 s`, `45 s`.
    public static func duration(_ seconds: Double) -> String {
        let value = max(0, Int(seconds.rounded()))
        let hours = value / 3600, minutes = value % 3600 / 60, secs = value % 60
        var parts: [String] = []
        if hours > 0 { parts.append("\(hours) h") }
        if minutes > 0 { parts.append("\(minutes) min") }
        if secs > 0 || parts.isEmpty { parts.append("\(secs) s") }
        return parts.joined(separator: " ")
    }

    /// `25 min timer`.
    public static func title(preset seconds: Double) -> String { "\(duration(seconds)) timer" }

    /// Menu item for a preset: `1 Minute`, `25 Minutes`.
    public static func presetMenuTitle(minutes: Int) -> String { minutes == 1 ? "1 Minute" : "\(minutes) Minutes" }

    /// The note on a late alert, from `TimerPolicy.lateNoteFrom` on: `Ended 3 min ago`.
    public static func lateNote(_ late: Double, policy: TimerPolicy = TimerPolicy()) -> String? {
        guard late >= policy.lateNoteFrom else { return nil }
        let minutes = Int((late / 60).rounded())
        return minutes < 1 ? "Ended moments ago" : "Ended \(minutes) min ago"
    }

    /// Menu header for a timer: `Timer — 24:59 left`, `Timer — paused, 4:12 left`,
    /// `Timer — time's up`, `Timer — ended at 14:35`.
    public static func menuHeader(_ state: TimerState, ringing: Bool, now: Date, time: (Date) -> String) -> String {
        switch state.phase {
        case .running:
            return "Timer — \(clock(state.shownSeconds(at: now))) left"
        case .paused:
            return "Timer — paused, \(clock(state.shownSeconds(at: now))) left"
        case .finished(let at, _, _):
            return ringing ? "Timer — time's up" : "Timer — ended at \(time(at))"
        }
    }

    /// First tick of a 1 Hz timeline aligned with the end: the countdown changes exactly on the whole
    /// seconds before the end (`end − k`). Always at or before `now`.
    public static func tickAnchor(end: Date, now: Date) -> Date {
        let left = end.timeIntervalSince(now)
        guard left > 0 else { return now }
        return end.addingTimeInterval(-left.rounded(.up))
    }

    /// The hint under the custom-duration field.
    public static func entryHint(for seconds: Double?) -> String {
        guard let seconds else { return "Try 25, 1:30 or 1h 30m — from 1 s to 24 h" }
        return "Starts a \(duration(seconds)) timer"
    }

    /// The custom field's prefill for a stored duration: `20`, `1:30`, `1h 30m`.
    public static func entryText(_ seconds: Double) -> String {
        let value = max(1, Int(seconds.rounded()))
        let hours = value / 3600, minutes = value % 3600 / 60, secs = value % 60
        if hours == 0, secs == 0 { return "\(minutes)" }
        if hours == 0 { return "\(minutes):" + String(format: "%02d", secs) }
        if secs == 0 { return minutes == 0 ? "\(hours)h" : "\(hours)h \(minutes)m" }
        return String(format: "%d:%02d:%02d", hours, minutes, secs)
    }
}
