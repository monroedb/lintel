import CoreGraphics
import Foundation

// The Ruler picker for setting a timer: geometry, motion,
// haptic ticks, gesture routing and keys. Pure values; the app drives them with real time.

/// Timer › Picker style.
public enum TimerPickerStyle: String, SettingChoice, Sendable {
    case ruler
    case classic
}

// MARK: - Scale and geometry

/// The ruler's fixed numbers: one tick per minute from `origin` to `maximum`, `minimum` …
/// `maximum` selectable, a label every `labelEvery` minutes.
public struct TimerRulerScale: Equatable, Sendable {
    public var minimum = 1
    public var maximum = 120
    /// First tick (labelled `0`); never selected.
    public var origin = 0
    /// Points per minute.
    public var spacing: CGFloat = 9
    public var labelEvery = 5
    /// Ticks and labels fade out over this many points at both edges.
    public var fadeWidth: CGFloat = 56
    /// UIScrollView-style rubber band past the ends.
    public var rubberBandCoefficient: Double = 0.55
    /// Width of the ruler (the card body).
    public var width: CGFloat = 345

    public static let defaultMinutes = 15

    public init() {}

    /// The selected minute for a (possibly overscrolled) position: rounded, within the range.
    public func selected(_ position: Double) -> Int {
        guard position.isFinite else { return minimum }
        return clamp(Int(position.rounded()))
    }

    public func clamp(_ minutes: Int) -> Int { min(maximum, max(minimum, minutes)) }

    public func clamp(_ position: Double) -> Double { min(Double(maximum), max(Double(minimum), position)) }

    public func contains(_ minutes: Int) -> Bool { minutes >= minimum && minutes <= maximum }

    /// x of a minute's tick when the centre shows `position`.
    public func x(of minute: Int, position: Double) -> CGFloat {
        width / 2 + CGFloat(Double(minute) - position) * spacing
    }

    /// Ticks inside the ruler (one spare on each side), never before the origin or after the end.
    public func visibleMinutes(position: Double) -> ClosedRange<Int> {
        let half = Double(width / 2 / spacing) + 1
        let low = max(origin, Int((position - half).rounded(.down)))
        let high = min(maximum, Int((position + half).rounded(.up)))
        return low...max(low, high)
    }

    public func isLabelled(_ minute: Int) -> Bool { minute % labelEvery == 0 }

    public enum Tone: Equatable, Sendable {
        /// At or below the selection (copper), the selected tick (light copper), above it (dim).
        case passed, selected, ahead
    }

    public func tone(of minute: Int, selected: Int) -> Tone {
        if minute == selected { return .selected }
        return minute < selected ? .passed : .ahead
    }

    /// Opacity of the edge fade at x: 0 at both edges, 1 from `fadeWidth` inwards.
    public func edgeOpacity(x: CGFloat) -> Double {
        guard fadeWidth > 0 else { return 1 }
        let distance = min(x, width - x)
        return Double(min(1, max(0, distance / fadeWidth)))
    }

    /// The rubber band's dimension: half the ruler's width, in minutes.
    public var bandMinutes: Double { Double(width / 2 / spacing) }

    /// Where the ruler is drawn for a held (finger) position: past an end it moves with resistance,
    /// d′ = (1 − 1 ∕ (c d ∕ D + 1)) D.
    public func rubberBanded(_ raw: Double) -> Double {
        let lower = Double(minimum), upper = Double(maximum), dimension = bandMinutes
        func band(_ over: Double) -> Double { (1 - 1 / (over * rubberBandCoefficient / dimension + 1)) * dimension }
        if raw < lower { return lower - band(lower - raw) }
        if raw > upper { return upper + band(raw - upper) }
        return raw
    }

    /// The held position that is drawn at `shown` (inverse of `rubberBanded`), so a drag can pick
    /// up a ruler that is springing back.
    public func unbanded(_ shown: Double) -> Double {
        let lower = Double(minimum), upper = Double(maximum), dimension = bandMinutes
        func unband(_ over: Double) -> Double {
            let fraction = min(over / dimension, 0.999)
            return (1 / (1 - fraction) - 1) * dimension / rubberBandCoefficient
        }
        if shown < lower { return lower - unband(lower - shown) }
        if shown > upper { return upper + unband(shown - upper) }
        return shown
    }

    /// `15:00`, `1:18:00`.
    public func clock(_ minutes: Int) -> String { TimerFormat.clock(minutes * 60) }
}

// MARK: - Motion

/// A ruler movement once nothing holds it: a critically damped approach to a whole minute,
/// x(t) = (x₀ + (v₀ + ω x₀) t) e^(−ω t) with x = position − target. With ω = v₀ ∕ distance this is
/// an exponential deceleration that starts at exactly the release speed and never overshoots.
public struct RulerMotion: Equatable, Sendable {
    public enum Kind: String, Sendable {
        /// Momentum after a release (deceleration to the projected minute).
        case momentum
        /// A slow release, or back from past an end (spring to the nearest minute).
        case settle
        /// Wheel or key steps (spring to the stepped minute).
        case step
    }

    public var kind: Kind
    public var start: Double
    /// A whole minute within the range.
    public var target: Int
    /// Minutes per second at the start.
    public var velocity: Double
    public var omega: Double
    public var startTime: Double

    public init(kind: Kind, start: Double, target: Int, velocity: Double, omega: Double, startTime: Double) {
        self.kind = kind
        self.start = start
        self.target = target
        self.velocity = velocity
        self.omega = omega
        self.startTime = startTime
    }

    public func position(at time: Double) -> Double {
        let t = max(0, time - startTime)
        let x0 = start - Double(target)
        return Double(target) + (x0 + (velocity + omega * x0) * t) * exp(-omega * t)
    }

    public func velocity(at time: Double) -> Double {
        let t = max(0, time - startTime)
        let x0 = start - Double(target)
        let b = velocity + omega * x0
        return (b - omega * (x0 + b * t)) * exp(-omega * t)
    }

    /// Close enough to rest on the target: under a tenth of a point away and nearly still (the
    /// exponential's long tail is invisible), or long over.
    public func isFinished(at time: Double) -> Bool {
        let t = time - startTime
        if t > 12 / max(omega, 0.1) { return true }
        return abs(position(at: time) - Double(target)) < 0.01 && abs(velocity(at: time)) < 0.1
    }
}

/// How the ruler moves after an input lets go.
public struct RulerPhysics: Equatable, Sendable {
    /// Momentum travels release speed × this (iOS's normal deceleration, 0.998 per ms).
    public var decelerationTime: Double = 0.5
    /// Slower releases (minutes per second) only settle.
    public var momentumThreshold: Double = 1.5
    /// Spring response of a settle and of a step, seconds.
    public var settleResponse: Double = 0.3
    public var stepResponse: Double = 0.25
    /// Limits of the momentum's time constant (very short or long deceleration).
    public var shortestDeceleration: Double = 0.08
    public var longestDeceleration: Double = 0.8

    public init() {}

    /// The motion after a release at `position` (drawn) with `velocity` (minutes per second).
    public func release(position: Double, velocity: Double, time: Double, scale: TimerRulerScale) -> RulerMotion {
        let lower = Double(scale.minimum), upper = Double(scale.maximum)
        if position < lower || position > upper {
            // Back from past an end.
            return RulerMotion(kind: .settle, start: position, target: scale.selected(position), velocity: velocity,
                               omega: 2 * .pi / settleResponse, startTime: time)
        }
        guard velocity.isFinite, abs(velocity) >= momentumThreshold else {
            return RulerMotion(kind: .settle, start: position, target: scale.selected(position),
                               velocity: velocity.isFinite ? velocity : 0, omega: 2 * .pi / settleResponse, startTime: time)
        }
        let projected = position + velocity * decelerationTime
        let target = scale.selected(projected)
        let distance = Double(target) - position
        guard distance * velocity > 0 else {
            return RulerMotion(kind: .settle, start: position, target: target, velocity: velocity,
                               omega: 2 * .pi / settleResponse, startTime: time)
        }
        let tau = min(longestDeceleration, max(shortestDeceleration, distance / velocity))
        return RulerMotion(kind: .momentum, start: position, target: target, velocity: velocity, omega: 1 / tau, startTime: time)
    }

    /// A spring from where the ruler is (keeping its speed) to a stepped minute.
    public func step(from position: Double, velocity: Double, to target: Int, time: Double, scale: TimerRulerScale) -> RulerMotion {
        RulerMotion(kind: .step, start: position, target: scale.clamp(target), velocity: velocity.isFinite ? velocity : 0,
                    omega: 2 * .pi / stepResponse, startTime: time)
    }
}

/// Release speed from the last moments of a drag or swipe: positions in minutes, seconds.
public struct RulerVelocityTracker: Equatable, Sendable {
    public struct Sample: Equatable, Sendable {
        public var time: Double
        public var position: Double
    }

    /// Movement considered for the speed.
    public var window: Double = 0.08
    /// No momentum when nothing moved for this long before the release.
    public var stillTime: Double = 0.06
    public private(set) var samples: [Sample] = []

    public init() {}

    public mutating func reset() { samples.removeAll() }

    public mutating func add(position: Double, time: Double) {
        samples.append(Sample(time: time, position: position))
        // Keep a little more than the window.
        if let last = samples.last { samples.removeAll { $0.time < last.time - window * 2 } }
    }

    /// Minutes per second at a release at `time`.
    public func velocity(at time: Double) -> Double {
        guard let last = samples.last, time - last.time <= stillTime else { return 0 }
        let recent = samples.filter { $0.time >= last.time - window }
        guard let first = recent.first, last.time - first.time > 0.005 else { return 0 }
        return (last.position - first.position) / (last.time - first.time)
    }
}

// MARK: - Haptic ticks

/// One tick each time the selected minute changes, at most one per `interval`; changes in between
/// are merged into the next tick, which is strong when any of them passed a multiple of 5.
public struct RulerTicker: Equatable, Sendable {
    public enum Tick: String, Sendable {
        /// `alignment` pattern.
        case minute
        /// The stronger `levelChange` pattern (a multiple of 5 was reached or passed).
        case five
    }

    public var interval: Double = 0.025
    /// The minute of the last tick (or where the ruler started).
    public private(set) var lastMinute: Int?
    private var lastTime: Double?
    /// Changes merged into a later tick.
    public private(set) var merged = 0

    public init() {}

    /// Starts from a minute without a tick.
    public mutating func reset(to minute: Int) {
        lastMinute = minute
        lastTime = nil
    }

    /// Whether a change has waited for its tick (the rate limit).
    public func isPending(selected: Int) -> Bool { lastMinute.map { $0 != selected } ?? false }

    public mutating func update(selected: Int, now: Double) -> Tick? {
        guard let last = lastMinute else {
            lastMinute = selected
            return nil
        }
        guard selected != last else { return nil }
        if let lastTime, now - lastTime < interval {
            merged += 1
            return nil
        }
        let tick: Tick = Self.passesFive(from: last, to: selected) ? .five : .minute
        lastMinute = selected
        lastTime = now
        return tick
    }

    /// Whether moving from `a` to `b` reaches or passes a multiple of 5 (not counting `a` itself).
    public static func passesFive(from a: Int, to b: Int) -> Bool {
        guard a != b else { return false }
        let range = a < b ? (a + 1)...b : b...(a - 1)
        return range.contains { $0 % 5 == 0 }
    }
}

// MARK: - Gesture routing on the ruler page

/// The first `lockDistance` points of a trackpad gesture decide who gets it: mostly horizontal →
/// the ruler (with everything that came before), otherwise the island's swipes. Deltas are AppKit
/// scroll deltas; only their sizes matter here.
public struct RulerGestureRouter: Equatable, Sendable {
    public enum Owner: String, Sendable { case undecided, ruler, island }

    public enum Decision: Equatable, Sendable {
        /// Not decided yet; nothing to deliver.
        case wait
        /// Deliver to the ruler (the accumulated delta at the decision, then each delta).
        case ruler(dx: CGFloat)
        /// Deliver to the island's swipe recognizer.
        case island(dx: CGFloat, dy: CGFloat)
    }

    public var lockDistance: CGFloat = 8
    public private(set) var owner: Owner = .undecided
    /// Owner of the last gesture, kept after it ended (for its momentum events).
    public private(set) var lastOwner: Owner = .undecided
    private var pending = CGSize.zero

    public init() {}

    public mutating func began() {
        owner = .undecided
        pending = .zero
    }

    public mutating func changed(dx: CGFloat, dy: CGFloat) -> Decision {
        switch owner {
        case .ruler: return .ruler(dx: dx)
        case .island: return .island(dx: dx, dy: dy)
        case .undecided:
            pending.width += dx
            pending.height += dy
            guard max(abs(pending.width), abs(pending.height)) >= lockDistance else { return .wait }
            owner = abs(pending.width) > abs(pending.height) ? .ruler : .island
            lastOwner = owner
            defer { pending = .zero }
            return owner == .ruler ? .ruler(dx: pending.width) : .island(dx: pending.width, dy: pending.height)
        }
    }

    /// The gesture ended; returns who had it.
    public mutating func ended() -> Owner {
        let had = owner
        lastOwner = had
        owner = .undecided
        pending = .zero
        return had
    }
}

// MARK: - Wheel and keys

public enum RulerInput {
    /// Minutes moved by a line-based wheel event (scroll deltas, AppKit signs): at least one per
    /// notch, more with the wheel's acceleration; scrolling down or right → more.
    public static func wheelSteps(deltaX: Double, deltaY: Double) -> Int {
        let delta = abs(deltaY) >= abs(deltaX) ? deltaY : deltaX
        guard delta != 0, delta.isFinite else { return 0 }
        let steps = max(1, Int(abs(delta).rounded(.up)))
        return delta < 0 ? steps : -steps
    }

    /// Ruler movement (minutes) for a continuous scroll delta in points: scrolling right (content
    /// moving left) → more.
    public static func minutes(forScroll delta: CGFloat, scale: TimerRulerScale) -> Double {
        Double(-delta / scale.spacing)
    }
}

/// What a key does on the ruler.
public enum RulerKeyAction: Equatable, Sendable {
    case step(Int)
    case previousFive
    case nextFive
    case start
    case close
    /// Not the ruler's: the keyboard goes back to the frontmost app.
    case other

    public static let leftArrow: UInt16 = 123
    public static let rightArrow: UInt16 = 124
    public static let returnKey: UInt16 = 36
    public static let keypadEnter: UInt16 = 76
    public static let escape: UInt16 = 53

    public static func from(keyCode: UInt16, shift: Bool, command: Bool, option: Bool, control: Bool) -> RulerKeyAction {
        guard !command, !option, !control else { return .other }
        switch keyCode {
        case leftArrow: return shift ? .previousFive : .step(-1)
        case rightArrow: return shift ? .nextFive : .step(1)
        case returnKey, keypadEnter: return .start
        case escape: return .close
        default: return .other
        }
    }

    /// The minute a step lands on from `minute`.
    public func target(from minute: Int, scale: TimerRulerScale) -> Int? {
        switch self {
        case .step(let delta): return scale.clamp(minute + delta)
        case .previousFive:
            let below = minute % 5 == 0 ? minute - 5 : minute - minute % 5
            return scale.clamp(below)
        case .nextFive:
            return scale.clamp(minute - minute % 5 + 5)
        case .start, .close, .other: return nil
        }
    }
}

/// Keyboard focus on the ruler, the same rule as the Shelf's: only while an island is open on
/// the ruler with the pointer inside it, and not after a foreign key until the pointer comes back.
public enum RulerKeyboard {
    public static func wantsFocus(rulerOpen: Bool, pointerInside: Bool, gaveBack: Bool) -> Bool {
        rulerOpen && pointerInside && !gaveBack
    }
}

// MARK: - Quick presets

/// The quick presets (`timer.presets`): whole minutes 1 … 1440, sorted, without duplicates, at most
/// eight. Stored as an array of numbers; a launch argument may give it as text ("1,3,5,10").
public struct TimerQuickPresets: SettingValue, Sendable {
    public static let standard = TimerQuickPresets(minutes: [3, 5, 10])
    public static let maximumCount = 8
    public static let range = 1...1440

    public let minutes: [Int]

    public init(minutes: [Int]) {
        self.minutes = Array(Set(minutes.filter { Self.range.contains($0) }).sorted().prefix(Self.maximumCount))
    }

    public static func decode(_ object: Any) -> TimerQuickPresets? {
        if let array = object as? [Any] {
            let values = array.compactMap { item -> Int? in
                if let number = item as? NSNumber {
                    let value = number.doubleValue
                    return value.rounded() == value ? Int(value) : nil
                }
                return (item as? String).flatMap(parseMinutes)
            }
            guard values.count == array.count || !values.isEmpty else { return nil }
            return TimerQuickPresets(minutes: values)
        }
        if let text = object as? String {
            let parts = text.split(whereSeparator: { $0 == "," || $0 == " " || $0 == ";" }).map(String.init)
            let values = parts.compactMap(parseMinutes)
            guard values.count == parts.count || !values.isEmpty else { return nil }
            return TimerQuickPresets(minutes: values)
        }
        return nil
    }

    public var encoded: Any? { minutes }

    /// Whole minutes typed in Settings: `25`, `25 min`, `25m` (1 … 1440).
    public static func parseMinutes(_ text: String) -> Int? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for suffix in ["minutes", "minute", "mins", "min", "m"] where value.hasSuffix(suffix) {
            value = String(value.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
            break
        }
        guard !value.isEmpty, value.allSatisfy(\.isASCII), value.allSatisfy(\.isNumber), let minutes = Int(value),
              range.contains(minutes) else { return nil }
        return minutes
    }

    public enum AddResult: Equatable, Sendable {
        case added(TimerQuickPresets)
        case invalid
        case duplicate
        case full
    }

    public func adding(_ text: String) -> AddResult {
        guard let value = Self.parseMinutes(text) else { return .invalid }
        guard !minutes.contains(value) else { return .duplicate }
        guard minutes.count < Self.maximumCount else { return .full }
        return .added(TimerQuickPresets(minutes: minutes + [value]))
    }

    public func removing(_ value: Int) -> TimerQuickPresets {
        TimerQuickPresets(minutes: minutes.filter { $0 != value })
    }

    /// Why a typed value can't be added, for the Settings row.
    public static func message(for result: AddResult) -> String? {
        switch result {
        case .added: return nil
        case .invalid: return "Type whole minutes from 1 to 1440."
        case .duplicate: return "That preset is already in the list."
        case .full: return "Up to \(maximumCount) presets."
        }
    }
}
