import Foundation

/// Which screen-lock messages Lintel believes.
///
/// `com.apple.screenIsLocked` and `com.apple.screenIsUnlocked` are distributed notifications, which
/// any process in the session can post as well. While the session is locked the island's panels stay
/// out of the dedicated window-server space, because that space draws above the lock screen
/// (`IslandSpacePolicy`). A forged "unlocked" must not bring them back over a locked Mac:
///
/// * "Locked" is believed at once. It only sends the panels back under the lock screen and pauses
///   work that nobody can see: the safe direction.
/// * "Unlocked" counts only when the window server's session dictionary agrees
///   (`CGSSessionScreenIsLocked` is missing or false). If it still says locked, the gate looks again
///   on a schedule (the message can come a moment before the dictionary changes) and unlocks as soon
///   as it agrees. Until then Lintel stays locked; a "locked" message ends the wait.
public struct LockStateGate: Equatable, Sendable {
    public enum Message: String, Sendable {
        case locked
        case unlocked
    }

    /// What a message or a look changed.
    public struct Step: Equatable, Sendable {
        /// The new lock state; nil when it didn't change.
        public var changed: Bool?
        /// Seconds until the next look at the session dictionary; nil when nothing waits.
        public var recheckAfter: TimeInterval?

        public init(changed: Bool? = nil, recheckAfter: TimeInterval? = nil) {
            self.changed = changed
            self.recheckAfter = recheckAfter
        }
    }

    /// Delays before the first looks after an "unlocked" that the session didn't confirm yet; every
    /// later look waits `slowRecheck`, until the session agrees or a "locked" arrives.
    public static let quickRechecks: [TimeInterval] = [0.1, 0.25, 0.5, 1, 2]
    public static let slowRecheck: TimeInterval = 5

    public private(set) var isLocked: Bool
    /// An "unlocked" message is waiting for the session dictionary to agree.
    public private(set) var awaitingUnlock = false
    /// Looks taken since that message.
    public private(set) var looks = 0

    /// `sessionLocked`: what the session dictionary says when Lintel starts.
    public init(sessionLocked: Bool) {
        isLocked = sessionLocked
    }

    public static func recheckDelay(afterLooks looks: Int) -> TimeInterval {
        looks < quickRechecks.count ? quickRechecks[looks] : slowRecheck
    }

    /// A message arrived; `sessionLocked` is what the session dictionary says now.
    public mutating func receive(_ message: Message, sessionLocked: Bool) -> Step {
        switch message {
        case .locked:
            awaitingUnlock = false
            looks = 0
            guard !isLocked else { return Step() }
            isLocked = true
            return Step(changed: true)
        case .unlocked:
            guard isLocked else { return Step() }
            if !sessionLocked { return unlock() }
            // Not confirmed: wait, starting the schedule again (a real unlock may follow a forged one).
            awaitingUnlock = true
            looks = 0
            return Step(recheckAfter: Self.recheckDelay(afterLooks: 0))
        }
    }

    /// The scheduled look while an "unlocked" waits.
    public mutating func recheck(sessionLocked: Bool) -> Step {
        guard awaitingUnlock, isLocked else { return Step() }
        if !sessionLocked { return unlock() }
        looks += 1
        return Step(recheckAfter: Self.recheckDelay(afterLooks: looks))
    }

    private mutating func unlock() -> Step {
        awaitingUnlock = false
        looks = 0
        isLocked = false
        return Step(changed: false)
    }
}
