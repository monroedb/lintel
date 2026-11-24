import Foundation
import LintelCore

/// One island's activity engine: applies settings, feeds hub events in, expires notifications and
/// peeks on time, and tells the controller after every change.
@MainActor
final class IslandActivity {
    private(set) var engine = ActivityEngine()
    /// Called after every mutation; the controller compares the result with what it shows.
    var onChange: (() -> Void)?

    private let settings: SettingsStore
    private var deadlineTask: Task<Void, Never>?

    init(settings: SettingsStore) {
        self.settings = settings
        applySettings()
    }

    static var now: Double { ProcessInfo.processInfo.systemUptime }

    func applySettings() {
        let settings = self.settings
        mutate { engine in
            engine.filters = NotificationFilters(
                allowedWhenFocused: Set(NotificationGroup.allCases.filter { settings[Keys.allowWhenFocused($0)] })
            )
            var peeks = PeekSettings()
            peeks.mediaEnabled = settings[Keys.mediaPeek]
            peeks.mediaOnChange = settings[Keys.mediaPeekOnChange]
            peeks.mediaDuration = settings[Keys.mediaPeekDuration]
            peeks.calendarEnabled = settings[Keys.calendarPeek]
            peeks.calendarBeforeStart = settings[Keys.calendarPeekBefore]
            peeks.calendarAtStart = settings[Keys.calendarPeekAtStart]
            peeks.calendarDuration = settings[Keys.calendarPeekDuration]
            engine.peeks = peeks
            engine.idleContent = ExpandedContent(idle: settings[Keys.idleActivity])
            engine.timerPageEnabled = settings[Keys.timerEnabled]
            if engine.idleContent == .timer, !engine.timerPageEnabled { engine.idleContent = .media }
            engine.followMostRecent = settings[Keys.followMostRecent]
            engine.shelfEnabled = settings[Keys.shelfEnabled]
        }
    }

    /// Seeds a new island with the sources that are already active.
    func seed(from hub: ActivityHub) {
        let now = Self.now
        mutate { engine in
            if let media = hub.media { engine.setLive(.media, active: true, identity: media.identity, now: now) }
            if let calendar = hub.calendar { engine.setLive(.calendar, active: true, identity: calendar.identity, now: now) }
            if let timer = hub.timer.liveIdentity { engine.setLive(.timer, active: true, identity: timer, now: now) }
            if let shelf = hub.shelf { engine.setLive(.shelf, active: true, identity: shelf.identity, now: now) }
            engine.updateContext { $0.focusActive = hub.focusActive }
        }
    }

    func handle(_ event: ActivityEvent, hub: ActivityHub) {
        let now = Self.now
        switch event {
        case .live(let kind, let active, let identity):
            mutate { $0.setLive(kind, active: active, identity: identity, now: now) }
        case .notification(let kind):
            // The hold counts from when the notification is fully shown (see notificationLeadIn).
            let extending = kind.isHUD && engine.notification?.kind == kind
            let leadIn = extending ? 0 : SwapTiming.notificationLeadIn(from: engine.compactPresentation, to: .notification(kind),
                                                                      expanded: engine.context.expanded)
            let duration = settings[Keys.duration(kind)] + leadIn
            mutate { _ = $0.post(kind, duration: duration, now: now) }
        case .peek(let kind, let userInitiated, let trigger):
            mutate { _ = $0.requestPeek(kind, userInitiated: userInitiated, calendarTrigger: trigger, now: now) }
        case .context:
            mutate { engine in engine.updateContext { $0.focusActive = hub.focusActive } }
        }
    }

    func mutate(_ body: (inout ActivityEngine) -> Void) {
        body(&engine)
        scheduleDeadline()
        onChange?()
    }

    private func scheduleDeadline() {
        deadlineTask?.cancel()
        guard let deadline = engine.nextDeadline else { return }
        let delay = max(0, deadline - Self.now)
        deadlineTask = Task { [weak self] in
            // Explicit tolerance: the default leeway grows with the interval (≈ 100–150 ms late on a 2 s hold).
            try? await Task.sleep(for: .seconds(delay), tolerance: .milliseconds(10))
            guard !Task.isCancelled, let self else { return }
            self.mutate { _ = $0.tick(now: Self.now) }
        }
    }

    func cancel() { deadlineTask?.cancel() }
}
