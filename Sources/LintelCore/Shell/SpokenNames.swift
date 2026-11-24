import Foundation

// What VoiceOver reads for the island's content. Raw values stay for the log.

extension ExpandedContent {
    public var spokenName: String {
        switch self {
        case .nothing: return "date and time"
        case .media: return "media"
        case .calendar: return "calendar"
        case .both: return "media and calendar"
        case .timer: return "timer"
        case .shelf: return "Shelf"
        }
    }
}

extension NotificationKind {
    public var spokenName: String {
        switch self {
        case .charging: return "charging"
        case .lowBattery: return "low battery"
        case .lowPowerMode: return "Low Power Mode"
        case .deviceConnected: return "audio device connected"
        case .deviceLowBattery: return "audio device battery low"
        case .focus: return "Focus"
        case .volume: return "volume"
        case .brightness: return "brightness"
        case .timeToLeave: return "time to leave"
        }
    }
}

extension CompactPresentation {
    /// nil while the closed island shows nothing.
    public var spokenName: String? {
        switch self {
        case .idle: return nil
        case .lock: return "locked"
        case .notification(let kind): return kind.spokenName
        case .peek(let kind): return kind == .media ? "media" : "calendar"
        case .live(let kinds):
            let names: [String] = LiveActivityKind.allCases.filter(kinds.contains).map {
                switch $0 {
                case .lock: return "locked"
                case .calendar: return "calendar"
                case .media: return "media"
                case .timer: return "timer"
                case .shelf: return "Shelf"
                }
            }
            // English like the rest of Lintel's copy, whatever the system's locale.
            guard let last = names.last else { return nil }
            return names.count == 1 ? last : names.dropLast().joined(separator: ", ") + " and " + last
        }
    }
}
