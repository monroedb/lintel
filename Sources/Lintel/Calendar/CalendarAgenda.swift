import Foundation
import LintelCore
import Observation

/// The calendar's live state: fetched events, the open card's day lists, the month grid and the
/// island's live event. Fetches are event-driven, debounced and rate-limited;
/// a single timer fires at the next relevant change instead of polling.
@MainActor
@Observable
final class CalendarAgenda {
    // MARK: State read by the views
    private(set) var access: CalendarAccess = .notDetermined
    private(set) var calendars: [CalendarListEntry] = []
    private(set) var today = AgendaDay(day: Date(), events: [], empty: .nothingPlanned)
    private(set) var tomorrow = AgendaDay(day: Date(), events: [], empty: .nothingPlanned)
    private(set) var month: MonthGrid?
    private(set) var busyDays: Set<Date> = []
    private(set) var live: LiveEventState?
    private(set) var dismissed: Set<String> = []
    /// Island-eligible and card-eligible events, filtered and cached separately.
    private(set) var islandEvents: [CalendarEventRecord] = []
    private(set) var cardEvents: [CalendarEventRecord] = []
    /// Card under the pointer (hover highlight).
    var hoveredEventID: String?

    // MARK: Bookkeeping (not observed)
    @ObservationIgnored let settings: SettingsStore
    @ObservationIgnored let hub: ActivityHub
    @ObservationIgnored private(set) var source: CalendarEventSource
    @ObservationIgnored private(set) var allEvents: [CalendarEventRecord] = []
    @ObservationIgnored private(set) var fetchCount = 0
    @ObservationIgnored private(set) var lastFetch: Date?
    @ObservationIgnored private(set) var nextRecompute: Date?
    /// Event card frames in the island window (top-left origin), for context-menu hit tests.
    @ObservationIgnored var cardFrames: [String: CGRect] = [:]
    /// Events changed (time to leave follows).
    @ObservationIgnored var onEventsChanged: (() -> Void)?
    /// An island event started (event sound).
    @ObservationIgnored var onEventStarted: ((CalendarEventRecord) -> Void)?
    @ObservationIgnored private(set) var log: [String] = []
    @ObservationIgnored private var limiter = CalendarFetchLimiter()
    @ObservationIgnored private var fetchTask: Task<Void, Never>?
    @ObservationIgnored private var fetchGeneration = 0
    @ObservationIgnored private var recomputeTask: Task<Void, Never>?
    @ObservationIgnored private var publishTask: Task<Void, Never>?
    @ObservationIgnored private var lastEvaluation: Date?
    @ObservationIgnored private var publishedIdentity: String?
    @ObservationIgnored private var requestingAccess = false
    /// The live activity appears about 4 s after launch.
    @ObservationIgnored private let publishAllowedAt: Date

    init(settings: SettingsStore, hub: ActivityHub, source: CalendarEventSource, launchDate: Date = Date()) {
        self.settings = settings
        self.hub = hub
        self.source = source
        publishAllowedAt = launchDate.addingTimeInterval(4)
    }

    var isEnabled: Bool { settings[Keys.calendarEnabled] }
    var isActive: Bool { isEnabled && access.canRead }

    func event(id: String) -> CalendarEventRecord? { allEvents.first { $0.id == id } }

    // MARK: Lifecycle

    func start() {
        source.onChange = { [weak self] in self?.requestFetch() }
        refreshAccess()
        if isEnabled { activate() }
        let delay = max(0, publishAllowedAt.timeIntervalSinceNow)
        publishTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay), tolerance: .milliseconds(50))
            guard !Task.isCancelled else { return }
            self?.publish()
        }
    }

    /// Called when the master switch turns on (or at launch when it is on).
    func activate() {
        refreshAccess()
        if access == .notDetermined {
            if !settings[Keys.calendarAccessPrompted] { requestAccess() }
            return
        }
        requestFetch(immediately: true)
    }

    func deactivate() {
        fetchTask?.cancel()
        recomputeTask?.cancel()
        nextRecompute = nil
        allEvents = []
        recompute()
    }

    func refreshAccess() {
        access = source.access
        calendars = access.canRead ? source.calendars() : []
    }

    /// Asks for full calendar access (system prompt the first time).
    func requestAccess() {
        guard !requestingAccess else { return }
        requestingAccess = true
        settings[Keys.calendarAccessPrompted] = true
        Task { [weak self] in
            guard let self else { return }
            self.access = await self.source.requestAccess()
            self.requestingAccess = false
            self.refreshAccess()
            self.note("access \(self.access.rawValue)")
            if self.access.canRead { self.requestFetch(immediately: true) } else { self.deactivate() }
        }
    }

    // MARK: Fetching

    /// Debounced, at most one fetch every 1.25 s.
    func requestFetch(immediately: Bool = false) {
        guard isEnabled, access.canRead else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let earliest = (limiter.lastFetch ?? -.infinity) + limiter.minimumInterval
        let runAt = immediately ? max(now, earliest) : limiter.runTime(requestedAt: now)
        fetchTask?.cancel()
        fetchTask = Task { [weak self] in
            if runAt > now { try? await Task.sleep(for: .seconds(runAt - now)) }
            guard !Task.isCancelled, let self else { return }
            await self.fetch()
        }
    }

    private func fetch() async {
        limiter.didFetch(at: ProcessInfo.processInfo.systemUptime)
        fetchGeneration += 1
        let generation = fetchGeneration
        let range = fetchRange(now: Date())
        calendars = source.calendars()
        let events = await source.events(from: range.start, to: range.end)
        guard generation == fetchGeneration, isEnabled else { return }
        allEvents = events
        fetchCount += 1
        lastFetch = Date()
        recompute()
    }

    /// Today and tomorrow, plus the month grid when its indicators are shown.
    private func fetchRange(now: Date) -> DateInterval {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: now)
        var end = calendar.date(byAdding: .day, value: 2, to: start) ?? start.addingTimeInterval(2 * 86_400)
        var lower = start
        if settings[Keys.calendarMonthView], settings[Keys.calendarEventDots] {
            let grid = MonthGrid.make(containing: now, today: now, calendar: calendar).interval
            lower = min(lower, grid.start)
            end = max(end, grid.end)
        }
        return DateInterval(start: lower, end: end)
    }

    // MARK: Derived state

    /// Rebuilds the lists and the live event from the fetched events; plays sounds and requests
    /// Quick Peeks for countdowns that began and events that started since the last evaluation.
    func recompute(now: Date = Date()) {
        let calendar = Calendar.current
        let filter = CalendarEventFilter(excluded: settings[Keys.calendarExclusions].ids, modes: settings[Keys.calendarModes])
        let active = isActive
        let island = active ? allEvents.filter(filter.includesInIsland) : []
        let card = active ? allEvents.filter(filter.includesInCard) : []
        islandEvents = island
        cardEvents = card
        let todayList = AgendaBuilder.day(now, events: card, now: now, calendar: calendar)
        if todayList != today { today = todayList }
        let next = calendar.date(byAdding: .day, value: 1, to: now) ?? now.addingTimeInterval(86_400)
        let tomorrowList = AgendaBuilder.day(next, events: card, now: now, calendar: calendar)
        if tomorrowList != tomorrow { tomorrow = tomorrowList }
        if settings[Keys.calendarMonthView] {
            let grid = MonthGrid.make(containing: now, today: now, calendar: calendar)
            if grid != month { month = grid }
            let busy = settings[Keys.calendarEventDots] ? AgendaBuilder.busyDays(events: card, in: grid.interval, calendar: calendar) : []
            if busy != busyDays { busyDays = busy }
        } else {
            if month != nil { month = nil }
            if !busyDays.isEmpty { busyDays = [] }
        }
        let stillRelevant = dismissed.filter { id in allEvents.contains { $0.id == id && $0.end > now } }
        if stillRelevant != dismissed { dismissed = stillRelevant }

        let options = LiveEventOptions(leadTime: settings[Keys.calendarLeadMinutes] * 60,
                                       hideDuringEvents: settings[Keys.calendarHideDuringEvents])
        let newLive = LiveEventPlanner.state(events: island, now: now, options: options, dismissed: dismissed)
        if newLive != live { live = newLive }
        publish()

        if let last = lastEvaluation, active {
            for crossing in LiveEventPlanner.crossings(events: island, from: last, to: now, options: options, dismissed: dismissed) {
                handle(crossing)
            }
        }
        lastEvaluation = active ? now : nil
        onEventsChanged?()
        scheduleRecompute(now: now, island: island, card: card, options: options)
    }

    private func handle(_ crossing: LiveEventCrossing) {
        switch crossing {
        case .countdownBegan(let event):
            note("countdown \(event.id)")
            if live?.event.id == event.id { hub.peek(.calendar, userInitiated: false, trigger: .beforeStart) }
        case .started(let event):
            note("started \(event.id)")
            onEventStarted?(event)
            if live?.event.id == event.id, live?.phase == .ongoing { hub.peek(.calendar, userInitiated: false, trigger: .atStart) }
        }
    }

    private func scheduleRecompute(now: Date, island: [CalendarEventRecord], card: [CalendarEventRecord], options: LiveEventOptions) {
        recomputeTask?.cancel()
        nextRecompute = nil
        guard isActive else { return }
        let calendar = Calendar.current
        let candidates = [LiveEventPlanner.nextChange(events: island, now: now, options: options, dismissed: dismissed),
                          AgendaBuilder.nextListChange(events: card, now: now, calendar: calendar)]
        guard let next = candidates.compactMap({ $0 }).min() else { return }
        nextRecompute = next
        let day = calendar.startOfDay(for: now)
        recomputeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0.05, next.timeIntervalSinceNow + 0.05)), tolerance: .milliseconds(50))
            guard !Task.isCancelled, let self else { return }
            if Calendar.current.startOfDay(for: Date()) != day {
                self.requestFetch(immediately: true) // day rollover: new fetch range
            } else {
                self.recompute()
            }
        }
    }

    /// Hands the live event to the island (after the launch delay).
    private func publish() {
        guard Date() >= publishAllowedAt else { return }
        guard isActive, let live else {
            if publishedIdentity != nil {
                publishedIdentity = nil
                note("publish none")
                hub.setCalendar(nil)
            }
            return
        }
        let event = live.event
        let tint = settings[Keys.calendarTintIcon] ? event.color.readableOnBlack() : nil
        let snapshot = CalendarSnapshot(identity: event.id, title: event.title.isEmpty ? "Event" : event.title,
                                        start: event.start, end: event.end, tint: tint)
        if publishedIdentity != event.id { note("publish \(event.id)") }
        publishedIdentity = event.id
        if hub.calendar != snapshot { hub.setCalendar(snapshot) }
    }

    // MARK: Dismissal ("Dismiss Event", restorable; kept in memory only)

    func dismiss(_ id: String) {
        dismissed.insert(id)
        note("dismiss \(id)")
        recompute()
    }

    func restore(_ id: String? = nil) {
        if let id { dismissed.remove(id) } else { dismissed.removeAll() }
        note("restore \(id ?? "all")")
        recompute()
    }

    /// Whether the event can be hidden from (or brought back to) the island.
    func canHideFromIsland(_ event: CalendarEventRecord, now: Date = Date()) -> Bool {
        !event.isAllDay && event.end > now && islandEvents.contains { $0.id == event.id }
    }

    private func note(_ line: String) {
        log.append(String(format: "%.3f ", ProcessInfo.processInfo.systemUptime) + line)
        if log.count > 40 { log.removeFirst(log.count - 40) }
    }
}
