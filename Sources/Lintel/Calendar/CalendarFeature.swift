import AppKit
import CoreLocation
import Foundation
import LintelCore
import Observation

/// Calendar, weather and time to leave. Owns the agenda and its helpers, follows the
/// settings and system events, runs the permission flows and the event actions. One per app;
/// views reach it through `shared`.
@MainActor
@Observable
final class CalendarFeature {
    static var shared: CalendarFeature?

    let agenda: CalendarAgenda
    let weather: WeatherStore
    private(set) var locationAccess: LocationAccess = .notDetermined
    /// Calendar apps installed on this Mac (Calendar is always there).
    private(set) var installedApps: [CalendarAppChoice] = [.calendar]

    @ObservationIgnored let settings: SettingsStore
    @ObservationIgnored let hub: ActivityHub
    @ObservationIgnored let location: CoreLocationProvider
    @ObservationIgnored let leave: TimeToLeaveMonitor
    @ObservationIgnored let chime = HourlyChimeTimer()
    @ObservationIgnored let tones = TonePlayer()
    @ObservationIgnored let actions = CalendarActionRunner()
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init(settings: SettingsStore, hub: ActivityHub, launchDate: Date = Date()) {
        self.settings = settings
        self.hub = hub
        agenda = CalendarAgenda(settings: settings, hub: hub, source: Self.makeSource(), launchDate: launchDate)
        location = CoreLocationProvider()
        weather = WeatherStore(settings: settings, location: location)
        leave = TimeToLeaveMonitor(settings: settings, hub: hub, location: location, estimator: MapKitTravelEstimator(), tones: tones)
        Self.shared = self
    }

    private static func makeSource() -> CalendarEventSource {
        return EventKitCalendarSource()
    }

    func start() {
        refreshInstalledApps()
        location.onAccessChange = { [weak self] in self?.locationAccessChanged() }
        agenda.onEventStarted = { [weak self] _ in
            guard let self, self.settings[Keys.calendarStartSound] else { return }
            self.tones.play(.eventStart)
        }
        agenda.onEventsChanged = { [weak self] in self?.leave.update() }
        leave.events = { [weak self] in
            guard let self else { return [] }
            let filter = CalendarEventFilter(excluded: self.settings[Keys.calendarExclusions].ids, modes: self.settings[Keys.calendarModes])
            return self.agenda.isActive ? self.agenda.allEvents.filter(filter.includesAnywhere) : []
        }
        chime.isEnabled = { [weak self] in
            guard let self else { return false }
            return self.settings[Keys.calendarEnabled] && self.settings[Keys.calendarHourlyChime]
        }
        chime.onChime = { [weak self] in self?.tones.play(.hourlyChime) }
        observeSystem()
        followScreens()
        agenda.start()
        locationAccessChanged()
        promptForLocationIfNeeded()
        weather.updateSchedule()
        chime.reschedule()
    }

    // MARK: Settings

    private func settingDidChange(_ key: String) {
        let all = key == "*"
        guard all || Keys.calendarKeyPrefixes.contains(where: key.hasPrefix) || key == Keys.duration(.timeToLeave).name else { return }
        if key == Keys.weatherCache.name || key == Keys.locationPendingTarget.name || key.hasSuffix(".prompted") { return }
        if all || key == Keys.calendarEnabled.name {
            if settings[Keys.calendarEnabled] { agenda.activate() } else { agenda.deactivate() }
            promptForLocationIfNeeded()
        } else if key == Keys.calendarMonthView.name || key == Keys.calendarEventDots.name {
            agenda.recompute()
            agenda.requestFetch(immediately: true) // the fetch range follows the month grid
        } else {
            agenda.recompute()
        }
        weather.updateSchedule()
        chime.reschedule()
        leave.update()
    }

    /// The weather's half-hourly refresh waits while the displays sleep or the session is locked.
    private func followScreens() {
        let quiet = withObservationTracking { hub.screensQuiet } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.followScreens() }
        }
        weather.paused = quiet
    }

    // MARK: System events (fetch on store change, activation, locale,
    // clock or time-zone change and wake; plus the day changing)

    private func observeSystem() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .lintelSettingDidChange, object: nil, queue: .main) { [weak self] note in
            let key = note.userInfo?["key"] as? String ?? "*"
            MainActor.assumeIsolated { self?.settingDidChange(key) }
        })
        let refetch: [Notification.Name] = [
            NSApplication.didBecomeActiveNotification, NSLocale.currentLocaleDidChangeNotification,
            .NSSystemClockDidChange, .NSSystemTimeZoneDidChange, .NSCalendarDayChanged,
        ]
        for name in refetch {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.systemChanged() }
            })
        }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil,
                                                                          queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.systemChanged()
                self?.weather.refreshIfNeeded()
            }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                                          object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshInstalledAppsIfNeeded() }
        })
    }

    private func systemChanged() {
        agenda.refreshAccess()
        agenda.requestFetch()
        chime.reschedule()
        leave.update()
    }

    // MARK: Calendar access

    func requestCalendarAccess() { agenda.requestAccess() }

    func openPrivacySettings(location: Bool) {
        let pane = location ? "Privacy_LocationServices" : "Privacy_Calendars"
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Location (asked for only when a toggle that needs it is switched on)

    static func key(for target: LocationPermissionTarget) -> SettingKey<Bool>? {
        switch target {
        case .weatherOnFreeDay: return Keys.calendarWeatherOnFreeDay
        case .timeToLeave: return Keys.timeToLeaveEnabled
        case .weatherWidget: return nil // lock-screen widgets aren't available
        }
    }

    /// Switches a location-dependent toggle. Without a decision yet, the system is asked first and
    /// the toggle turns on once access is granted (`pendingLocationPermissionTarget`).
    func setLocationFeature(_ target: LocationPermissionTarget, on: Bool) {
        guard let key = Self.key(for: target) else { return }
        guard on else {
            settings[key] = false
            return
        }
        if location.access == .notDetermined {
            settings[Keys.locationPendingTarget] = target
            settings[Keys.locationAccessPrompted] = true
            location.requestAccess()
        } else {
            settings[key] = true // without access the weather stays hidden; Settings offers a way to fix it
        }
    }

    /// A location toggle that is already on (e.g. restored settings) but was never asked about.
    private func promptForLocationIfNeeded() {
        guard settings[Keys.calendarEnabled], location.access == .notDetermined, !settings[Keys.locationAccessPrompted],
              settings[Keys.calendarWeatherOnFreeDay] || settings[Keys.timeToLeaveEnabled] else { return }
        settings[Keys.locationAccessPrompted] = true
        location.requestAccess()
    }

    private func locationAccessChanged() {
        locationAccess = location.access
        weather.locationAuthorized = locationAccess.isAuthorized
        if let pending = settings[Keys.locationPendingTarget], locationAccess != .notDetermined {
            settings[Keys.locationPendingTarget] = nil
            if locationAccess.isAuthorized, let key = Self.key(for: pending) { settings[key] = true }
        }
        weather.updateSchedule()
        leave.update()
    }

    // MARK: Event actions

    /// The app events open in: the chosen one if installed, else Calendar.
    var calendarApp: CalendarAppChoice {
        let chosen = settings[Keys.calendarApp]
        return installedApps.contains(chosen) ? chosen : .calendar
    }

    /// Click on an event: join its meeting, or show it; ⌥-click does the other.
    func performPrimary(on event: CalendarEventRecord, alternate: Bool) {
        if let link = event.meeting, !alternate {
            actions.join(link)
        } else {
            actions.show(event, in: calendarApp)
        }
    }

    func openToday() { actions.showDay(Date(), in: calendarApp) }

    /// Context-menu items for one event.
    func menuItems(for event: CalendarEventRecord) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        let title = event.title.isEmpty ? "Event" : event.title
        let header = NSMenuItem(title: title.count > 42 ? String(title.prefix(41)) + "…" : title, action: nil, keyEquivalent: "")
        header.isEnabled = false
        items.append(header)
        if let link = event.meeting {
            items.append(ClosureMenuItem(title: "Join on \(link.service.title)", key: "") { [weak self] in self?.actions.join(link) })
        }
        let app = calendarApp
        items.append(ClosureMenuItem(title: "Show in \(app.title)", key: "") { [weak self] in self?.actions.show(event, in: app) })
        if agenda.canHideFromIsland(event) {
            if agenda.dismissed.contains(event.id) {
                items.append(ClosureMenuItem(title: "Show in Island Again", key: "") { [weak self] in self?.agenda.restore(event.id) })
            } else {
                items.append(ClosureMenuItem(title: "Hide from Island", key: "") { [weak self] in self?.agenda.dismiss(event.id) })
            }
        }
        return items
    }

    /// Items for a right-click on an island: the event under the pointer (or the live event) and a
    /// way back for hidden events. The click hasn't expanded the island yet when this runs.
    func menuItems(controller: IslandController, event: NSEvent) -> [NSMenuItem] {
        guard agenda.isActive else { return [] }
        let model = controller.model
        let height = event.window?.frame.height ?? IslandMetrics.canvasSize.height
        let point = CGPoint(x: event.locationInWindow.x, y: height - event.locationInWindow.y)
        var target: CalendarEventRecord?
        switch model.phase {
        case .expanded:
            if model.expandedContent == .calendar || model.expandedContent == .both {
                if let id = agenda.cardFrames.first(where: { $0.value.contains(point) })?.key {
                    target = agenda.event(id: id)
                } else if model.expandedContent == .calendar || point.x >= IslandMetrics.canvasSize.width / 2 {
                    target = agenda.live?.event
                }
            }
        case .idle, .elevated:
            switch model.displayed {
            case .live(let kinds) where kinds.contains(.calendar): target = agenda.live?.event
            case .peek(.calendar): target = agenda.live?.event
            default: break
            }
        }
        var items = target.map(menuItems(for:)) ?? []
        if !agenda.dismissed.isEmpty {
            items.append(ClosureMenuItem(title: "Show Hidden Events", key: "") { [weak self] in self?.agenda.restore() })
        }
        return items
    }

    // MARK: Installed apps

    @ObservationIgnored private var appsCheckedAt: Date?

    private func refreshInstalledApps() {
        appsCheckedAt = Date()
        let found = CalendarAppChoice.allCases.filter { $0 == .calendar || CalendarActionRunner.installedApp($0.bundleIDs) != nil }
        if found != installedApps { installedApps = found }
    }

    private func refreshInstalledAppsIfNeeded() {
        if let appsCheckedAt, Date().timeIntervalSince(appsCheckedAt) < 300 { return }
        refreshInstalledApps()
    }
}

/// Opens meeting links, events and days in apps.
@MainActor
final class CalendarActionRunner {
    private(set) var log: [String] = []

    static func installedApp(_ bundleIDs: [String]) -> URL? {
        bundleIDs.lazy.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.first
    }

    /// Native app first (its own link, or the web link handed to it), else the browser.
    func join(_ link: MeetingLink) {
        if let app = Self.installedApp(link.service.appBundleIDs) {
            if let appURL = link.appURL { open(appURL, kind: "join") } else { open(link.webURL, with: app, kind: "join") }
        } else {
            open(link.webURL, kind: "join")
        }
    }

    func show(_ event: CalendarEventRecord, in choice: CalendarAppChoice) {
        let app = Self.installedApp(choice.bundleIDs)
        if let url = choice.eventURL(externalID: event.externalID, start: event.start) ?? choice.dayURL(for: event.start) {
            open(url, kind: "show")
        } else if let app {
            launch(app)
        }
    }

    func showDay(_ date: Date, in choice: CalendarAppChoice) {
        if let url = choice.dayURL(for: date) {
            open(url, kind: "day")
        } else if let app = Self.installedApp(choice.bundleIDs) {
            launch(app)
        }
    }

    private func open(_ url: URL, with app: URL? = nil, kind: String) {
        record("\(kind) \(url.absoluteString)" + (app.map { " in \($0.deletingPathExtension().lastPathComponent)" } ?? ""))
        if let app {
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    private func launch(_ app: URL) {
        record("launch \(app.deletingPathExtension().lastPathComponent)")
        NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
    }

    private func record(_ line: String) {
        log.append(line)
        if log.count > 20 { log.removeFirst(log.count - 20) }
    }
}
