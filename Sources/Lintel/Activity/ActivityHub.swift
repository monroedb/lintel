import Foundation
import LintelCore
import Observation

/// Now Playing summary that drives the media live activity. Filled by `NowPlayingController`.
struct MediaSnapshot: Equatable {
    var identity: String
    var title: String
    var artist: String
    var playing: Bool
    /// Seed for Lintel's generated placeholder artwork.
    var artworkSeed: Int
    var duration: Double
    var elapsed: Double
}

/// Calendar data shown by the island (the live event from `CalendarAgenda`).
struct CalendarSnapshot: Equatable {
    var identity: String
    var title: String
    var start: Date
    var end: Date
    /// Calendar colour for the glyph and ring ("coloured calendar indicator"); nil = Lintel Copper.
    var tint: EventColor? = nil

    func progress(at date: Date) -> Double {
        let total = end.timeIntervalSince(start)
        guard total > 0 else { return 0 }
        return min(1, max(0, date.timeIntervalSince(start) / total))
    }
}

/// Content of a transient notification.
struct NotificationPayload: Equatable {
    var symbol: String
    var label: String
    /// Level 0…1 for HUD bars.
    var level: Double?
    /// Short trailing text for alerts ("On", "80 %").
    var value: String?
    /// Battery, audio-device and Focus alert content (`SystemAlertViews.swift`).
    var detail: SystemAlertDetail? = nil

    static func make(_ kind: NotificationKind, value: Double?) -> NotificationPayload {
        let percent = value.map { "\(Int(($0 * 100).rounded())) %" }
        switch kind {
        case .volume:
            let level = value ?? 0.5
            return NotificationPayload(symbol: level <= 0 ? "speaker.slash.fill" : "speaker.wave.2.fill", label: "Sound", level: level)
        case .brightness:
            return NotificationPayload(symbol: "sun.max.fill", label: "Display", level: value ?? 0.5)
        case .focus:
            let on = (value ?? 1) > 0
            return NotificationPayload(symbol: on ? "moon.fill" : "moon", label: "Focus", value: on ? "On" : "Off")
        case .charging:
            return NotificationPayload(symbol: "bolt.fill", label: "Charging", value: percent ?? "80 %")
        case .lowBattery:
            return NotificationPayload(symbol: "battery.25percent", label: "Low battery", value: percent ?? "10 %")
        case .lowPowerMode:
            return NotificationPayload(symbol: "leaf.fill", label: "Low Power", value: "On")
        case .deviceConnected:
            return NotificationPayload(symbol: "headphones", label: "Connected", value: percent ?? "85 %")
        case .deviceLowBattery:
            return NotificationPayload(symbol: "headphones", label: "Low battery", value: percent ?? "10 %")
        case .timeToLeave:
            return NotificationPayload(symbol: "car.fill", label: "Leave now", value: "12 min")
        }
    }
}

/// Events the hub forwards to every island's engine.
enum ActivityEvent {
    case live(LiveActivityKind, active: Bool, identity: String)
    case notification(NotificationKind)
    case peek(QuickPeekKind, userInitiated: Bool, trigger: ActivityEngine.CalendarPeekTrigger)
    case context
}

/// Process-wide activity sources. Each island owns its own `ActivityEngine` (its context — expanded,
/// full screen — is per display); the hub keeps the shared source data and fans events out.
@MainActor
@Observable
final class ActivityHub {
    private(set) var media: MediaSnapshot?
    private(set) var calendar: CalendarSnapshot?
    /// Shelf indicator: item count and the latest drop.
    private(set) var shelf: ShelfSnapshot?
    private(set) var payloads: [NotificationKind: NotificationPayload] = [:]
    private(set) var focusActive = false
    private(set) var locked = false
    /// The displays sleep or the session is locked: nothing Lintel draws can be seen, so what only
    /// matters on screen pauses (the live waveform's audio tap, animations, ticks).
    private(set) var screensQuiet = false
    /// Focus symbol shown instead of the compact waveform ("Replace waveform during focus").
    var focusGlyphForWaveform: FocusModeDescriptor?
    /// Last gesture or click action.
    var lastAction = ""
    /// Rich Now Playing state and media actions; `media` above drives the live activity.
    let nowPlaying = NowPlayingCenter()
    /// What the volume and brightness HUDs show (written by `SystemHUDService`).
    let hud = HUDPresentationState()
    /// The timer's state and actions (written by `TimerFeature`).
    let timer = TimerCenter()

    @ObservationIgnored var onEvent: ((ActivityEvent) -> Void)?

    func setMedia(_ snapshot: MediaSnapshot?) {
        let previous = media
        media = snapshot
        if previous?.identity != snapshot?.identity || (previous == nil) != (snapshot == nil) {
            onEvent?(.live(.media, active: snapshot != nil, identity: snapshot?.identity ?? ""))
        }
    }

    func setCalendar(_ snapshot: CalendarSnapshot?) {
        let previous = calendar
        calendar = snapshot
        if previous?.identity != snapshot?.identity || (previous == nil) != (snapshot == nil) {
            onEvent?(.live(.calendar, active: snapshot != nil, identity: snapshot?.identity ?? ""))
        }
    }

    func setShelf(_ snapshot: ShelfSnapshot?) {
        let previous = shelf
        shelf = snapshot
        if previous?.identity != snapshot?.identity || (previous == nil) != (snapshot == nil) {
            onEvent?(.live(.shelf, active: snapshot != nil, identity: snapshot?.identity ?? ""))
        }
    }

    func post(_ kind: NotificationKind, payload: NotificationPayload) {
        payloads[kind] = payload
        onEvent?(.notification(kind))
    }

    func peek(_ kind: QuickPeekKind, userInitiated: Bool, trigger: ActivityEngine.CalendarPeekTrigger = .atStart) {
        // A peek needs something to show.
        guard kind == .media ? media != nil : calendar != nil else { return }
        onEvent?(.peek(kind, userInitiated: userInitiated, trigger: trigger))
    }

    func setFocus(_ active: Bool) {
        guard focusActive != active else { return }
        focusActive = active
        onEvent?(.context)
    }

    func setLocked(_ isLocked: Bool) {
        guard locked != isLocked else { return }
        locked = isLocked
        onEvent?(.context)
    }

    func setScreensQuiet(_ quiet: Bool) {
        guard screensQuiet != quiet else { return }
        screensQuiet = quiet
        nowPlaying.controller?.screensQuietChanged()
    }
}
