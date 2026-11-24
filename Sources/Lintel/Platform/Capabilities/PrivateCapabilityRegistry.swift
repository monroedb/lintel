import Foundation
import LintelCore
import Observation

/// Availability of the private capabilities Lintel uses (each private API is resolved at
/// runtime, reports here, and can be switched off with a setting). Settings reads it.
@MainActor
@Observable
final class PrivateCapabilityRegistry {
    enum Status: Equatable {
        case available
        /// The framework or a symbol is missing on this macOS.
        case unavailable(String)
        /// Switched off with its setting (`defaults write com.sashagilliard.lintel <key> -bool NO`).
        case switchedOff
        /// Present but returned values that don't make sense; the feature degrades.
        case misbehaving(String)

        /// With the technical reason, for the log.
        var label: String {
            switch self {
            case .available: return "available"
            case .unavailable(let why): return "unavailable (\(why))"
            case .switchedOff: return "switched off"
            case .misbehaving(let why): return "disabled after unexpected results (\(why))"
            }
        }

        /// Settings' wording (the reason stays in `label`).
        var settingsLabel: String {
            switch self {
            case .available: return "Available"
            case .unavailable: return "Not available on this Mac"
            case .switchedOff: return "Off"
            case .misbehaving: return "Turned off: it didn’t work as expected"
            }
        }

        var isUsable: Bool { self == .available }
    }

    struct Entry: Equatable {
        let id: String
        let title: String
        let settingName: String
        var status: Status
    }

    static let shared = PrivateCapabilityRegistry()

    private(set) var entries: [String: Entry] = [:]

    func report(id: String, title: String, setting: SettingKey<Bool>, status: Status) {
        entries[id] = Entry(id: id, title: title, settingName: setting.name, status: status)
    }

    func status(_ id: String) -> Status? { entries[id]?.status }
}
