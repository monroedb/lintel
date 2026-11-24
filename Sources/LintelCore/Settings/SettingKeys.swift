import Foundation

/// Where islands are shown.
public enum DisplaySelection: String, SettingChoice {
    case builtIn = "builtIn"
    case main = "main"
    case all = "all"
    case selected = "selected"

    public var title: String {
        switch self {
        case .builtIn: return "Built-in display"
        case .main: return "Main display"
        case .all: return "All displays"
        case .selected: return "Chosen display"
        }
    }
}

/// What the expanded island shows when nothing is active.
public enum IdleActivity: String, SettingChoice {
    case nothing, media, calendar, both
    /// The timer page.
    case timer

    public var title: String {
        switch self {
        case .nothing: return "Nothing"
        case .media: return "Media"
        case .calendar: return "Calendar"
        case .both: return "Media + Calendar"
        case .timer: return "Timer"
        }
    }
}

/// Lintel's settings keys.
public enum Keys {
    // MARK: App
    /// Lintel's menu-bar item (Settings › General › "Show in menu bar").
    /// Off hides the item at once; Settings stays reachable from the island's right-click
    /// menu and by opening Lintel again.
    public static let showMenuBarItem = SettingKey<Bool>("app.showMenuBarItem", default: true)

    // MARK: Island — placement
    public static let displaySelection = SettingKey<DisplaySelection>("island.display", default: .main)
    public static let chosenDisplayUUID = SettingKey<String?>("island.display.uuid", default: nil)
    public static let chosenDisplayName = SettingKey<String>("island.display.name", default: "")
    public static let forceSimulatedNotch = SettingKey<Bool>("island.forceSimulatedNotch", default: false)
    public static let hideFromScreenCapture = SettingKey<Bool>("island.hideFromScreenCapture", default: false)
    public static let widthTuning = SettingKey<Double>("island.tuning.width", default: 0)
    public static let heightTuning = SettingKey<Double>("island.tuning.height", default: 0)
    /// Private capability switch: hold the island's panels in a dedicated window-server
    /// space so Space switches don't move them.
    public static let windowSpaceCapability = SettingKey<Bool>("capabilities.windowSpace", default: true)

    // MARK: Island — behaviour
    public static let expandOnHover = SettingKey<Bool>("island.expandOnHover", default: false)
    public static let hoverDelay = SettingKey<Double>("island.hoverDelay", default: 0)
    public static let haptics = SettingKey<Bool>("island.haptics", default: true)

    // MARK: Island — hiding rules, effects, open-island content, gestures
    public static let hideInFullScreen = SettingKey<Bool>("island.hide.fullScreen", default: true)
    public static let hideInMissionControl = SettingKey<Bool>("island.hide.missionControl", default: true)
    public static let hideWhileGaming = SettingKey<Bool>("island.hide.gaming", default: false)
    /// Mission Control: the island tucks into the notch with Mission Control's zoom and grows back
    /// after it; off = hide and show at once.
    public static let animateMissionControl = SettingKey<Bool>("island.missionControl.animate", default: true)
    public static let contrastOutline = SettingKey<Bool>("island.contrastOutline", default: true)
    public static let progressiveBlur = SettingKey<Bool>("island.progressiveBlur", default: true)
    public static let idleActivity = SettingKey<IdleActivity>("island.idleActivity", default: .media)
    public static let followMostRecent = SettingKey<Bool>("island.idleActivity.mostRecent", default: false)
    public static let gestureNaturalDirection = SettingKey<Bool>("gestures.natural", default: false)
    public static let gestureToggle = SettingKey<Bool>("gestures.toggle", default: true)
    public static let gestureCycle = SettingKey<Bool>("gestures.cycle", default: true)
    public static let gestureDismiss = SettingKey<Bool>("gestures.dismiss", default: true)
    public static let gestureSkip = SettingKey<Bool>("gestures.skip", default: true)

    // MARK: Alerts — per-group filters during a Focus (Focus "Allowed Notifications"; all on)
    public static func allowWhenFocused(_ group: NotificationGroup) -> SettingKey<Bool> {
        SettingKey("alerts.\(group.rawValue).allowWhenFocused", default: true)
    }

    /// Hold duration per notification (alerts 5 s, HUDs 1.5 s, time to leave 8 s).
    public static func duration(_ kind: NotificationKind) -> SettingKey<Double> {
        let fallback: Double
        switch kind {
        case .volume, .brightness: fallback = 1.5
        case .timeToLeave: fallback = 8
        default: fallback = 5
        }
        let group: String
        switch kind.group {
        case .battery: group = "battery"
        case .connectivity: group = "devices"
        case .focus: group = "focus"
        case .display: group = "brightness"
        case .sound: group = "volume"
        case .travel: group = "travel"
        }
        return SettingKey("alerts.\(group).duration", default: fallback)
    }

    // MARK: Quick Peek
    public static let mediaPeek = SettingKey<Bool>("peek.media", default: true)
    public static let mediaPeekOnChange = SettingKey<Bool>("peek.media.onChange", default: true)
    public static let mediaPeekDuration = SettingKey<Double>("peek.media.duration", default: 2)
    public static let calendarPeek = SettingKey<Bool>("peek.calendar", default: true)
    public static let calendarPeekBefore = SettingKey<Bool>("peek.calendar.beforeStart", default: false)
    public static let calendarPeekAtStart = SettingKey<Bool>("peek.calendar.atStart", default: true)
    public static let calendarPeekDuration = SettingKey<Double>("peek.calendar.duration", default: 4)

    // MARK: Debug (launch arguments, e.g. `-debug.treatAllDisplaysAsNotchless YES`)
    public static let debugTreatAllDisplaysAsNotchless = SettingKey<Bool>("debug.treatAllDisplaysAsNotchless", default: false)
    public static let debugShowIdlePill = SettingKey<Bool>("debug.showIdlePill", default: false)

    /// Keys whose change requires re-planning islands.
    public static let placementKeyNames: Set<String> = [
        displaySelection.name, chosenDisplayUUID.name, forceSimulatedNotch.name,
        widthTuning.name, heightTuning.name, debugTreatAllDisplaysAsNotchless.name,
    ]
}
