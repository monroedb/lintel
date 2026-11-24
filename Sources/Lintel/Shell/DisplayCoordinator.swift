import AppKit
import ColorSync
import LintelCore

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    /// Stable identifier for remembering a chosen display.
    var displayUUID: String {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue(),
              let string = CFUUIDCreateString(nil, uuid) as String? else { return "display-\(displayID)" }
        return string
    }
}

extension ScreenDescriptor {
    @MainActor
    init(screen: NSScreen, isPrimary: Bool) {
        let notch = ScreenDescriptor.notchSize(screenWidth: screen.frame.width,
                                               auxLeftWidth: screen.auxiliaryTopLeftArea?.width,
                                               auxRightWidth: screen.auxiliaryTopRightArea?.width,
                                               safeAreaTop: screen.safeAreaInsets.top)
        var menuBar = screen.frame.maxY - screen.visibleFrame.maxY
        if notch != nil { menuBar = screen.safeAreaInsets.top }
        if menuBar < 1 { menuBar = NSApp.mainMenu?.menuBarHeight ?? 0 }
        if menuBar < 1 { menuBar = NSStatusBar.system.thickness }
        self.init(uuid: screen.displayUUID, name: screen.localizedName, frame: screen.frame, notchSize: notch,
                  menuBarHeight: menuBar, isBuiltIn: CGDisplayIsBuiltin(screen.displayID) != 0, isPrimary: isPrimary)
    }
}

/// Creates, updates and removes one island per selected display, feeds them pointer and scroll
/// events, activity events, hiding rules and the backdrop luminance.
@MainActor
final class DisplayCoordinator {
    private let settings: SettingsStore
    let hub: ActivityHub
    let haptics: Haptics
    let environment: EnvironmentMonitor
    /// The panels' place among the window server's spaces.
    let spaces: IslandSpaces
    private let luminanceSampler = BackdropLuminanceSampler()
    private let lockState: LockStateSource
    private(set) var controllers: [String: IslandController] = [:]
    var menuActions: IslandMenuActions? {
        didSet { controllers.values.forEach { $0.menuActions = menuActions } }
    }
    private(set) var lastLuminance: [String: Double] = [:]
    private(set) var luminanceSource: [String: String] = [:]
    /// Menu-bar appearance (dark content behind the menu bar), the fallback backdrop signal.
    var menuBarIsDark: () -> Bool? = { nil }

    private var observers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []
    private var monitors: [Any] = []
    private var outlineTimer: Timer?

    init(settings: SettingsStore, hub: ActivityHub, haptics: Haptics,
         environment: EnvironmentMonitor = EnvironmentMonitor(), lockState: LockStateSource = SessionLockStateSource(),
         spaceProvider: WindowSpaceProvider? = nil) {
        self.settings = settings
        self.hub = hub
        self.haptics = haptics
        self.environment = environment
        self.lockState = lockState
        spaces = IslandSpaces(settings: settings, provider: spaceProvider ?? CGSWindowSpaceProvider(settings: settings))
    }

    func start() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.records = nil
                self?.rebuild()
                self?.reassertSpacesIfDisplaysChanged()
                self?.refreshOutlines(invalidate: true)
            }
        })
        observers.append(center.addObserver(forName: .lintelSettingDidChange, object: nil, queue: .main) { [weak self] note in
            let key = note.userInfo?["key"] as? String
            MainActor.assumeIsolated { self?.settingDidChange(key) }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshOutlines() }
        })
        // The desktop picture changed (posted by the system's wallpaper service).
        distributedObservers.append(DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.desktop"), object: "BackgroundChanged", queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshOutlines(invalidate: true) }
        })

        hub.onEvent = { [weak self] event in
            guard let self else { return }
            let screens = Array(self.controllers.keys)
            for (screen, controller) in self.controllers where self.hub.delivers(event, toScreen: screen, among: screens) {
                controller.activity.handle(event, hub: self.hub)
            }
        }
        hub.setLocked(lockState.isLocked)
        spaces.setLocked(lockState.isLocked)
        lockState.onChange = { [weak self] locked in
            self?.hub.setLocked(locked)
            self?.spaces.setLocked(locked)
            self?.updateEnvironmentPolling()
        }
        // Mission Control can't open while the displays sleep: its watcher pauses meanwhile.
        for (name, asleep) in [(NSWorkspace.screensDidSleepNotification, true), (NSWorkspace.screensDidWakeNotification, false)] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.screensAsleep = asleep
                    self?.updateEnvironmentPolling()
                }
            })
        }

        environment.displays = { [weak self] in self?.displayRecords() ?? [] }
        environment.onChange = { [weak self] in self?.applyVisibility() }

        rebuild()
        reassertSpacesIfDisplaysChanged()
        startPointerTracking()
        updateEnvironmentPolling()
        refreshOutlines()
        // Dynamic desktop pictures change over the day (not looked at while nobody can see the island:
        // the displays sleeping or the session locked; looked at again when they wake).
        let timer = Timer(timeInterval: 600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.hub.screensQuiet else { return }
                self.refreshOutlines(invalidate: true)
            }
        }
        timer.tolerance = 60
        RunLoop.main.add(timer, forMode: .common)
        outlineTimer = timer
    }

    /// Recomputes plans from the current screens and settings and reconciles the controllers.
    func rebuild() {
        let screens = NSScreen.screens
        let descriptors = screens.enumerated().map { ScreenDescriptor(screen: $0.element, isPrimary: $0.offset == 0) }
        let plans = DisplayPlanner.plan(
            screens: descriptors,
            selection: settings[Keys.displaySelection],
            chosenUUID: settings[Keys.chosenDisplayUUID],
            forceSimulatedNotch: settings[Keys.forceSimulatedNotch],
            tuning: CGSize(width: settings[Keys.widthTuning], height: settings[Keys.heightTuning]),
            treatAllAsNotchless: settings[Keys.debugTreatAllDisplaysAsNotchless]
        )
        let wanted = Set(plans.map(\.screenUUID))
        for (uuid, controller) in controllers where !wanted.contains(uuid) {
            spaces.release(for: controller)
            controller.close()
            controllers[uuid] = nil
        }
        for plan in plans {
            if let existing = controllers[plan.screenUUID] {
                existing.update(plan: plan)
            } else {
                let controller = IslandController(plan: plan, settings: settings, hub: hub, haptics: haptics)
                controller.menuActions = menuActions
                controller.setScreensQuiet(hub.screensQuiet)
                controllers[plan.screenUUID] = controller
                spaces.adopt(controller.panels, for: controller)
            }
        }
        applyVisibility()
        refreshOutlines()
    }

    private func settingDidChange(_ key: String?) {
        guard let key else { return }
        let all = key == "*"
        if all || Keys.placementKeyNames.contains(key) { rebuild() }
        if all || key == Keys.hideFromScreenCapture.name { controllers.values.forEach { $0.applySharingType() } }
        if all || key == Keys.debugShowIdlePill.name { controllers.values.forEach { $0.refreshDebugFlags() } }
        if all || key.hasPrefix("alerts.") || key.hasPrefix("peek.") || key.hasPrefix("island.idleActivity") {
            controllers.values.forEach { $0.applyActivitySettings() }
        }
        if all || key.hasPrefix("island.hide.") {
            updateEnvironmentPolling()
            applyVisibility()
        }
        if all || key == Keys.animateMissionControl.name { applyVisibility() }
        if all || key == Keys.contrastOutline.name { refreshOutlines() }
        if all || key == Keys.progressiveBlur.name { controllers.values.forEach { $0.updateBackdrop() } }
        if all || key == Keys.windowSpaceCapability.name { spaces.settingChanged() }
    }

    /// Quit: the panels leave the dedicated space and the space is destroyed.
    func stop() {
        spaces.stop()
    }

    /// The displays as last seen (ids and frames). Full-screen transitions also post screen-parameter
    /// changes (the menu bar and Dock hide); those leave the panels alone.
    private var displaySignature = ""

    private func reassertSpacesIfDisplaysChanged() {
        let signature = NSScreen.screens.map { "\($0.displayID):\(NSStringFromRect($0.frame))" }.joined(separator: ",")
        guard signature != displaySignature else { return }
        let first = displaySignature.isEmpty
        displaySignature = signature
        if !first { spaces.reassert() }
    }

    // MARK: Hiding rules

    private var screensAsleep = false

    private func updateEnvironmentPolling() {
        let locked = lockState.isLocked
        let quiet = locked || screensAsleep
        environment.setPolling(settings[Keys.hideInFullScreen])
        // Nothing goes full screen unseen while the displays sleep or the session is locked.
        environment.setPaused(quiet)
        // Mission Control's watcher (30 Hz, ≈ 0.5 % of an efficiency core, resting while the user
        // is away) runs only while Mission Control could open: the rule is on, the session unlocked
        // and the displays awake.
        environment.setMissionControlWatching(settings[Keys.hideInMissionControl] && !quiet)
        // What only matters on screen pauses too: the waveform and its audio tap, the timer's
        // ticks, the calendar ring.
        let wasQuiet = hub.screensQuiet
        hub.setScreensQuiet(quiet)
        for controller in controllers.values { controller.setScreensQuiet(quiet) }
        if wasQuiet, !quiet { refreshOutlines(invalidate: true) }
    }

    private func applyVisibility() {
        for controller in controllers.values {
            let id = screen(for: controller.plan)?.displayID
            let visibility = IslandVisibility.resolve(
                fullScreen: id.map { environment.fullScreenDisplays.contains($0) } ?? false,
                missionControl: environment.missionControl,
                gaming: environment.gaming,
                hideInFullScreen: settings[Keys.hideInFullScreen],
                hideInMissionControl: settings[Keys.hideInMissionControl],
                hideWhileGaming: settings[Keys.hideWhileGaming]
            )
            let byMissionControl = environment.missionControl && settings[Keys.hideInMissionControl]
            let tuck = byMissionControl && settings[Keys.animateMissionControl]
            // Hidden for gaming as well as for Mission Control: gaming wins (it lasts).
            controller.apply(visibility: visibility, tuck: tuck,
                             byMissionControl: byMissionControl && !(environment.gaming && settings[Keys.hideWhileGaming]))
        }
    }

    private func screen(for plan: IslandPlan) -> NSScreen? {
        NSScreen.screens.first { $0.displayUUID == plan.screenUUID }
    }

    /// Displays as last worked out (cleared when the screens change).
    private var records: [DisplayRecord]?

    /// Displays in CoreGraphics global coordinates for the window-list heuristics.
    private func displayRecords() -> [DisplayRecord] {
        if let records { return records }
        let made = NSScreen.screens.enumerated().map { index, screen in
            let descriptor = ScreenDescriptor(screen: screen, isPrimary: index == 0)
            return DisplayRecord(id: screen.displayID, bounds: CGDisplayBounds(screen.displayID),
                                 menuBarHeight: descriptor.menuBarHeight)
        }
        records = made
        return made
    }

    // MARK: Contrast outline

    func refreshOutlines(invalidate: Bool = false) {
        if invalidate { luminanceSampler.invalidate() }
        for (uuid, controller) in controllers {
            var source = "none"
            var value = screen(for: controller.plan).flatMap { luminanceSampler.luminance(for: $0) }
            if value != nil {
                source = "picture"
            } else if let dark = menuBarIsDark() {
                // Coarse two-level estimate from the adaptive menu bar.
                value = dark ? 0.1 : 0.6
                source = "menuBar"
            }
            lastLuminance[uuid] = value
            luminanceSource[uuid] = source
            controller.applyOutline(luminance: value)
        }
    }

    // MARK: Pointer and scroll tracking

    /// Global monitors see events going to other apps; local monitors cover Lintel's own windows.
    /// No permission is needed for mouse-movement or scroll monitoring.
    private func startPointerTracking() {
        let moves: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: moves, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.pointerMoved() }
        }) { monitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: moves, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.pointerMoved() }
            return event
        }) { monitors.append(monitor) }
        // Trackpad swipes over the island.
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel, handler: { [weak self] event in
            MainActor.assumeIsolated { _ = self?.scrolled(event) }
        }) { monitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: { [weak self] event in
            let consumed = MainActor.assumeIsolated { self?.scrolled(event) ?? false }
            return consumed ? nil : event
        }) { monitors.append(monitor) }
    }

    private func pointerMoved() {
        let point = NSEvent.mouseLocation
        for controller in controllers.values { controller.pointerMoved(to: point) }
    }

    private func scrolled(_ event: NSEvent) -> Bool {
        pointerMoved()
        guard let controller = controllers.values.first(where: { $0.pointerInside }) else { return false }
        return controller.handleScroll(event)
    }
}
