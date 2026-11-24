import Foundation
import LintelCore
import Observation

/// What the volume and brightness HUDs show, read by the island's views (one instance per app,
/// owned by `ActivityHub.hud`). The HUD service writes it; the activity engine decides when the
/// HUD notification is on screen.
@MainActor
@Observable
final class HUDPresentationState {
    struct Reading: Equatable {
        /// 0…1; shown as an empty track while muted.
        var level: Double
        var muted: Bool
        var symbol: String
        var label: String
        /// Brightness of an external display (the glyph is a display instead of the sun).
        var externalTarget = false
        /// The notification payload posted with this reading. A HUD posted by another source carries
        /// a different payload, and the views then show that.
        var posted: NotificationPayload?

        var shownLevel: Double { muted ? 0 : level }
    }

    /// A rubber-band pulse of the level bar; the token changes on every overshooting press.
    struct Overshoot: Equatable {
        var edge: LevelEdge
        var token: Int
    }

    private(set) var volume: Reading?
    private(set) var brightness: Reading?
    var volumeAppearance = HUDAppearance()
    var brightnessAppearance = HUDAppearance()
    private(set) var overshoot: [HUDKind: Overshoot] = [:]
    /// Display (UUID) whose island shows the HUD; nil = every island.
    private(set) var targetScreen: [HUDKind: String] = [:]

    func reading(for kind: HUDKind) -> Reading? { kind == .volume ? volume : brightness }

    /// The reading behind the HUD currently posted with `payload`, if Lintel's service posted it.
    func reading(for kind: HUDKind, matching payload: NotificationPayload) -> Reading? {
        guard let reading = reading(for: kind), reading.posted == payload else { return nil }
        return reading
    }

    func appearance(for kind: HUDKind) -> HUDAppearance { kind == .volume ? volumeAppearance : brightnessAppearance }

    func set(_ reading: Reading, for kind: HUDKind, screen: String?) {
        if kind == .volume { volume = reading } else { brightness = reading }
        targetScreen[kind] = screen
    }

    /// Updates the level in place (changes made elsewhere while the HUD is shown).
    func update(level: Double, muted: Bool, symbol: String, for kind: HUDKind) {
        guard var reading = reading(for: kind) else { return }
        reading.level = level
        reading.muted = muted
        reading.symbol = symbol
        if kind == .volume { volume = reading } else { brightness = reading }
    }

    func pulse(_ edge: LevelEdge, for kind: HUDKind) {
        let token = (overshoot[kind]?.token ?? 0) &+ 1
        overshoot[kind] = Overshoot(edge: edge, token: token)
    }
}

extension ActivityHub {
    /// Whether an activity event reaches the island on `screen` (HUDs go to the affected display
    /// when it has an island; everything else goes everywhere).
    func delivers(_ event: ActivityEvent, toScreen screen: String, among screens: [String]) -> Bool {
        guard case .notification(let kind) = event, let hudKind = HUDKind(notification: kind) else { return true }
        return HUDRouting.screens(target: hud.targetScreen[hudKind], islands: screens).contains(screen)
    }
}
