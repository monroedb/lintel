import Foundation

/// Video-call services whose links Lintel recognises.
public enum MeetingService: String, Sendable, CaseIterable, Codable {
    case facetime, zoom, googleMeet, teams, webex

    public var title: String {
        switch self {
        case .facetime: return "FaceTime"
        case .zoom: return "Zoom"
        case .googleMeet: return "Google Meet"
        case .teams: return "Microsoft Teams"
        case .webex: return "Webex"
        }
    }

    /// Native apps that handle the service, in order of preference ("native apps are
    /// preferred over web links").
    public var appBundleIDs: [String] {
        switch self {
        case .facetime: return ["com.apple.FaceTime"]
        case .zoom: return ["us.zoom.xos"]
        case .googleMeet: return []
        case .teams: return ["com.microsoft.teams2", "com.microsoft.teams"]
        case .webex: return ["Cisco-Systems.Spark", "com.webex.meetingmanager"]
        }
    }
}

/// A meeting link found in an event, with the web link and (when the service has one) the link its
/// native app opens directly.
public struct MeetingLink: Equatable, Hashable, Sendable, Codable {
    public var service: MeetingService
    public var webURL: URL
    /// App-specific link; nil when the app takes the web link itself (FaceTime, Webex) or there is no app.
    public var appURL: URL?

    public init(service: MeetingService, webURL: URL, appURL: URL? = nil) {
        self.service = service
        self.webURL = webURL
        self.appURL = appURL
    }
}

/// Finds the first meeting link in an event's URL, location and notes (in that order).
public enum MeetingLinkDetector {
    private struct Pattern {
        let service: MeetingService
        let regex: NSRegularExpression
    }

    private static let patterns: [Pattern] = {
        let tail = #"[^\s<>"'\)\]]*"#
        let sources: [(MeetingService, String)] = [
            (.zoom, #"(?:https?://)?(?:[a-z0-9-]+\.)*zoom(?:gov)?\.(?:us|com)/(?:j|my|w|s|wc/join)/"# + tail),
            (.zoom, #"zoommtg://"# + tail),
            (.googleMeet, #"(?:https?://)?meet\.google\.com/[a-z]{3,4}-[a-z]{4}-[a-z]{3,4}"# + tail),
            (.teams, #"(?:https?://)?teams\.(?:microsoft|live)\.com/(?:l/meetup-join|meet)/"# + tail),
            (.webex, #"(?:https?://)?(?:[a-z0-9-]+\.)*webex\.com/"# + tail),
            (.facetime, #"(?:https?://)?facetime\.apple\.com/join"# + tail),
        ]
        return sources.compactMap { service, source in
            (try? NSRegularExpression(pattern: source, options: [.caseInsensitive])).map { Pattern(service: service, regex: $0) }
        }
    }()

    public static func detect(url: String?, location: String?, notes: String?) -> MeetingLink? {
        detect(in: [url, location, notes])
    }

    /// The first link found, searching each text in turn.
    public static func detect(in texts: [String?]) -> MeetingLink? {
        for case let text? in texts where !text.isEmpty {
            if let link = firstLink(in: text) { return link }
        }
        return nil
    }

    private static func firstLink(in text: String) -> MeetingLink? {
        let range = NSRange(text.startIndex..., in: text)
        var best: (location: Int, link: MeetingLink)?
        for pattern in patterns {
            guard let match = pattern.regex.firstMatch(in: text, options: [], range: range),
                  let matchRange = Range(match.range, in: text) else { continue }
            if let best, best.location <= match.range.location { continue }
            if let link = link(for: pattern.service, raw: String(text[matchRange])) {
                best = (match.range.location, link)
            }
        }
        return best?.link
    }

    private static func link(for service: MeetingService, raw: String) -> MeetingLink? {
        var text = raw
        while let last = text.last, ".,;:!?".contains(last) { text.removeLast() }
        if service == .zoom, text.lowercased().hasPrefix("zoommtg://") {
            guard let url = URL(string: text) else { return nil }
            return MeetingLink(service: .zoom, webURL: url, appURL: url)
        }
        if !text.lowercased().hasPrefix("http") { text = "https://" + text }
        guard let web = URL(string: text) else { return nil }
        return MeetingLink(service: service, webURL: web, appURL: appURL(for: service, web: web))
    }

    /// Native links: Zoom's join scheme (meeting number and passcode) and Teams' own scheme.
    /// FaceTime and Webex take the web link in their app; Google Meet has no app.
    static func appURL(for service: MeetingService, web: URL) -> URL? {
        switch service {
        case .zoom:
            let parts = web.pathComponents
            guard let index = parts.firstIndex(where: { ["j", "w", "s"].contains($0) }), index + 1 < parts.count else { return nil }
            let number = parts[index + 1].filter(\.isNumber)
            guard !number.isEmpty else { return nil }
            var components = URLComponents()
            components.scheme = "zoommtg"
            components.host = "zoom.us"
            components.path = "/join"
            var items = [URLQueryItem(name: "action", value: "join"), URLQueryItem(name: "confno", value: number)]
            if let pwd = URLComponents(url: web, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "pwd" })?.value {
                items.append(URLQueryItem(name: "pwd", value: pwd))
            }
            components.queryItems = items
            return components.url
        case .teams:
            guard var components = URLComponents(url: web, resolvingAgainstBaseURL: false) else { return nil }
            components.scheme = "msteams"
            return components.url
        case .facetime, .webex, .googleMeet:
            return nil
        }
    }
}

/// The app that opens events and dates (Calendar, Fantastical, Notion Calendar).
public enum CalendarAppChoice: String, SettingChoice {
    case calendar, fantastical, notionCalendar

    public var title: String {
        switch self {
        case .calendar: return "Calendar"
        case .fantastical: return "Fantastical"
        case .notionCalendar: return "Notion Calendar"
        }
    }

    public var bundleIDs: [String] {
        switch self {
        case .calendar: return ["com.apple.iCal"]
        case .fantastical: return ["com.flexibits.fantastical2.mac", "com.flexibits.fantastical"]
        case .notionCalendar: return ["com.cron.electron"]
        }
    }

    /// Link that shows one event, when the app has one.
    public func eventURL(externalID: String?, start: Date, calendar: Calendar = .current) -> URL? {
        switch self {
        case .calendar:
            guard let externalID, !externalID.isEmpty,
                  let encoded = externalID.addingPercentEncoding(withAllowedCharacters: Self.unreserved) else { return nil }
            return URL(string: "ical://ekevent/\(encoded)?method=show&options=more")
        case .fantastical:
            return dayURL(for: start, calendar: calendar)
        case .notionCalendar:
            return nil
        }
    }

    /// Link that shows a day, when the app has one (otherwise the app is simply opened).
    public func dayURL(for date: Date, calendar: Calendar = .current) -> URL? {
        switch self {
        case .fantastical:
            // URLs take Gregorian dates whatever calendar the user's locale uses.
            var gregorian = Calendar(identifier: .gregorian)
            gregorian.timeZone = calendar.timeZone
            let parts = gregorian.dateComponents([.year, .month, .day], from: date)
            guard let year = parts.year, let month = parts.month, let day = parts.day else { return nil }
            return URL(string: String(format: "x-fantastical3://show/calendar/%04d-%02d-%02d", year, month, day))
        case .calendar, .notionCalendar:
            return nil
        }
    }

    private static let unreserved = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
}
