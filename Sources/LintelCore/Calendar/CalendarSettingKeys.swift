import Foundation

/// How the user travels to events with a location (`defaultTransportType`: drive / walk / transit).
public enum TravelMode: String, SettingChoice {
    case driving, walking, transit

    public var title: String {
        switch self {
        case .driving: return "Car"
        case .walking: return "Walking"
        case .transit: return "Public transport"
        }
    }

    public var symbol: String {
        switch self {
        case .driving: return "car.fill"
        case .walking: return "figure.walk"
        case .transit: return "tram.fill"
        }
    }
}

/// Toggles that need Location; remembered while the permission prompt is open (`pendingLocationPermissionTarget`).
public enum LocationPermissionTarget: String, SettingChoice {
    case weatherOnFreeDay, timeToLeave, weatherWidget
}

/// Lintel's calendar, weather and time-to-leave keys.
extension Keys {
    // MARK: Calendar — master switch and access
    public static let calendarEnabled = SettingKey<Bool>("calendar.enabled", default: false)
    public static let calendarAccessPrompted = SettingKey<Bool>("calendar.access.prompted", default: false)

    // MARK: Calendar — island (live activity)
    /// Minutes before an event during which the island counts down to it.
    public static let calendarLeadMinutes = SettingKey<Double>("calendar.island.leadMinutes", default: 15)
    public static let calendarTintIcon = SettingKey<Bool>("calendar.island.tintIcon", default: true)
    public static let calendarHideDuringEvents = SettingKey<Bool>("calendar.island.hideDuringEvents", default: false)

    // MARK: Calendar — open card
    public static let calendarTintTitles = SettingKey<Bool>("calendar.card.tintTitles", default: false)
    public static let calendarMonthView = SettingKey<Bool>("calendar.card.monthView", default: false)
    public static let calendarEventDots = SettingKey<Bool>("calendar.card.eventDots", default: false)
    public static let calendarWeatherOnFreeDay = SettingKey<Bool>("calendar.card.weatherOnFreeDay", default: false)
    public static let calendarApp = SettingKey<CalendarAppChoice>("calendar.card.app", default: .calendar)

    // MARK: Calendar — sounds
    public static let calendarStartSound = SettingKey<Bool>("calendar.sound.eventStart", default: true)
    public static let calendarHourlyChime = SettingKey<Bool>("calendar.sound.hourlyChime", default: false)

    // MARK: Calendar — time to leave (alert duration: `Keys.duration(.timeToLeave)`, 8 s)
    public static let timeToLeaveEnabled = SettingKey<Bool>("calendar.leave.enabled", default: false)
    public static let timeToLeaveBufferMinutes = SettingKey<Double>("calendar.leave.bufferMinutes", default: 10)
    public static let timeToLeaveSound = SettingKey<Bool>("calendar.leave.sound", default: true)
    public static let timeToLeaveMode = SettingKey<TravelMode>("calendar.leave.mode", default: .driving)

    // MARK: Calendar — which calendars
    public static let calendarExclusions = SettingKey<CalendarExclusions>("calendar.excluded", default: CalendarExclusions())
    public static let calendarModes = SettingKey<CalendarModeAssignments>("calendar.modes", default: CalendarModeAssignments())

    // MARK: Location and weather
    public static let locationAccessPrompted = SettingKey<Bool>("location.access.prompted", default: false)
    public static let locationPendingTarget = SettingKey<LocationPermissionTarget?>("location.pendingTarget", default: nil)
    /// Last weather report as JSON (`cachedWeather`).
    public static let weatherCache = SettingKey<String?>("weather.cache", default: nil)

    /// Prefixes of the keys above; changes to them are handled by the calendar feature.
    public static let calendarKeyPrefixes = ["calendar.", "location.", "weather."]
}
