import CoreGraphics
import Foundation

/// Mission Control as Lintel follows it, from its windows.
///
/// Measured on macOS 27: the moment Mission Control opens, the
/// WindowManager process puts up an overlay over the whole display (layer 19), the Spaces bar across
/// its top (layer 14) and window thumbnails (layer 17), all within ~10 ms of the key. On the way back
/// the desktop zooms in for ≈ 0.27 s, the overlay and thumbnails go at ≈ 0.29 s, and the Spaces bar
/// only ≈ 0.14 s after that. (The Dock's Exposé accessibility notifications are accepted but never
/// posted on macOS 27.) So the island tucks in when the overlay appears and may grow back only once
/// the Spaces bar is gone too.
public struct MissionControlTracker: Equatable, Sendable {
    public enum Phase: String, Sendable {
        /// No Mission Control: the island shows.
        case none
        /// Mission Control is opening or open (its overlay is up).
        case shown
        /// The overlay is gone but the Spaces bar is still leaving.
        case leaving
    }

    /// A bar that never leaves doesn't keep the island hidden longer than this.
    public static let leavingTimeout: Double = 1.0

    public private(set) var phase: Phase = .none
    /// When the current phase began (uptime).
    public private(set) var since: Double = 0
    /// Phase changes with their uptime (testing).
    public private(set) var log: [String] = []

    public init() {}

    /// Hidden (tucked) while Mission Control is shown or still leaving.
    public var hidesIsland: Bool { phase != .none }

    /// One look at Mission Control's windows; returns true when `hidesIsland` changed.
    @discardableResult
    public mutating func update(overlay: Bool, bar: Bool, at time: Double) -> Bool {
        let before = hidesIsland
        if overlay {
            move(to: .shown, at: time)
        } else if bar, phase != .none {
            move(to: .leaving, at: time)
        } else {
            move(to: .none, at: time)
        }
        expire(at: time)
        return before != hidesIsland
    }

    /// Time passes; returns true when `hidesIsland` changed.
    @discardableResult
    public mutating func tick(at time: Double) -> Bool {
        let before = hidesIsland
        expire(at: time)
        return before != hidesIsland
    }

    private mutating func expire(at time: Double) {
        if phase == .leaving, time - since >= Self.leavingTimeout { move(to: .none, at: time, cause: "timeout") }
    }

    private mutating func move(to next: Phase, at time: Double, cause: String = "") {
        guard next != phase else { return }
        log.append(String(format: "%.3f ", time) + "\(phase.rawValue) → \(next.rawValue)" + (cause.isEmpty ? "" : " (\(cause))"))
        if log.count > 30 { log.removeFirst(log.count - 30) }
        phase = next
        since = time
    }
}

/// Which of Mission Control's windows a window is, from its owner, layer and bounds (CoreGraphics
/// global coordinates). Only the two that exist only in Mission Control count: the overlay over a
/// whole display and the Spaces bar across a display's top (Stage Manager's own WindowManager
/// windows never match them).
public enum MissionControlWindow: String, Sendable {
    case overlay, bar

    public static let owner = "WindowManager"
    public static let overlayLayer = 19
    public static let barLayer = 14

    public static func classify(owner: String, layer: Int, bounds: CGRect, displays: [CGRect]) -> MissionControlWindow? {
        guard owner == Self.owner else { return nil }
        switch layer {
        case overlayLayer:
            return displays.contains { coversMost(bounds, $0) } ? .overlay : nil
        case barLayer:
            let spansTop = displays.contains { d in
                abs(bounds.minX - d.minX) <= 1 && abs(bounds.width - d.width) <= 1 && abs(bounds.minY - d.minY) <= 1
                    && bounds.height <= d.height / 3
            }
            return spansTop ? .bar : nil
        default:
            return nil
        }
    }

    private static func coversMost(_ window: CGRect, _ display: CGRect) -> Bool {
        let inter = window.intersection(display)
        guard !inter.isNull else { return false }
        return inter.width * inter.height >= 0.9 * display.width * display.height
    }
}
