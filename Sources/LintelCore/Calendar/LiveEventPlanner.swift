import Foundation

public enum LiveEventPhase: String, Sendable, Equatable {
    /// Starts within the lead time: the island counts down.
    case upcoming
    /// Under way: the island shows its progress.
    case ongoing
}

/// The event the island's calendar live activity is about.
public struct LiveEventState: Equatable, Sendable {
    public var event: CalendarEventRecord
    public var phase: LiveEventPhase

    public init(event: CalendarEventRecord, phase: LiveEventPhase) {
        self.event = event
        self.phase = phase
    }
}

public struct LiveEventOptions: Equatable, Sendable {
    /// How long before an event the countdown starts (`timeBeforeEvent`, 15 min).
    public var leadTime: TimeInterval
    /// No live activity while an event is under way (`disableActivityDuringEvents`).
    public var hideDuringEvents: Bool

    public init(leadTime: TimeInterval = 15 * 60, hideDuringEvents: Bool = false) {
        self.leadTime = max(0, leadTime)
        self.hideDuringEvents = hideDuringEvents
    }
}

/// Something that happened since the last evaluation (drives sounds and Quick Peeks).
public enum LiveEventCrossing: Equatable, Sendable {
    /// The event entered its countdown window ("before event starts" peek).
    case countdownBegan(CalendarEventRecord)
    /// The event started ("when event is starting" peek, event sound).
    case started(CalendarEventRecord)
}

/// Chooses the calendar live activity and when it next changes, so a single
/// timer replaces polling.
///
/// Rules: all-day, dismissed, declined and cancelled events never drive the island. An event under
/// way wins over an upcoming one, unless the upcoming one starts before it ends (a meeting inside a
/// long block); among events under way the most recently started wins; among upcoming ones the
/// soonest.
public enum LiveEventPlanner {
    public static func state(events: [CalendarEventRecord], now: Date, options: LiveEventOptions,
                             dismissed: Set<String> = []) -> LiveEventState? {
        let candidates = eligible(events, dismissed: dismissed).filter { $0.end > now }
        let upcoming = candidates
            .filter { $0.start > now && $0.start.timeIntervalSince(now) <= options.leadTime }
            .min { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }
        let ongoing = options.hideDuringEvents ? nil : candidates
            .filter { $0.start <= now }
            .max { $0.start == $1.start ? $0.end > $1.end : $0.start < $1.start }
        if let ongoing {
            if let upcoming, upcoming.start < ongoing.end { return LiveEventState(event: upcoming, phase: .upcoming) }
            return LiveEventState(event: ongoing, phase: .ongoing)
        }
        return upcoming.map { LiveEventState(event: $0, phase: .upcoming) }
    }

    /// The next instant at which `state` can change: an event entering its countdown, starting or ending.
    public static func nextChange(events: [CalendarEventRecord], now: Date, options: LiveEventOptions,
                                  dismissed: Set<String> = []) -> Date? {
        eligible(events, dismissed: dismissed)
            .flatMap { [$0.start.addingTimeInterval(-options.leadTime), $0.start, $0.end] }
            .filter { $0 > now }
            .min()
    }

    /// Countdowns that began and events that started in `(last, now]`. Crossings older than
    /// `tolerance` (e.g. while the Mac slept) are dropped, so nothing stale plays after wake.
    public static func crossings(events: [CalendarEventRecord], from last: Date, to now: Date, options: LiveEventOptions,
                                 dismissed: Set<String> = [], tolerance: TimeInterval = 90) -> [LiveEventCrossing] {
        guard now > last else { return [] }
        var result: [LiveEventCrossing] = []
        for event in eligible(events, dismissed: dismissed).sorted(by: { $0.start < $1.start }) {
            let countdown = event.start.addingTimeInterval(-options.leadTime)
            if options.leadTime > 0, countdown > last, countdown <= now, now.timeIntervalSince(countdown) <= tolerance,
               event.start.timeIntervalSince(now) > 30 {
                result.append(.countdownBegan(event))
            }
            if event.start > last, event.start <= now, now.timeIntervalSince(event.start) <= tolerance {
                result.append(.started(event))
            }
        }
        return result
    }

    private static func eligible(_ events: [CalendarEventRecord], dismissed: Set<String>) -> [CalendarEventRecord] {
        events.filter { $0.isVisible && !$0.isAllDay && !dismissed.contains($0.id) }
    }
}

/// Short countdown label for the compact island: whole minutes, rounded up ("12m"). Half a second
/// of tolerance keeps timer jitter at a minute boundary from showing the previous minute.
public enum CountdownLabel {
    static let tolerance: TimeInterval = 0.5

    public static func minutes(until start: Date, now: Date) -> Int {
        max(1, Int(((start.timeIntervalSince(now) - tolerance) / 60).rounded(.up)))
    }

    public static func compact(until start: Date, now: Date) -> String {
        let minutes = minutes(until: start, now: now)
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60, rest = minutes % 60
        return rest == 0 ? "\(hours)h" : "\(hours)h\(rest)"
    }

    /// "20 min left", "1 h 5 min left" for an event under way.
    public static func remaining(until end: Date, now: Date) -> String {
        let minutes = max(1, Int(((end.timeIntervalSince(now) - tolerance) / 60).rounded(.up)))
        if minutes < 60 { return "\(minutes) min left" }
        let hours = minutes / 60, rest = minutes % 60
        return rest == 0 ? "\(hours) h left" : "\(hours) h \(rest) min left"
    }

    /// Second line of a calendar Quick Peek.
    public static func peekCaption(start: Date, now: Date) -> String {
        start.timeIntervalSince(now) > 30 ? "Starts in \(minutes(until: start, now: now)) min" : "Starting now"
    }
}
