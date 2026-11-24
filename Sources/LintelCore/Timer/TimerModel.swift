import Foundation

/// Fixed numbers of Lintel's timer.
public struct TimerPolicy: Equatable, Sendable {
    /// Seconds between rings while "Keep ringing until dismissed" is on.
    public var ringInterval: Double = 3
    /// Safety cap: the alert stops ringing this long after it started (40 rings at 3 s).
    public var ringCap: Double = 120
    /// A single-ring alert (repeat off) stays this long, then the timer is gone.
    public var singleRingHold: Double = 10
    /// An end noticed up to this late still rings; later it goes straight to done.
    public var lateGrace: Double = 300
    /// A done timer is forgotten this long after its end.
    public var forgetAfter: Double = 12 * 3600
    /// The countdown turns urgent with this much (shown) time left.
    public var urgentSeconds: Int = 10
    /// What "+1 min" adds.
    public var addStep: Double = 60
    /// A late alert mentions the delay from this lateness on.
    public var lateNoteFrom: Double = 30

    public static let minimumDuration: Double = 1
    public static let maximumDuration: Double = 24 * 3600
    /// Preset tiles and menu items, in minutes.
    public static let presetMinutes: [Int] = [1, 3, 5, 10, 15, 25, 30]

    public init() {}

    /// Whole seconds within 1 s … 24 h, or nil.
    public static func validDuration(_ seconds: Double) -> Double? {
        guard seconds.isFinite else { return nil }
        let rounded = seconds.rounded()
        guard rounded >= minimumDuration, rounded <= maximumDuration else { return nil }
        return rounded
    }
}

/// One timer. Pure value; every change goes through `TimerMachine`.
public struct TimerState: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        /// Counting down to a wall-clock end.
        case running(end: Date)
        case paused(remaining: Double)
        /// Ended at `at`. `alerted`: the alert started; `silenced`: it stopped ringing (cap, or late).
        case finished(at: Date, alerted: Bool, silenced: Bool)
    }

    public var id: String
    /// What the user chose; Restart runs it again.
    public var preset: Double
    /// Length of the current run (grows with "+1 min"); progress = elapsed ÷ duration.
    public var duration: Double
    /// Bumped by every user change and by the end (the live activity's identity).
    public var revision: Int
    public var phase: Phase

    public init(id: String, preset: Double, duration: Double, revision: Int = 0, phase: Phase) {
        self.id = id
        self.preset = preset
        self.duration = duration
        self.revision = revision
        self.phase = phase
    }

    public var isRunning: Bool { if case .running = phase { return true }; return false }
    public var isPaused: Bool { if case .paused = phase { return true }; return false }
    public var isFinished: Bool { if case .finished = phase { return true }; return false }
    /// Ended and no longer ringing: waits quietly until dismissed.
    public var isDone: Bool { if case .finished(_, _, true) = phase { return true }; return false }

    /// Live-activity identity: changes with every user change and at the end.
    public var identity: String { "timer-\(id)-\(revision)" }

    public var end: Date? {
        switch phase {
        case .running(let end): return end
        case .finished(let at, _, _): return at
        case .paused: return nil
        }
    }

    /// Seconds left (0 once ended).
    public func remaining(at now: Date) -> Double {
        switch phase {
        case .running(let end): return max(0, end.timeIntervalSince(now))
        case .paused(let remaining): return max(0, remaining)
        case .finished: return 0
        }
    }

    /// Whole seconds shown: rounded up, so `0:01` shows until the end; the tolerance keeps a value
    /// that is a hair above a whole second (timer jitter) on that second.
    public func shownSeconds(at now: Date) -> Int {
        Self.shownSeconds(remaining: remaining(at: now))
    }

    public static func shownSeconds(remaining: Double) -> Int {
        max(0, Int((remaining - 0.05).rounded(.up)))
    }

    /// Part of the run still to go, 0…1 (the ring shows this part).
    public func remainingFraction(at now: Date) -> Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, remaining(at: now) / duration))
    }

    /// Last seconds of a running or paused timer (the shown value is at most `urgentSeconds`).
    public func isUrgent(at now: Date, policy: TimerPolicy = TimerPolicy()) -> Bool {
        switch phase {
        case .running, .paused: return shownSeconds(at: now) <= policy.urgentSeconds
        case .finished: return false
        }
    }
}

/// The alert of an ended timer: when it rang first, whether it repeats, how many rings played.
public struct TimerAlert: Equatable, Sendable {
    public var endedAt: Date
    public var startedAt: Date
    public var repeats: Bool
    public var ringsPlayed: Int

    public init(endedAt: Date, startedAt: Date, repeats: Bool, ringsPlayed: Int = 0) {
        self.endedAt = endedAt
        self.startedAt = startedAt
        self.repeats = repeats
        self.ringsPlayed = ringsPlayed
    }

    /// How late the alert started after the timer's end.
    public var lateBy: Double { max(0, startedAt.timeIntervalSince(endedAt)) }

    public func ringCount(policy: TimerPolicy) -> Int {
        guard repeats, policy.ringInterval > 0 else { return 1 }
        return max(1, Int((policy.ringCap / policy.ringInterval).rounded(.up)))
    }

    public func ringTime(_ index: Int, policy: TimerPolicy) -> Date {
        startedAt.addingTimeInterval(Double(index) * (repeats ? policy.ringInterval : 0))
    }

    /// When the alert is over: the cap (repeating) or the hold (single ring).
    public func endsAt(policy: TimerPolicy) -> Date {
        startedAt.addingTimeInterval(repeats ? policy.ringCap : policy.singleRingHold)
    }

    /// Rings whose time has come by `now`.
    public func dueRings(at now: Date, policy: TimerPolicy) -> Int {
        let count = ringCount(policy: policy)
        guard now >= startedAt else { return 0 }
        guard repeats, policy.ringInterval > 0 else { return 1 }
        let elapsed = now.timeIntervalSince(startedAt)
        return min(count, Int((elapsed / policy.ringInterval + 1e-9).rounded(.down)) + 1)
    }

    public func nextRing(policy: TimerPolicy) -> Date? {
        ringsPlayed < ringCount(policy: policy) ? ringTime(ringsPlayed, policy: policy) : nil
    }
}

/// What happened while advancing the timer (the app plays, opens and closes accordingly).
public enum TimerEvent: Equatable, Sendable {
    /// The alert started (ring 0 follows); `late` seconds after the end.
    case alertStarted(late: Double)
    /// Ended too long ago to ring: straight to done.
    case missed(late: Double)
    /// Play ring number `index`.
    case ring(index: Int)
    /// The repeating alert reached its cap: done, quiet.
    case silenced
    /// The single-ring alert's hold passed: the timer is gone.
    case cleared
    /// A done timer was forgotten after `forgetAfter`.
    case forgotten
}

/// Lintel's timer as a deterministic state machine. Callers pass the wall-clock time, apply the
/// events `advance` returns and schedule one task for `nextDeadline` (nothing polls).
public struct TimerMachine: Equatable, Sendable {
    public private(set) var state: TimerState?
    public private(set) var alert: TimerAlert?
    public var policy = TimerPolicy()
    /// "Keep ringing until dismissed" (read when an alert starts).
    public var repeats = true

    public init(state: TimerState? = nil) {
        self.state = state
    }

    public var isRinging: Bool { alert != nil }

    // MARK: User actions (each returns whether anything changed)

    /// Starts (or replaces with) a timer of `seconds`, rounded to whole seconds; nil outside 1 s … 24 h.
    @discardableResult
    public mutating func start(seconds: Double, now: Date, id: String = UUID().uuidString) -> Bool {
        guard let duration = TimerPolicy.validDuration(seconds) else { return false }
        state = TimerState(id: id, preset: duration, duration: duration, revision: 0,
                           phase: .running(end: now.addingTimeInterval(duration)))
        alert = nil
        return true
    }

    @discardableResult
    public mutating func pause(now: Date) -> Bool {
        guard var timer = state, case .running(let end) = timer.phase else { return false }
        let left = end.timeIntervalSince(now)
        guard left > 0.05 else { return false } // about to end: let it finish
        timer.phase = .paused(remaining: left)
        timer.revision += 1
        state = timer
        return true
    }

    @discardableResult
    public mutating func resume(now: Date) -> Bool {
        guard var timer = state, case .paused(let left) = timer.phase else { return false }
        timer.phase = .running(end: now.addingTimeInterval(left))
        timer.revision += 1
        state = timer
        return true
    }

    @discardableResult
    public mutating func togglePause(now: Date) -> Bool {
        state?.isPaused == true ? resume(now: now) : pause(now: now)
    }

    /// "+1 min": more time for a running or paused timer (never above 24 h left); an ended timer runs
    /// again for the step.
    @discardableResult
    public mutating func add(seconds: Double? = nil, now: Date) -> Bool {
        guard var timer = state else { return false }
        let step = (seconds ?? policy.addStep).rounded()
        guard step > 0 else { return false }
        switch timer.phase {
        case .running(let end):
            let left = max(0, end.timeIntervalSince(now))
            let added = min(step, TimerPolicy.maximumDuration - left)
            guard added > 0 else { return false }
            timer.phase = .running(end: end.addingTimeInterval(added))
            timer.duration += added
        case .paused(let left):
            let added = min(step, TimerPolicy.maximumDuration - left)
            guard added > 0 else { return false }
            timer.phase = .paused(remaining: left + added)
            timer.duration += added
        case .finished:
            let run = min(step, TimerPolicy.maximumDuration)
            timer.phase = .running(end: now.addingTimeInterval(run))
            timer.duration = run
            alert = nil
        }
        timer.revision += 1
        state = timer
        return true
    }

    /// Runs the preset again from the start.
    @discardableResult
    public mutating func restart(now: Date) -> Bool {
        guard var timer = state else { return false }
        timer.phase = .running(end: now.addingTimeInterval(timer.preset))
        timer.duration = timer.preset
        timer.revision += 1
        state = timer
        alert = nil
        return true
    }

    /// Cancel (running or paused) or stop (ringing or done): the timer is gone.
    @discardableResult
    public mutating func cancel() -> Bool {
        guard state != nil else { return false }
        state = nil
        alert = nil
        return true
    }

    // MARK: Time

    /// Moves the timer to `now`: the end, rings, the alert's end and forgetting. At most one ring is
    /// reported per call, even when several were missed (e.g. after sleep).
    public mutating func advance(now: Date) -> [TimerEvent] {
        var events: [TimerEvent] = []
        if var timer = state, case .running(let end) = timer.phase, now >= end {
            timer.revision += 1
            state = timer
            events += endReached(at: end, now: now)
        }
        if var current = alert, var timer = state, case .finished(let at, _, _) = timer.phase {
            let due = current.dueRings(at: now, policy: policy)
            if due > current.ringsPlayed {
                events.append(.ring(index: due - 1))
                current.ringsPlayed = due
                alert = current
            }
            if now >= current.endsAt(policy: policy) {
                alert = nil
                if current.repeats {
                    timer.phase = .finished(at: at, alerted: true, silenced: true)
                    state = timer
                    events.append(.silenced)
                } else {
                    state = nil
                    events.append(.cleared)
                }
            }
        }
        if let timer = state, case .finished(let at, _, true) = timer.phase,
           now.timeIntervalSince(at) >= policy.forgetAfter {
            state = nil
            events.append(.forgotten)
        }
        return events
    }

    /// The end: ring (with the alert) when noticed in time, else done without a sound.
    private mutating func endReached(at end: Date, now: Date) -> [TimerEvent] {
        guard var timer = state else { return [] }
        let late = max(0, now.timeIntervalSince(end))
        if late <= policy.lateGrace {
            timer.phase = .finished(at: end, alerted: true, silenced: false)
            state = timer
            alert = TimerAlert(endedAt: end, startedAt: now, repeats: repeats)
            return [.alertStarted(late: late)]
        }
        timer.phase = .finished(at: end, alerted: false, silenced: true)
        state = timer
        alert = nil
        return [.missed(late: late)]
    }

    /// The next moment `advance` has something to do.
    public func nextDeadline() -> Date? {
        guard let state else { return nil }
        switch state.phase {
        case .running(let end):
            return end
        case .paused:
            return nil
        case .finished(let at, _, let silenced):
            if let alert {
                return [alert.nextRing(policy: policy), alert.endsAt(policy: policy)].compactMap { $0 }.min()
            }
            return silenced ? at.addingTimeInterval(policy.forgetAfter) : nil
        }
    }

    // MARK: Persistence

    /// What is stored (no alert details: the restore rules re-derive them).
    public var snapshot: TimerSnapshot? { state.map(TimerSnapshot.init(state:)) }

    /// Restores a stored timer at launch, then advances it to `now`.
    public mutating func restore(_ snapshot: TimerSnapshot?, now: Date) -> [TimerEvent] {
        alert = nil
        guard let snapshot, var timer = snapshot.state else {
            state = nil
            return []
        }
        if case .finished(let at, let alerted, let silenced) = timer.phase, !silenced {
            if alerted && !repeats {
                // A single-ring alert that already played isn't repeated.
                state = nil
                return [.cleared]
            }
            // Quit while ringing, or ended before the alert could start: ring again if still in time.
            let late = max(0, now.timeIntervalSince(at))
            if late <= policy.lateGrace {
                state = timer
                alert = TimerAlert(endedAt: at, startedAt: now, repeats: repeats)
                return [.alertStarted(late: late)] + advance(now: now)
            }
            timer.phase = .finished(at: at, alerted: alerted, silenced: true)
            state = timer
            return [.missed(late: late)] + advance(now: now)
        }
        state = timer
        return advance(now: now)
    }
}

/// `timer.state` as stored (JSON, version 1): dates as seconds since the reference date.
public struct TimerSnapshot: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var id: String
    public var preset: Double
    public var duration: Double
    public var revision: Int
    /// `running`, `paused` or `finished`.
    public var phase: String
    public var end: Date?
    public var remaining: Double?
    public var alerted: Bool?
    public var silenced: Bool?

    public init(state: TimerState) {
        version = Self.currentVersion
        id = state.id
        preset = state.preset
        duration = state.duration
        revision = state.revision
        switch state.phase {
        case .running(let end):
            phase = "running"
            self.end = end
        case .paused(let left):
            phase = "paused"
            remaining = left
        case .finished(let at, let alerted, let silenced):
            phase = "finished"
            end = at
            self.alerted = alerted
            self.silenced = silenced
        }
    }

    /// The timer it describes; nil for unknown versions or inconsistent values.
    public var state: TimerState? {
        guard version == Self.currentVersion, !id.isEmpty,
              let preset = TimerPolicy.validDuration(preset),
              duration.isFinite, duration > 0, duration <= TimerPolicy.maximumDuration else { return nil }
        let phase: TimerState.Phase
        switch self.phase {
        case "running":
            guard let end else { return nil }
            phase = .running(end: end)
        case "paused":
            guard let remaining, remaining.isFinite, remaining >= 0, remaining <= TimerPolicy.maximumDuration else { return nil }
            phase = .paused(remaining: remaining)
        case "finished":
            guard let end else { return nil }
            phase = .finished(at: end, alerted: alerted ?? false, silenced: silenced ?? false)
        default:
            return nil
        }
        return TimerState(id: id, preset: preset, duration: duration, revision: max(0, revision), phase: phase)
    }

    public var json: String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func decode(_ json: String) -> TimerSnapshot? {
        try? JSONDecoder().decode(TimerSnapshot.self, from: Data(json.utf8))
    }
}
