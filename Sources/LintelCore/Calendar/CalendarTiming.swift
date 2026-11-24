import Foundation

/// Time-to-leave decisions: alert once per event when
/// now ≥ start − travel time − buffer.
public enum TimeToLeavePlanner {
    /// Only events starting within this window get a travel-time estimate.
    public static let horizon: TimeInterval = 4 * 3600
    /// Travel estimates are refreshed this often while an event is pending.
    public static let refreshInterval: TimeInterval = 10 * 60

    /// Upcoming timed events with a physical place that haven't had their alert yet, soonest first.
    public static func candidates(events: [CalendarEventRecord], now: Date, alerted: Set<String>) -> [CalendarEventRecord] {
        events
            .filter { $0.isVisible && !$0.isAllDay && $0.start > now && $0.start.timeIntervalSince(now) <= horizon }
            .filter { !alerted.contains($0.id) && hasPlace($0) }
            .sorted { $0.start < $1.start }
    }

    /// Whether the event names somewhere to travel to (coordinates, or a location that isn't a link).
    public static func hasPlace(_ event: CalendarEventRecord) -> Bool {
        if event.latitude != nil, event.longitude != nil { return true }
        guard let text = event.location?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return false }
        let lower = text.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.contains("://") { return false }
        if MeetingLinkDetector.detect(in: [text]) != nil, !text.contains(" ") { return false }
        return true
    }

    public static func leaveTime(start: Date, travel: TimeInterval, buffer: TimeInterval) -> Date {
        start.addingTimeInterval(-(max(0, travel) + max(0, buffer)))
    }

    public static func isDue(now: Date, start: Date, travel: TimeInterval, buffer: TimeInterval) -> Bool {
        now >= leaveTime(start: start, travel: travel, buffer: buffer) && now < start
    }

    /// When to look again: at the leave time, or sooner to refresh the estimate.
    public static func nextCheck(now: Date, start: Date, travel: TimeInterval, buffer: TimeInterval) -> Date {
        min(leaveTime(start: start, travel: travel, buffer: buffer), now.addingTimeInterval(refreshInterval))
    }

    /// "25 min", "1 h 10 min".
    public static func travelLabel(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int((seconds / 60).rounded()))
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60, rest = minutes % 60
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
    }
}

/// Event fetches are debounced and run at most once every 1.25 s.
public struct CalendarFetchLimiter: Sendable, Equatable {
    public var debounce: Double
    public var minimumInterval: Double
    public private(set) var lastFetch: Double?

    public init(debounce: Double = 0.25, minimumInterval: Double = 1.25) {
        self.debounce = debounce
        self.minimumInterval = minimumInterval
    }

    /// When a fetch requested at `now` should run (a later request replaces an earlier pending one).
    public func runTime(requestedAt now: Double) -> Double {
        max(now + debounce, (lastFetch ?? -.infinity) + minimumInterval)
    }

    public mutating func didFetch(at time: Double) { lastFetch = time }
}

/// The hourly chime.
public enum HourlyChimeSchedule {
    /// The next top of the hour strictly after `date`.
    public static func next(after date: Date, calendar: Calendar) -> Date {
        calendar.nextDate(after: date, matching: DateComponents(minute: 0, second: 0), matchingPolicy: .nextTime)
            ?? date.addingTimeInterval(3600)
    }
}
