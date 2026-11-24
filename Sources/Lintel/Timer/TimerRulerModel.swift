import AppKit
import LintelCore
import Observation
import QuartzCore

/// The Ruler picker on one island: where the ruler is, what holds or
/// moves it, and the inputs that reach it (trackpad swipes, wheels, drags, keys). Every input ends on
/// a whole minute. The island controller routes events here and wires the haptics and Start; the
/// views draw `position` and `selected`.
@MainActor
@Observable
final class TimerRulerModel {
    let scale = TimerRulerScale()
    @ObservationIgnored let physics = RulerPhysics()

    /// Drawn position in minutes (past an end while held).
    private(set) var position = Double(TimerRulerScale.defaultMinutes)
    /// The selected minute: the position rounded, within 1 … 120 (changes less often than `position`).
    private(set) var selected = TimerRulerScale.defaultMinutes

    /// The minute the ruler rests on, or is landing on (what Start uses).
    var restingMinute: Int { motion?.target ?? selected }
    var isMoving: Bool { motion != nil }
    var isHeld: Bool { held }

    @ObservationIgnored private(set) var motion: RulerMotion?
    @ObservationIgnored private var held = false
    /// Unbanded position while held (the rubber band is applied when drawing).
    @ObservationIgnored private var heldRaw = 0.0
    @ObservationIgnored private var dragStartRaw = 0.0
    @ObservationIgnored private var dragging = false
    @ObservationIgnored private var tracker = RulerVelocityTracker()
    @ObservationIgnored private var ticker = RulerTicker()
    /// Who gets the current trackpad gesture on the ruler page.
    @ObservationIgnored var router = RulerGestureRouter()
    @ObservationIgnored private let clock = RulerFrameClock()
    @ObservationIgnored private var smoothSettle: Task<Void, Never>?
    @ObservationIgnored private var pendingTick: Task<Void, Never>?

    /// Plays a haptic tick (set by the island controller).
    @ObservationIgnored var onTick: ((RulerTicker.Tick) -> Void)?
    /// Starts a timer of so many minutes from the picker (Start Timer, Return, a preset pill).
    @ObservationIgnored var onStart: ((Int) -> Void)?
    /// The display the island is on (the frame clock follows its refresh rate).
    @ObservationIgnored var screen: () -> NSScreen? = { NSScreen.main }

    // Counters and recent events.
    @ObservationIgnored private(set) var tickCounts: [String: Int] = [:]
    @ObservationIgnored private(set) var inputCounts: [String: Int] = [:]
    @ObservationIgnored private(set) var log: [String] = []
    @ObservationIgnored private(set) var lastRelease: [String: Double] = [:]

    init() {
        ticker.reset(to: selected)
        clock.owner = self
    }

    static func now() -> Double { CACurrentMediaTime() }

    // MARK: Showing

    /// Puts the ruler on a minute at once, without a tick (the picker appears).
    func reset(to minutes: Int) {
        stopMotion()
        held = false
        dragging = false
        setPosition(Double(scale.clamp(minutes)), tick: false)
    }

    /// The card closed: whatever moved the ruler stops (it is reset when the picker shows again).
    func cardClosed() {
        stopMotion()
        held = false
        dragging = false
    }

    // MARK: Trackpad (phased scroll events)

    /// A finger rests on the trackpad (or a gesture begins): the ruler stops where it is and is held.
    func touch() {
        guard !held else { return }
        if motion != nil { record("caught at \(String(format: "%.2f", position))") }
        stopMotion()
        held = true
        heldRaw = scale.unbanded(position)
        tracker.reset()
        tracker.add(position: heldRaw, time: Self.now())
    }

    /// A horizontal scroll delta (AppKit points; content moving left → more).
    func scroll(deltaX: CGFloat) {
        if !held { touch() }
        guard deltaX != 0 else { return }
        count("swipe")
        heldRaw += RulerInput.minutes(forScroll: deltaX, scale: scale)
        tracker.add(position: heldRaw, time: Self.now())
        setPosition(scale.rubberBanded(heldRaw))
    }

    /// The fingers lifted (momentum) or the gesture was cancelled (settle).
    func release(cancelled: Bool = false) {
        guard held else { return }
        held = false
        dragging = false
        let now = Self.now()
        let velocity = cancelled ? 0 : tracker.velocity(at: now)
        lastRelease = ["position": position, "velocity": velocity, "time": now]
        let motion = physics.release(position: position, velocity: velocity, time: now, scale: scale)
        if motion.kind == .momentum { count("momentum") }
        start(motion)
    }

    // MARK: Pointer drag on the ruler

    /// Drag translation since the mouse went down (points; dragging left → more).
    func drag(translation: CGFloat) {
        if !dragging {
            touch()
            dragging = true
            dragStartRaw = heldRaw
            count("drag")
        }
        heldRaw = dragStartRaw - Double(translation / scale.spacing)
        tracker.add(position: heldRaw, time: Self.now())
        setPosition(scale.rubberBanded(heldRaw))
    }

    func dragEnded() {
        guard dragging else { return }
        release()
    }

    // MARK: Wheels

    /// A line-based wheel event of so many minutes (springs; steps during a spring add up).
    func wheel(steps: Int) {
        guard steps != 0 else { return }
        count("wheel")
        stepTo(restingMinute + steps)
    }

    /// A smooth wheel (precise deltas without phase): follows, then settles 0.15 s after the last event.
    func smoothScroll(delta: CGFloat) {
        guard delta != 0 else { return }
        count("smoothWheel")
        stopMotion()
        held = false
        setPosition(scale.clamp(position + RulerInput.minutes(forScroll: delta, scale: scale)))
        smoothSettle?.cancel()
        smoothSettle = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self else { return }
            self.start(self.physics.release(position: self.position, velocity: 0, time: Self.now(), scale: self.scale))
        }
    }

    // MARK: Keys

    /// ← → ⇧← ⇧→ and Return/Enter; false for keys the ruler doesn't handle (Escape, others).
    @discardableResult
    func key(_ action: RulerKeyAction) -> Bool {
        switch action {
        case .step, .previousFive, .nextFive:
            guard let target = action.target(from: restingMinute, scale: scale) else { return true }
            count("key")
            stepTo(target)
            return true
        case .start:
            startTimer()
            return true
        case .close, .other:
            return false
        }
    }

    // MARK: Starting

    func startTimer() {
        let minutes = restingMinute
        count("start")
        record("start \(minutes) min")
        stopMotion()
        held = false
        dragging = false
        setPosition(Double(minutes), tick: false)
        onStart?(minutes)
    }

    func startPreset(_ minutes: Int) {
        count("preset")
        record("preset \(minutes) min")
        onStart?(minutes)
    }

    // MARK: Motion

    private func stepTo(_ minute: Int) {
        held = false
        dragging = false
        smoothSettle?.cancel()
        let now = Self.now()
        let velocity = motion?.velocity(at: now) ?? 0
        start(physics.step(from: position, velocity: velocity, to: minute, time: now, scale: scale))
    }

    private func start(_ motion: RulerMotion) {
        self.motion = motion
        record("\(motion.kind.rawValue) → \(motion.target) from \(String(format: "%.2f", motion.start)) at \(String(format: "%.1f", motion.velocity)) min/s")
        let running = clock.start(screen: screen()) { [weak self] time in self?.frame(at: time) }
        if !running {
            // No display to pace the motion: rest on the target at once.
            self.motion = nil
            setPosition(Double(motion.target))
        }
    }

    private func frame(at time: Double) {
        guard let motion else {
            clock.stop()
            return
        }
        if motion.isFinished(at: time) {
            self.motion = nil
            clock.stop()
            setPosition(Double(motion.target))
            record("rest \(motion.target)")
        } else {
            setPosition(motion.position(at: time))
        }
    }

    private func stopMotion() {
        motion = nil
        clock.stop()
        smoothSettle?.cancel()
        smoothSettle = nil
    }

    private func setPosition(_ value: Double, tick: Bool = true) {
        if position != value { position = value }
        let minute = scale.selected(value)
        if selected != minute { selected = minute }
        guard tick else {
            ticker.reset(to: minute)
            return
        }
        if let tick = ticker.update(selected: minute, now: Self.now()) {
            emit(tick)
        } else if ticker.isPending(selected: minute) {
            schedulePendingTick()
        }
    }

    /// A change held back by the rate limit still ticks once the ruler stops changing.
    private func schedulePendingTick() {
        guard pendingTick == nil else { return }
        pendingTick = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(30))
            guard let self else { return }
            self.pendingTick = nil
            if let tick = self.ticker.update(selected: self.selected, now: Self.now()) { self.emit(tick) }
        }
    }

    private func emit(_ tick: RulerTicker.Tick) {
        tickCounts[tick.rawValue, default: 0] += 1
        onTick?(tick)
    }

    // MARK: Counters

    private func count(_ input: String) { inputCounts[input, default: 0] += 1 }

    private func record(_ line: String) {
        log.append(String(format: "%.3f ", Self.now()) + line)
        if log.count > 30 { log.removeFirst(log.count - 30) }
    }
}

/// Calls back once per display refresh while the ruler moves (CADisplayLink on the island's
/// display); stopped as soon as the ruler rests, so nothing runs while it is still.
@MainActor
final class RulerFrameClock: NSObject {
    private var link: CADisplayLink?
    private var handler: ((Double) -> Void)?
    /// Frames delivered since launch.
    private(set) var frames = 0
    /// The ruler that runs this clock; the clock stops if it goes away (its island was removed).
    weak var owner: AnyObject?

    /// Starts (or keeps) the frame callbacks; false when there is no display to pace them.
    @discardableResult
    func start(screen: NSScreen?, _ handler: @escaping (Double) -> Void) -> Bool {
        self.handler = handler
        if link != nil { return true }
        guard let screen = screen ?? NSScreen.main else { return false }
        let link = screen.displayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        return true
    }

    func stop() {
        link?.invalidate()
        link = nil
        handler = nil
    }

    @objc private func step(_ link: CADisplayLink) {
        guard owner != nil, let handler else {
            stop()
            return
        }
        frames += 1
        handler(link.targetTimestamp)
    }
}
