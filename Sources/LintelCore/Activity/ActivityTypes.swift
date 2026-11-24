import Foundation

/// Persistent activities shown while their source is active.
public enum LiveActivityKind: String, CaseIterable, Sendable, Codable {
    /// Screen locked: reserved for a lock-screen activity, which isn't built (Maybe later).
    case lock
    case calendar
    case media
    /// Countdown timer.
    case timer
    /// Items on the Shelf: drawn only on its own.
    case shelf
}

/// Groups used by the "Allowed during Focus" filters.
public enum NotificationGroup: String, CaseIterable, Sendable, Codable {
    case battery, connectivity, focus, display, sound, travel
}

/// Transient notifications.
public enum NotificationKind: String, CaseIterable, Sendable, Codable {
    case charging, lowBattery, lowPowerMode
    case deviceConnected, deviceLowBattery
    case focus
    case volume, brightness
    case timeToLeave

    /// HUD notifications update in place and extend their hold on repeat; alerts replace.
    public var isHUD: Bool { self == .volume || self == .brightness }

    public var group: NotificationGroup {
        switch self {
        case .charging, .lowBattery, .lowPowerMode: return .battery
        case .deviceConnected, .deviceLowBattery: return .connectivity
        case .focus: return .focus
        case .brightness: return .display
        case .volume: return .sound
        case .timeToLeave: return .travel
        }
    }
}

public enum QuickPeekKind: String, CaseIterable, Sendable, Codable {
    case media, calendar
}

/// What the expanded card shows.
public enum ExpandedContent: String, CaseIterable, Sendable, Codable {
    case nothing, media, calendar, both
    /// The timer page: presets, or the timer's controls.
    case timer
    /// The Shelf page.
    case shelf
}

/// What the compact island shows, in priority order lock > notification > peek > live > idle.
public enum CompactPresentation: Equatable, Sendable {
    case idle
    case lock
    case notification(NotificationKind)
    case peek(QuickPeekKind)
    /// Visible live activities; media and calendar share the island when both are active.
    case live(Set<LiveActivityKind>)

    public var hasContent: Bool { self != .idle }
}

/// Inputs that gate what may be shown.
public struct ActivityContext: Equatable, Sendable {
    public var focusActive = false
    /// Full screen on this display with "hide in full screen" on: live activities and peeks are
    /// suppressed, notifications and interaction still work.
    public var suppressLiveActivities = false
    public var expanded = false

    public init(focusActive: Bool = false, suppressLiveActivities: Bool = false, expanded: Bool = false) {
        self.focusActive = focusActive
        self.suppressLiveActivities = suppressLiveActivities
        self.expanded = expanded
    }
}

/// Which notification groups may appear during a Focus (Focus "Allowed Notifications"; all on
/// by default). Travel alerts are always allowed.
public struct NotificationFilters: Equatable, Sendable {
    public var allowedWhenFocused: Set<NotificationGroup>

    public init(allowedWhenFocused: Set<NotificationGroup> = Set(NotificationGroup.allCases)) {
        self.allowedWhenFocused = allowedWhenFocused
    }

    public func allows(_ kind: NotificationKind, in context: ActivityContext) -> Bool {
        if kind.group == .travel { return true }
        if context.focusActive, kind != .focus, !allowedWhenFocused.contains(kind.group) { return false }
        return true
    }
}

/// Quick Peek configuration (media peek on with 2 s, calendar "when starting" on with 4 s).
public struct PeekSettings: Equatable, Sendable {
    public var mediaEnabled = true
    public var mediaOnChange = true
    public var mediaDuration: Double = 2
    public var calendarEnabled = true
    public var calendarBeforeStart = false
    public var calendarAtStart = true
    public var calendarDuration: Double = 4

    public init() {}
}
