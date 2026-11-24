import Foundation

/// Step sizes of the HUD keys (1/16 per press; ⌥⇧ gives fine steps of a quarter step, 1/64).
public enum LevelStep {
    public static let normal: Double = 1.0 / 16
    public static let fineFactor: Double = 0.25
    public static var fine: Double { normal * fineFactor }
}

/// Result of one key press on a level (volume or brightness).
public struct LevelChange: Equatable, Sendable {
    public var value: Double
    /// Set when the press pushed past a bound: the bar rubber-bands towards that edge.
    public var overshoot: LevelEdge?

    public init(value: Double, overshoot: LevelEdge? = nil) {
        self.value = value
        self.overshoot = overshoot
    }
}

/// Moves a level one press up or down.
///
/// Presses land on the step grid (multiples of 1/16, or 1/64 for fine steps) in the direction of the
/// press, so a level changed elsewhere (e.g. 0.13) snaps to the next grid point (0.1875 up, 0.125
/// down) — as macOS's own keys do. At a bound the level stays and the press
/// overshoots, but only while the HUD is already showing or the key auto-repeats; the first press
/// at a bound just shows the HUD ("A single press may overshoot while the HUD is already open").
public enum LevelStepper {
    public static func step(from current: Double, up: Bool, fine: Bool, hudVisible: Bool, isRepeat: Bool) -> LevelChange {
        let size = fine ? LevelStep.fine : LevelStep.normal
        let level = current.isFinite ? min(1, max(0, current)) : 0
        let epsilon = 1e-4
        let mayOvershoot = hudVisible || isRepeat
        if up {
            if level >= 1 - epsilon { return LevelChange(value: 1, overshoot: mayOvershoot ? .maximum : nil) }
            let next = (floor(level / size + epsilon) + 1) * size
            return LevelChange(value: min(1, next))
        } else {
            if level <= epsilon { return LevelChange(value: 0, overshoot: mayOvershoot ? .minimum : nil) }
            let next = (ceil(level / size - epsilon) - 1) * size
            return LevelChange(value: max(0, next))
        }
    }
}

/// Recognises the app's own writes when they come back as change notifications, so they aren't
/// treated as changes made elsewhere (own brightness changes ignored for 0.45 s; volume writes
/// "briefly ignored").
public struct EchoFilter: Sendable {
    public var window: Double
    public var tolerance: Double
    private var writes: [(value: Double, time: Double)] = []

    public init(window: Double = 0.45, tolerance: Double = 0.003) {
        self.window = window
        self.tolerance = tolerance
    }

    public mutating func recordWrite(_ value: Double, now: Double) {
        prune(now: now)
        writes.append((value, now))
        if writes.count > 64 { writes.removeFirst(writes.count - 64) }
    }

    /// True when `value` matches one of the writes made within the window.
    public mutating func isEcho(_ value: Double, now: Double) -> Bool {
        prune(now: now)
        return writes.contains { abs($0.value - value) <= tolerance }
    }

    /// True while any own write is younger than the window (e.g. during a smooth brightness ramp).
    public mutating func isSettling(now: Double) -> Bool {
        prune(now: now)
        return !writes.isEmpty
    }

    private mutating func prune(now: Double) {
        writes.removeAll { now - $0.time > window }
    }
}

/// Whether and when the system's volume-feedback sound plays after a key press (when "Play
/// feedback when volume is changed" is on, after a change, with a short delay after unmuting).
public enum VolumeFeedback {
    public static let unmuteDelay: Double = 0.3
    public static let minimumInterval: Double = 0.15

    /// Delay before playing, or nil for no sound.
    public static func delay(feedbackEnabled: Bool, muted: Bool, changed: Bool, unmuted: Bool) -> Double? {
        guard feedbackEnabled, !muted, changed || unmuted else { return nil }
        return unmuted ? unmuteDelay : 0
    }
}
