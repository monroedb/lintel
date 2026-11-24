import CoreGraphics
import Foundation
import LintelCore

/// Screen lock state (public distributed notifications + session dictionary).
@MainActor
protocol LockStateSource: AnyObject {
    var isLocked: Bool { get }
    var onChange: ((Bool) -> Void)? { get set }
}

/// The lock and unlock notifications, checked against the session dictionary: any process can post
/// the notifications, so an "unlocked" counts only when the window server agrees (`LockStateGate`).
@MainActor
final class SessionLockStateSource: LockStateSource {
    var isLocked: Bool { gate.isLocked }
    var onChange: ((Bool) -> Void)?
    private var gate: LockStateGate
    private let sessionLocked: () -> Bool?
    private var observers: [NSObjectProtocol] = []
    private var recheck: Timer?

    /// `names` and `sessionLocked` are what macOS posts and keeps; a test passes its own.
    init(names: (locked: String, unlocked: String) = ("com.apple.screenIsLocked", "com.apple.screenIsUnlocked"),
         center: DistributedNotificationCenter = .default(),
         sessionLocked: @escaping () -> Bool? = SessionLockStateSource.sessionSaysLocked) {
        self.sessionLocked = sessionLocked
        gate = LockStateGate(sessionLocked: sessionLocked() ?? false)
        for (name, message) in [(names.locked, LockStateGate.Message.locked), (names.unlocked, .unlocked)] {
            observers.append(center.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.receive(message) }
            })
        }
    }

    /// `CGSSessionScreenIsLocked` in the window server's session dictionary; nil when there is none.
    nonisolated static func sessionSaysLocked() -> Bool? {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return nil }
        return (session["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue ?? false
    }

    // An unreadable dictionary never confirms an unlock.
    private func receive(_ message: LockStateGate.Message) {
        apply(gate.receive(message, sessionLocked: sessionLocked() ?? true))
    }

    private func look() {
        apply(gate.recheck(sessionLocked: sessionLocked() ?? true))
    }

    /// The gate's step: the next look replaces any scheduled one, then the change is announced.
    private func apply(_ step: LockStateGate.Step) {
        recheck?.invalidate()
        recheck = nil
        if let delay = step.recheckAfter {
            let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.look() }
            }
            RunLoop.main.add(timer, forMode: .common)
            recheck = timer
        }
        if let locked = step.changed { onChange?(locked) }
    }
}
