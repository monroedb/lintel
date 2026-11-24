import CoreGraphics
import Foundation

/// An sRGB colour without UI dependencies (calendar colours, event tints).
public struct EventColor: Equatable, Hashable, Sendable, Codable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = min(1, max(0, red))
        self.green = min(1, max(0, green))
        self.blue = min(1, max(0, blue))
    }

    /// Parses "#RRGGBB" or "RRGGBB".
    public init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255)
    }

    /// Converts any CoreGraphics colour (e.g. an EventKit calendar colour) to sRGB.
    public init?(cgColor: CGColor) {
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let converted = cgColor.converted(to: srgb, intent: .defaultIntent, options: nil),
              let components = converted.components, components.count >= 3 else { return nil }
        self.init(red: Double(components[0]), green: Double(components[1]), blue: Double(components[2]))
    }

    public var hex: String {
        String(format: "#%02X%02X%02X", Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded()))
    }

    public var luminance: Double { Luminance.relative(r: red, g: green, b: blue) }

    public func mixed(with other: EventColor, amount: Double) -> EventColor {
        let t = min(1, max(0, amount))
        return EventColor(red: red + (other.red - red) * t, green: green + (other.green - green) * t,
                          blue: blue + (other.blue - blue) * t)
    }

    /// The colour lightened towards white just enough to stand out on the black island (very dark
    /// calendar colours would otherwise disappear).
    public func readableOnBlack(minimumLuminance: Double = 0.1) -> EventColor {
        guard luminance < minimumLuminance else { return self }
        var amount = 0.0
        var color = self
        while color.luminance < minimumLuminance, amount < 1 {
            amount += 0.05
            color = mixed(with: .white, amount: amount)
        }
        return color
    }

    public static let white = EventColor(red: 1, green: 1, blue: 1)
    /// Lintel Copper #D9773A, the accent when a calendar colour isn't used.
    public static let copper = EventColor(red: 0xD9 / 255, green: 0x77 / 255, blue: 0x3A / 255)
}

/// Regular events, holidays and birthdays are drawn slightly differently.
public enum CalendarEventKind: String, Sendable, Codable {
    case regular, holiday, birthday
}

/// One event occurrence, normalised from the calendar store.
public struct CalendarEventRecord: Equatable, Hashable, Sendable, Identifiable {
    /// Unique per occurrence (event identifier + start), stable across fetches.
    public var id: String
    /// Identifier calendar apps use to show the event (EventKit's external identifier).
    public var externalID: String?
    public var calendarID: String
    public var title: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    public var location: String?
    /// Coordinates of a structured location, when the calendar provides one.
    public var latitude: Double?
    public var longitude: Double?
    public var color: EventColor
    public var kind: CalendarEventKind
    /// Declined by the user or cancelled: hidden everywhere.
    public var declined: Bool
    public var cancelled: Bool
    public var meeting: MeetingLink?

    public init(id: String, externalID: String? = nil, calendarID: String, title: String, start: Date, end: Date,
                isAllDay: Bool = false, location: String? = nil, latitude: Double? = nil, longitude: Double? = nil,
                color: EventColor = .copper, kind: CalendarEventKind = .regular, declined: Bool = false,
                cancelled: Bool = false, meeting: MeetingLink? = nil) {
        self.id = id
        self.externalID = externalID
        self.calendarID = calendarID
        self.title = title
        self.start = start
        self.end = max(start, end)
        self.isAllDay = isAllDay
        self.location = location
        self.latitude = latitude
        self.longitude = longitude
        self.color = color
        self.kind = kind
        self.declined = declined
        self.cancelled = cancelled
        self.meeting = meeting
    }

    public var isVisible: Bool { !declined && !cancelled }

    public func isOngoing(at now: Date) -> Bool { start <= now && now < end }

    public func overlaps(from lower: Date, to upper: Date) -> Bool { start < upper && end > lower }

    public var duration: TimeInterval { end.timeIntervalSince(start) }

    /// Progress through the event, 0…1.
    public func progress(at now: Date) -> Double {
        guard duration > 0 else { return now >= start ? 1 : 0 }
        return min(1, max(0, now.timeIntervalSince(start) / duration))
    }
}

/// A calendar the user can include, exclude or limit (settings list).
public struct CalendarListEntry: Equatable, Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var color: EventColor
    /// Account or source the calendar belongs to (grouping in Settings).
    public var account: String

    public init(id: String, title: String, color: EventColor, account: String) {
        self.id = id
        self.title = title
        self.color = color
        self.account = account
    }
}

/// Where a calendar's events appear (`calendarDisplayModes`: Both / Live Activity / Expanded View).
public enum CalendarDisplayMode: String, Sendable, CaseIterable, Codable {
    case both, island, card

    public var showsInIsland: Bool { self != .card }
    public var showsInCard: Bool { self != .island }

    public var title: String {
        switch self {
        case .both: return "Island and open card"
        case .island: return "Island only"
        case .card: return "Open card only"
        }
    }
}

/// Calendars left out everywhere (`excludedCalendars`; all included by default).
public struct CalendarExclusions: SettingValue {
    public var ids: Set<String>

    public init(_ ids: Set<String> = []) { self.ids = ids }

    public static func decode(_ object: Any) -> CalendarExclusions? {
        guard let array = object as? [Any] else { return nil }
        return CalendarExclusions(Set(array.compactMap { $0 as? String }))
    }

    public var encoded: Any? { ids.sorted() }
}

/// Per-calendar display modes (`calendarDisplayModes`; unlisted calendars use "both").
public struct CalendarModeAssignments: SettingValue {
    public var modes: [String: CalendarDisplayMode]

    public init(_ modes: [String: CalendarDisplayMode] = [:]) { self.modes = modes }

    public static func decode(_ object: Any) -> CalendarModeAssignments? {
        guard let dictionary = object as? [String: Any] else { return nil }
        var modes: [String: CalendarDisplayMode] = [:]
        for (id, raw) in dictionary {
            if let raw = raw as? String, let mode = CalendarDisplayMode(rawValue: raw) { modes[id] = mode }
        }
        return CalendarModeAssignments(modes)
    }

    public var encoded: Any? { modes.mapValues(\.rawValue) }

    public func mode(for calendarID: String) -> CalendarDisplayMode { modes[calendarID] ?? .both }
}

/// Which events reach the island (live activity) and the open card. The two lists are filtered and
/// cached separately.
public struct CalendarEventFilter: Equatable, Sendable {
    public var excluded: Set<String>
    public var modes: CalendarModeAssignments

    public init(excluded: Set<String> = [], modes: CalendarModeAssignments = CalendarModeAssignments()) {
        self.excluded = excluded
        self.modes = modes
    }

    public func includesInIsland(_ event: CalendarEventRecord) -> Bool {
        event.isVisible && !excluded.contains(event.calendarID) && modes.mode(for: event.calendarID).showsInIsland
    }

    public func includesInCard(_ event: CalendarEventRecord) -> Bool {
        event.isVisible && !excluded.contains(event.calendarID) && modes.mode(for: event.calendarID).showsInCard
    }

    /// Events considered for time-to-leave alerts: any included, visible event.
    public func includesAnywhere(_ event: CalendarEventRecord) -> Bool {
        event.isVisible && !excluded.contains(event.calendarID)
    }
}
