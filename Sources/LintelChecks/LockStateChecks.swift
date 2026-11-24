import Foundation
import LintelCore

/// The screen-lock messages Lintel believes (`LockStateGate`). Regression: any process can post
/// `com.apple.screenIsUnlocked`, and a forged one used to bring the island's panels back into the
/// dedicated space, which draws above the lock screen, while the Mac was still locked.
func runLockStateChecks() {
    typealias Gate = LockStateGate

    // Follows the gate's schedule after an "unlocked" at t = 0 until it unlocks or `limit` passes.
    // `sessionLocked(t)` is the session dictionary at time t. Returns the unlock time, or nil.
    func unlockTime(session sessionLocked: (Double) -> Bool, limit: Double = 600) -> Double? {
        var gate = Gate(sessionLocked: true)
        var t = 0.0
        var step = gate.receive(.unlocked, sessionLocked: sessionLocked(t))
        while step.changed == nil, let delay = step.recheckAfter, t + delay <= limit {
            t += delay
            step = gate.recheck(sessionLocked: sessionLocked(t))
        }
        return step.changed == false ? t : nil
    }

    // Start: whatever the session dictionary says.
    check(!Gate(sessionLocked: false).isLocked && Gate(sessionLocked: true).isLocked, "lock gate starts from the session dictionary")

    // A real lock and unlock.
    var real = Gate(sessionLocked: false)
    check(real.receive(.locked, sessionLocked: true) == .init(changed: true), "lock message → locked at once")
    check(real.receive(.unlocked, sessionLocked: false) == .init(changed: false) && !real.isLocked,
          "unlock message the session confirms → unlocked at once, nothing scheduled")

    // The regression: a forged "unlocked" while the Mac is locked.
    var forged = Gate(sessionLocked: true)
    let first = forged.receive(.unlocked, sessionLocked: true)
    check(first.changed == nil && forged.isLocked && forged.awaitingUnlock,
          "forged unlock (session still locked) → stays locked")
    check(first.recheckAfter == 0.1, "…and looks at the session again after 0.1 s")
    let place = IslandSpacePolicy.decide(switchedOn: true, available: true, locked: forged.isLocked)
    check(place.mode == .allSpaces && place.reason == .locked,
          "…so the panels stay out of the level-400 space, under the lock screen")
    var delays: [TimeInterval] = []
    var stayedLocked = true
    for _ in 0..<40 {  // more than three minutes of looks
        let step = forged.recheck(sessionLocked: true)
        stayedLocked = stayedLocked && step.changed == nil && forged.isLocked
        delays.append(step.recheckAfter ?? -1)
    }
    check(stayedLocked, "forged unlock: 40 looks at a locked session never unlock")
    check(Array(delays.prefix(5)) == [0.25, 0.5, 1, 2, 5] && delays.dropFirst(4).allSatisfy { $0 == 5 },
          "forged unlock: looks back off to every 5 s and keep going (got \(delays.prefix(6)))")
    check(forged.recheck(sessionLocked: false) == .init(changed: false) && !forged.isLocked && !forged.awaitingUnlock,
          "the real unlock later: the next look sees the session unlocked → unlocked")
    check(forged.recheck(sessionLocked: true) == .init(), "a stray look after unlocking does nothing")

    // A lock message ends the wait.
    var cancelled = Gate(sessionLocked: true)
    _ = cancelled.receive(.unlocked, sessionLocked: true)
    check(cancelled.receive(.locked, sessionLocked: true) == .init() && !cancelled.awaitingUnlock,
          "lock message while an unlock waits → still locked, the wait ends")
    check(cancelled.recheck(sessionLocked: false) == .init() && cancelled.isLocked,
          "a look scheduled before that lock message no longer unlocks")

    // A real unlock that comes a moment before the session dictionary changes.
    check(unlockTime(session: { $0 < 0.3 }).map { abs($0 - 0.35) < 1e-9 } == true,
          "dictionary clears 0.3 s after the message → unlocked at 0.35 s")
    check(unlockTime(session: { _ in false }) == 0, "dictionary already clear → unlocked at once")
    if let late = unlockTime(session: { $0 < 60 }) {
        check(late >= 60 && late <= 65, "dictionary clears after a minute → unlocked within 5 s of it (got \(late))")
    } else {
        check(false, "dictionary clears after a minute → still unlocks")
    }
    check(unlockTime(session: { _ in true }) == nil, "dictionary never clears → never unlocks")
    check(Gate.quickRechecks.reduce(0, +) < 4 && Gate.slowRecheck == 5, "quick looks within 4 s, then every 5 s")

    // A new "unlocked" (a real one after a forged one) starts the quick looks again.
    var again = Gate(sessionLocked: true)
    _ = again.receive(.unlocked, sessionLocked: true)
    for _ in 0..<8 { _ = again.recheck(sessionLocked: true) }
    check(again.receive(.unlocked, sessionLocked: true).recheckAfter == 0.1 && again.looks == 0,
          "another unlock message restarts the schedule at 0.1 s")
    check(again.receive(.unlocked, sessionLocked: false) == .init(changed: false), "…and one the session confirms unlocks")

    // Messages that change nothing.
    var unlocked = Gate(sessionLocked: false)
    check(unlocked.receive(.unlocked, sessionLocked: true) == .init() && !unlocked.awaitingUnlock,
          "unlock message while unlocked → nothing to do, nothing scheduled")
    var locked = Gate(sessionLocked: true)
    check(locked.receive(.locked, sessionLocked: true) == .init(), "lock message while locked → no change")

    // A forged "locked" is believed (the safe direction) and a confirmed "unlocked" undoes it.
    var spoofedLock = Gate(sessionLocked: false)
    check(spoofedLock.receive(.locked, sessionLocked: false) == .init(changed: true),
          "lock message is believed even when the session says unlocked (only ever hides the island)")
    check(spoofedLock.receive(.unlocked, sessionLocked: false) == .init(changed: false), "…and the next unlock message ends it")
}
