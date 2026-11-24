import Foundation

/// Decides what the island shows. Pure and deterministic: callers pass the current time and
/// schedule a timer for `nextDeadline`.
///
public struct ActivityEngine: Sendable {
    public struct Live: Equatable, Sendable {
        public var kind: LiveActivityKind
        public var identity: String
        public var since: Double
    }

    public struct ActiveNotification: Equatable, Sendable {
        public var kind: NotificationKind
        public var identity: String
        public var until: Double
    }

    public struct ActivePeek: Equatable, Sendable {
        public var kind: QuickPeekKind
        public var until: Double
    }

    public enum PostResult: Equatable, Sendable { case shown, extended, filtered }

    public private(set) var live: [LiveActivityKind: Live] = [:]
    /// Dismissed live activities (most recent last), restored on the next collapse after an expansion.
    public private(set) var dismissed: [Live] = []
    public private(set) var notification: ActiveNotification?
    public private(set) var peek: ActivePeek?
    public private(set) var mostRecent: ExpandedContent?
    /// User's cycle choice while expanded; cleared on collapse.
    public private(set) var cycledChoice: ExpandedContent?
    /// Bumped on every change that can alter what is shown; lets callers drop stale completions.
    public private(set) var generation = 0

    public var context = ActivityContext()
    public var filters = NotificationFilters()
    public var peeks = PeekSettings()
    public var idleContent: ExpandedContent = .media
    public var followMostRecent = false
    /// The timer page is in the cycle (Timers switched on).
    public var timerPageEnabled = false
    /// Shelf: the page is offered (cycle, drop zone) only
    /// while the Shelf is on; switching it off leaves the page.
    public var shelfEnabled = true {
        didSet {
            guard !shelfEnabled, oldValue else { return }
            if cycledChoice == .shelf { cycledChoice = nil }
            if mostRecent == .shelf { mostRecent = nil }
            shelfDropFocus = false
            bump()
        }
    }
    /// A file drag is over this island, or files were dropped on it, since it opened.
    public private(set) var shelfDropFocus = false

    public init() {}

    // MARK: Live activities

    public mutating func setLive(_ kind: LiveActivityKind, active: Bool, identity: String = "", now: Double) {
        if active {
            let previous = live[kind]
            if previous?.identity != identity {
                // A new instance (new track, new event) is no longer dismissed.
                dismissed.removeAll { $0.kind == kind }
                live[kind] = Live(kind: kind, identity: identity, since: now)
                if kind != .lock { mostRecent = content(for: kind) }
                bump()
            }
        } else if live[kind] != nil {
            live[kind] = nil
            dismissed.removeAll { $0.kind == kind }
            if case .peek(let peekKind)? = currentPeekPresentation, peekKind.rawValue == kind.rawValue { peek = nil }
            bump()
        }
    }

    /// Live activities currently drawn in the compact island.
    public var visibleLiveKinds: Set<LiveActivityKind> {
        if context.suppressLiveActivities { return [] }
        let dismissedKinds = Set(dismissed.map(\.kind))
        return Set(live.keys).subtracting(dismissedKinds)
    }

    /// Dismisses one visible live activity (the most recently started); returns it.
    @discardableResult
    public mutating func dismissTopLiveActivity() -> LiveActivityKind? {
        let candidates = live.values.filter { $0.kind != .lock && drawnLiveKinds.contains($0.kind) }
        guard let top = candidates.max(by: { $0.since < $1.since }) else { return nil }
        dismissed.append(top)
        bump()
        return top.kind
    }

    public mutating func restoreDismissed() {
        guard !dismissed.isEmpty else { return }
        dismissed.removeAll()
        bump()
    }

    // MARK: Notifications

    @discardableResult
    public mutating func post(_ kind: NotificationKind, identity: String = "", duration: Double, now: Double) -> PostResult {
        guard filters.allows(kind, in: context) else { return .filtered }
        if let current = notification, current.kind == kind, kind.isHUD {
            // Never shorten a hold that is still in its lead-in.
            notification = ActiveNotification(kind: kind, identity: identity, until: max(current.until, now + duration))
            return .extended // same HUD: update in place, no new transition
        }
        notification = ActiveNotification(kind: kind, identity: identity, until: now + duration)
        peek = nil // notifications take priority over a running peek
        bump()
        return .shown
    }

    // MARK: Quick Peek

    /// Requests a peek. Media peeks happen only for changes not caused by the user, while the island is
    /// idle or showing a different activity, never while expanded or suppressed by full screen.
    @discardableResult
    public mutating func requestPeek(_ kind: QuickPeekKind, userInitiated: Bool, calendarTrigger: CalendarPeekTrigger = .atStart,
                                     now: Double) -> Bool {
        guard !context.expanded, !context.suppressLiveActivities, notification == nil else { return false }
        let duration: Double
        switch kind {
        case .media:
            guard peeks.mediaEnabled, peeks.mediaOnChange, !userInitiated else { return false }
            if visibleLiveKinds.subtracting([.shelf]) == [.media] { return false } // already showing Now Playing
            duration = peeks.mediaDuration
        case .calendar:
            guard peeks.calendarEnabled else { return false }
            switch calendarTrigger {
            case .beforeStart: guard peeks.calendarBeforeStart else { return false }
            case .atStart: guard peeks.calendarAtStart else { return false }
            }
            duration = peeks.calendarDuration
        }
        peek = ActivePeek(kind: kind, until: now + duration)
        bump()
        return true
    }

    public enum CalendarPeekTrigger: Sendable { case beforeStart, atStart }

    /// Ends a running peek early (a Quick Peek can be swiped away).
    @discardableResult
    public mutating func dismissPeek() -> Bool {
        guard peek != nil else { return false }
        peek = nil
        bump()
        return true
    }

    /// Whether a vertical swipe on the compact island has something to dismiss.
    public var hasDismissible: Bool {
        switch compactPresentation {
        case .peek: return true
        case .live(let kinds): return !kinds.subtracting([.lock]).isEmpty
        default: return false
        }
    }

    // MARK: Time

    /// Expires notifications and peeks; returns true when the presentation changed.
    @discardableResult
    public mutating func tick(now: Double) -> Bool {
        var changed = false
        if let n = notification, now >= n.until { notification = nil; changed = true }
        if let p = peek, now >= p.until { peek = nil; changed = true }
        if changed { bump() }
        return changed
    }

    public var nextDeadline: Double? {
        [notification?.until, peek?.until].compactMap { $0 }.min()
    }

    // MARK: Expansion

    public mutating func setExpanded(_ expanded: Bool) {
        guard context.expanded != expanded else { return }
        context.expanded = expanded
        if expanded {
            peek = nil
        } else {
            cycledChoice = nil
            shelfDropFocus = false
            restoreDismissedSilently()
        }
        bump()
    }

    /// A supported file drag entered the island, or files were dropped on it: the Shelf page shows as
    /// the drop zone whatever else is live. Dragging onto the island is an explicit choice (like a
    /// cycle), so it takes the first slot; both end when the island closes.
    public mutating func focusShelfForDrop() {
        guard shelfEnabled, !(shelfDropFocus && cycledChoice == .shelf) else { return }
        shelfDropFocus = true
        cycledChoice = .shelf
        bump()
    }

    /// Cycles the expanded content Media → Calendar → Both → (Shelf) → Media; remembered as most recent.
    public mutating func cycleExpanded() {
        var order: [ExpandedContent] = [.media, .calendar, .both]
        if timerPageEnabled { order.append(.timer) }
        if shelfEnabled { order.append(.shelf) }
        let current = expandedContent
        let index = order.firstIndex(of: current) ?? -1
        let next = order[(index + 1) % order.count]
        cycledChoice = next
        mostRecent = next
        bump()
    }

    /// Keeps the open card on `content` until it closes, like a cycle choice (the timer page
    /// stays, with its presets, when its timer is cancelled or stopped from the card).
    public mutating func keepExpanded(_ content: ExpandedContent) {
        guard context.expanded, cycledChoice != content else { return }
        cycledChoice = content
        bump()
    }

    /// Expanded content: an explicit cycle choice, else what is active, else the idle choice.
    public var expandedContent: ExpandedContent {
        if let cycledChoice { return cycledChoice }
        // A timer that is the most recently started or changed live activity. The Shelf doesn't
        // count: items arriving on it don't take the open island away from a running timer.
        if let timer = live[.timer],
           !live.values.contains(where: { ![.timer, .lock, .shelf].contains($0.kind) && $0.since > timer.since }) {
            return .timer
        }
        let media = live[.media] != nil, calendar = live[.calendar] != nil
        switch (media, calendar) {
        case (true, true): return .both
        case (true, false): return .media
        case (false, true): return .calendar
        case (false, false):
            // Shelf: while a drag is over the island or since a drop, or while its indicator is the
            // island's activity.
            if shelfEnabled, shelfDropFocus || live[.shelf] != nil { return .shelf }
            return (followMostRecent ? mostRecent : nil) ?? idleContent
        }
    }

    // MARK: Presentation

    public var compactPresentation: CompactPresentation {
        if live[.lock] != nil, !context.suppressLiveActivities { return .lock }
        if let notification { return .notification(notification.kind) }
        if let presentation = currentPeekPresentation { return presentation }
        let visible = drawnLiveKinds
        return visible.isEmpty ? .idle : .live(visible)
    }

    /// Visible live activities as drawn: the Shelf indicator shows only on its own (slot priority
    /// … > calendar > shelf).
    private var drawnLiveKinds: Set<LiveActivityKind> {
        let visible = visibleLiveKinds.subtracting([.lock])
        return visible.count > 1 ? visible.subtracting([.shelf]) : visible
    }

    private var currentPeekPresentation: CompactPresentation? {
        guard let peek, !context.expanded, !context.suppressLiveActivities else { return nil }
        return .peek(peek.kind)
    }

    // MARK: Context

    public mutating func updateContext(_ update: (inout ActivityContext) -> Void) {
        var copy = context
        update(&copy)
        guard copy != context else { return }
        context = copy
        if context.suppressLiveActivities { peek = nil }
        bump()
    }

    private func content(for kind: LiveActivityKind) -> ExpandedContent {
        if kind == .timer { return .timer }
        if kind == .shelf { return .shelf }
        return kind == .calendar ? .calendar : .media
    }

    private mutating func restoreDismissedSilently() { dismissed.removeAll() }

    private mutating func bump() { generation &+= 1 }
}
