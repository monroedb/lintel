import AppKit
import LintelCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let settings = SettingsStore()
    let loginItems = LoginItemService()
    let hub = ActivityHub()
    private var coordinator: DisplayCoordinator?
    private var statusItem: StatusItemController?
    private var settingsWindow: SettingsWindowController?
    private var calendar: CalendarFeature?
    /// Battery, audio-device and Focus alerts.
    private var systemAlerts: SystemAlertController?
    private var nowPlaying: NowPlayingController?
    private var hudService: SystemHUDService?
    /// Timer.
    private var timer: TimerFeature?
    /// File shelf.
    private var shelf: ShelfFeature?
    /// SIGTERM handler (see applicationDidFinishLaunching).
    private var terminationSignal: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Key equivalents (⌘Q, ⌘W, ⌘,, editing) while Settings or About is in front.
        MainMenu.install(showAbout: { [weak self] in self?.showAbout() },
                         showSettings: { [weak self] in self?.showSettings() })
        // `kill`/`pkill` (SIGTERM) quits like ⌘Q, so the willTerminate observers run and helper
        // processes (the media adapter) stop with Lintel instead of being left behind.
        signal(SIGTERM, SIG_IGN)
        let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        termination.setEventHandler { MainActor.assumeIsolated { NSApp.terminate(nil) } }
        termination.resume()
        terminationSignal = termination
        let info = Bundle.main.infoDictionary
        Log.app.notice("""
            Lintel \(info?["CFBundleShortVersionString"] as? String ?? "?", privacy: .public) \
            (\(info?["CFBundleVersion"] as? String ?? "?", privacy: .public)) at \(Bundle.main.bundlePath, privacy: .public): \
            \(SigningInfo.current.description, privacy: .public); Accessibility trusted: \(AccessibilityAccess.isTrusted)
            """)
        // Before the HUD service reads it: did the signature change since the last launch?
        let signature = SignatureTracker.recordLaunch(settings: settings)

        let statusItem = StatusItemController(
            settings: settings,
            openSettings: { [weak self] in self?.showSettings() },
            showAbout: { [weak self] in self?.showAbout() }
        )
        self.statusItem = statusItem
        let calendar = CalendarFeature(settings: settings, hub: hub)
        self.calendar = calendar
        let shelf = ShelfFeature(settings: settings, hub: hub) // loads the index before the islands are seeded
        self.shelf = shelf

        let coordinator = DisplayCoordinator(settings: settings, hub: hub, haptics: Haptics(settings: settings))
        coordinator.menuActions = IslandMenuActions(openSettings: { [weak self] in self?.showSettings() },
                                                    quit: { NSApp.terminate(nil) },
                                                    regionItems: { [weak calendar] island, event in
                                                        ShelfMenu.joined(calendar?.menuItems(controller: island, event: event) ?? [],
                                                                         ShelfMenu.items(controller: island, event: event))
                                                    })
        coordinator.menuBarIsDark = { [weak statusItem] in statusItem?.menuBarIsDark }
        statusItem.onMenuBarAppearanceChange = { [weak coordinator] in coordinator?.refreshOutlines() }
        coordinator.start()
        self.coordinator = coordinator
        calendar.start()
        let timer = TimerFeature(settings: settings, hub: hub)
        timer.start(coordinator: coordinator)
        self.timer = timer
        shelf.start(coordinator: coordinator)
        let systemAlerts = SystemAlertController(settings: settings, hub: hub)
        systemAlerts.start()
        self.systemAlerts = systemAlerts
        let nowPlaying = NowPlayingController(hub: hub, settings: settings)
        nowPlaying.start()
        self.nowPlaying = nowPlaying
        // Volume and brightness HUDs.
        let huds = SystemHUDService(settings: settings, hub: hub)
        if case .changed = signature { huds.signatureChangedAtLaunch = true }
        huds.openSettings = { [weak self] kind in
            SettingsNavigation.shared.requested = SettingsNavigation.section(for: kind)
            self?.showSettings()
        }
        huds.start()
        hudService = huds
    }

    func applicationWillTerminate(_ notification: Notification) {
        hudService?.stop()
        coordinator?.stop()
        shelf?.saveNow()
    }

    /// Re-opening the running app (Finder, Spotlight, `open`) shows Settings.
    /// With the menu-bar item hidden, this and the
    /// island's right-click menu are the ways back to Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// `lintel://timer…` links; a link that launches Lintel waits until the timer is restored.
    func application(_ application: NSApplication, open urls: [URL]) { TimerFeature.open(urls) }

    func showSettings() {
        settingsRelease?.cancel()
        settingsRelease = nil
        if settingsWindow == nil {
            let controller = SettingsWindowController(settings: settings, loginItems: loginItems)
            controller.onClose = { [weak self] in self?.settingsClosed() }
            settingsWindow = controller
        }
        settingsWindow?.present()
    }

    /// A closed Settings window kept its whole view hierarchy: opening Settings once added ≈ 35 MB
    /// for as long as Lintel ran. It's released a minute after
    /// it closes; opened again before then it's the same window, and a new one opens on the same
    /// page at the same place.
    private var settingsRelease: Task<Void, Never>?
    static let settingsReleaseDelay: Double = 60

    private func settingsClosed() {
        settingsRelease?.cancel()
        settingsRelease = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.settingsReleaseDelay))
            guard !Task.isCancelled, let self, self.settingsWindow?.isVisible == false else { return }
            self.settingsWindow = nil
            self.settingsRelease = nil
            // The window's objects are freed, but malloc keeps their pages: hand them back, once the
            // views' deferred teardown has run.
            try? await Task.sleep(for: .seconds(2))
            _ = malloc_zone_pressure_relief(nil, 0)
        }
    }

    func showAbout() {
        NSApp.activate()
        let credits = NSAttributedString(
            string: "A notch companion for macOS.\n\n" + ThirdPartyNotices.aboutLine,
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
        )
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }
}
