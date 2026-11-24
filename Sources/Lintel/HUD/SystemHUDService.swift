import AppKit
import CoreGraphics
import LintelCore

/// Replaces the system volume and brightness indicators.
///
/// Keys arrive from the event tap (`MediaKeySource`), are applied through `VolumeController` /
/// `BrightnessController`, and the result is posted to the island as a Sound or Display
/// notification (`ActivityHub.post`), whose timing — collapse the current activity, grow the HUD,
/// hold, collapse, restore — belongs to the activity engine. Only key presses (and BetterDisplay's
/// OSD events) open a HUD; volume or brightness changed elsewhere only updates a HUD that is
/// already showing (AppleScript changes don't show it).
@MainActor
final class SystemHUDService {
    /// The running service, for the settings sections (one per app).
    private(set) static weak var current: SystemHUDService?

    let settings: SettingsStore
    let hub: ActivityHub
    let access: AccessibilityAccess
    let keys: EventTapMediaKeySource
    let volume: CoreAudioVolumeController
    let brightness: DisplayServicesBrightnessController
    let betterDisplay: BetterDisplayBridge
    /// Opens Lintel's settings on a HUD's section (⌥ + key).
    var openSettings: ((HUDKind) -> Void)?
    /// Set by the app delegate when this launch's signature differs from the previous launch's
    /// (`SignatureTracker`): with a HUD on and no access, the HUDs just went silent, so the
    /// Accessibility window explains why once.
    var signatureChangedAtLaunch = false

    private var observers: [NSObjectProtocol] = []
    private var enabled: [HUDKind: Bool] = [:]
    private var hudDeadline: [HUDKind: Double] = [:]
    private var brightnessPoll: Task<Void, Never>?
    private var onboarding: AccessibilityOnboardingWindow?
    private var lastFeedback: Double = -1

    // Counters.
    private(set) var lastAction = ""
    private(set) var lastActionUptime: Double = 0
    private(set) var actions = 0
    private(set) var feedbackPlayed = 0
    private(set) var externalUpdates = 0
    private(set) var lastBrightnessDisplay: CGDirectDisplayID?

    init(settings: SettingsStore, hub: ActivityHub) {
        self.settings = settings
        self.hub = hub
        access = AccessibilityAccess(settings: settings)
        keys = EventTapMediaKeySource()
        volume = CoreAudioVolumeController()
        brightness = DisplayServicesBrightnessController(settings: settings)
        betterDisplay = BetterDisplayBridge()
    }

    static var now: Double { ProcessInfo.processInfo.systemUptime }

    // MARK: Lifecycle

    func start() {
        Self.current = self
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .lintelSettingDidChange, object: nil, queue: .main) { [weak self] note in
            let key = note.userInfo?["key"] as? String
            MainActor.assumeIsolated { self?.settingDidChange(key) }
        })
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil,
                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateRouting() }
        })
        access.onChange = { [weak self] _ in self?.applyEnabledState() }
        keys.onAction = { [weak self] event, action in self?.perform(action, from: event) }
        volume.onExternalChange = { [weak self] in self?.volumeChangedElsewhere() }
        volume.onDeviceChange = { [weak self] in self?.outputDeviceChanged() }
        betterDisplay.onOSD = { [weak self] event in self?.showBetterDisplayEvent(event) }
        betterDisplay.onActiveChange = { [weak self] in self?.updateRouting() }

        applyAppearance()
        for kind in HUDKind.allCases { enabled[kind] = settings[Keys.hud(kind).enabled] }
        applyEnabledState()
        betterDisplay.start()
        if signatureChangedAtLaunch, volumeEnabled || brightnessEnabled, !access.isTrusted {
            showOnboarding(for: volumeEnabled ? .volume : .brightness)
        }
    }

    /// On quit: give the keys back to macOS and BetterDisplay its own OSD.
    func stop() {
        keys.stop()
        volume.stop()
        brightnessPoll?.cancel()
        betterDisplay.stop()
    }

    // MARK: Settings

    private func settingDidChange(_ key: String?) {
        guard let key, key == "*" || Keys.hudKeyNames.contains(key) else { return }
        applyAppearance()
        var newlyEnabled: [HUDKind] = []
        for kind in HUDKind.allCases {
            let now = settings[Keys.hud(kind).enabled]
            if now, enabled[kind] != true { newlyEnabled.append(kind) }
            enabled[kind] = now
        }
        if key == "*" || key == Keys.displayServicesCapability.name { brightness.reload() }
        applyEnabledState()
        // Switching a HUD on without access explains why and how to grant it (Accessibility is
        // requested "when enabling Display or Sound").
        if let kind = newlyEnabled.first, !access.isTrusted { showOnboarding(for: kind) }
    }

    private func applyAppearance() {
        for kind in HUDKind.allCases {
            let keys = Keys.hud(kind)
            let appearance = HUDAppearance(style: settings[keys.style], speed: settings[keys.speed],
                                           showPercentage: settings[keys.showPercentage], hideLabel: settings[keys.hideLabel])
            if kind == .volume {
                if hub.hud.volumeAppearance != appearance { hub.hud.volumeAppearance = appearance }
            } else if hub.hud.brightnessAppearance != appearance {
                hub.hud.brightnessAppearance = appearance
            }
        }
    }

    var volumeEnabled: Bool { settings[Keys.volumeHUD.enabled] }
    var brightnessEnabled: Bool { settings[Keys.brightnessHUD.enabled] }
    /// Last tap status written to the log (state changes only).
    private var loggedTapStatus: MediaKeyTapStatus?

    /// Starts or stops the tap, the volume listeners and the BetterDisplay request to match the
    /// switches and the Accessibility state.
    private func applyEnabledState() {
        let anyEnabled = volumeEnabled || brightnessEnabled
        if volumeEnabled { volume.start() } else { volume.stop() }
        if anyEnabled {
            access.refresh()
            if access.isTrusted { keys.start() } else { keys.stop(); keys.markNotAuthorized() }
            access.watch(!access.isTrusted)
        } else {
            keys.stop()
            access.watch(false)
        }
        if keys.status != loggedTapStatus {
            loggedTapStatus = keys.status
            switch keys.status {
            case .notAuthorized:
                Log.hud.error("""
                    Media-key tap not started: Accessibility isn't granted to this copy \
                    (\(Bundle.main.bundlePath, privacy: .public), \(SigningInfo.current.description, privacy: .public)); \
                    macOS keeps its own volume and brightness indicators. If Lintel is switched on in System Settings › \
                    Privacy & Security › Accessibility, that entry was recorded for another signature (toggling it keeps \
                    that signature): remove Lintel there (−) and add this copy (+).
                    """)
            case .failed: Log.hud.error("Media-key tap could not be created although Accessibility is granted")
            case .running: Log.hud.notice("Media-key tap running (volume HUD \(self.volumeEnabled), brightness HUD \(self.brightnessEnabled))")
            case .off: Log.hud.notice("Media-key tap off (both HUDs switched off)")
            }
        }
        // A15: BetterDisplay reports its changes to Lintel and hides its own OSDs while a HUD is on.
        betterDisplay.setIntegration(anyEnabled)
        updateRouting()
    }

    /// Refreshes what the tap may take.
    func updateRouting() {
        var state = MediaKeyRoutingState()
        state.volumeEnabled = volumeEnabled
        state.brightnessEnabled = brightnessEnabled
        state.volumeAdjustable = volume.canSetVolume
        state.brightnessMode = settings[Keys.brightnessTarget]
        state.displays = brightnessDisplays()
        state.betterDisplayActive = betterDisplay.isActive
        keys.updateRouting(state)
    }

    func brightnessDisplays() -> [BrightnessDisplay] {
        NSScreen.screens.map { screen in
            BrightnessDisplay(id: screen.displayID, uuid: screen.displayUUID,
                              isBuiltIn: CGDisplayIsBuiltin(screen.displayID) != 0,
                              adjustable: brightness.canAdjust(screen.displayID))
        }
    }

    // MARK: Key actions

    func perform(_ action: MediaKeyAction, from event: MediaKeyEvent) {
        actions += 1
        lastAction = "\(action)"
        lastActionUptime = Self.now
        switch action {
        case .openSettings(let kind):
            openSettings?(kind)
        case .toggleMute:
            toggleMute()
        case .adjustVolume(let up, let fine, let isRepeat):
            adjustVolume(up: up, fine: fine, isRepeat: isRepeat)
        case .adjustBrightness(let up, let fine, let isRepeat, let display):
            adjustBrightness(up: up, fine: fine, isRepeat: isRepeat, display: display)
        }
    }

    func isHUDVisible(_ kind: HUDKind) -> Bool { Self.now < (hudDeadline[kind] ?? 0) }

    private func adjustVolume(up: Bool, fine: Bool, isRepeat: Bool) {
        volume.refresh()
        let wasMuted = volume.isMuted
        let before = volume.volume
        let change = LevelStepper.step(from: before, up: up, fine: fine, hudVisible: isHUDVisible(.volume), isRepeat: isRepeat)
        // Any volume key unmutes (as macOS does).
        if wasMuted { volume.setMuted(false) }
        let changed = abs(change.value - before) > 0.0001
        if changed { volume.setVolume(change.value) }
        if let edge = change.overshoot { hub.hud.pulse(edge, for: .volume) }
        showVolumeHUD()
        playFeedback(changed: changed, unmuted: wasMuted)
    }

    private func toggleMute() {
        volume.refresh()
        let muted = !volume.isMuted
        volume.setMuted(muted)
        showVolumeHUD()
        if !muted { playFeedback(changed: false, unmuted: true) }
    }

    private func adjustBrightness(up: Bool, fine: Bool, isRepeat: Bool, display: CGDirectDisplayID) {
        guard let current = brightness.currentLevel(of: display) else { return }
        let change = LevelStepper.step(from: current, up: up, fine: fine, hudVisible: isHUDVisible(.brightness), isRepeat: isRepeat)
        if abs(change.value - current) > 0.0001 {
            brightness.setBrightness(change.value, of: display, ramp: settings[Keys.brightnessHUD.speed].brightnessRamp)
        }
        if let edge = change.overshoot { hub.hud.pulse(edge, for: .brightness) }
        lastBrightnessDisplay = display
        showBrightnessHUD(level: change.value, display: display)
        watchBrightness(display)
    }

    // MARK: Showing

    /// The output device the volume HUD names.
    private var shownDevice: OutputDeviceInfo? {
        return volume.device
    }

    func showVolumeHUD() {
        let (symbol, label) = HUDGlyphs.volume(device: shownDevice, mode: settings[Keys.volumeLabelMode],
                                               level: volume.volume, muted: volume.isMuted)
        let reading = HUDPresentationState.Reading(level: volume.volume, muted: volume.isMuted, symbol: symbol, label: label)
        show(.volume, reading: reading, screen: Self.screenUnderPointer())
    }

    func showBrightnessHUD(level: Double, display: CGDirectDisplayID) {
        let external = CGDisplayIsBuiltin(display) == 0
        let reading = HUDPresentationState.Reading(level: level, muted: false,
                                                   symbol: external ? HUDGlyphs.externalDisplay : HUDGlyphs.sun,
                                                   label: HUDKind.brightness.defaultLabel, externalTarget: external)
        show(.brightness, reading: reading, screen: Self.screen(for: display) ?? Self.screenUnderPointer())
    }

    private func show(_ kind: HUDKind, reading: HUDPresentationState.Reading, screen: String?) {
        let payload = NotificationPayload(symbol: reading.symbol, label: reading.label, level: reading.shownLevel)
        var reading = reading
        reading.posted = payload
        hub.hud.set(reading, for: kind, screen: screen)
        // Same rule as the islands: a fresh HUD holds from when it is fully shown (at most the
        // contract-then-grow lead-in); a press while it shows extends it from the press.
        let now = Self.now
        let duration = settings[Keys.duration(kind.notification)]
        let leadIn = isHUDVisible(kind) ? 0 : SwapTiming.notificationLeadIn(from: .live([.media]), to: kind.notification.asPresentation,
                                                                            expanded: false)
        hub.post(kind.notification, payload: payload)
        hudDeadline[kind] = max(hudDeadline[kind] ?? 0, now + leadIn + duration)
    }

    /// The Settings "Preview" button: shows the HUD with the current level, changing nothing.
    func preview(_ kind: HUDKind) {
        if kind == .volume {
            volume.refresh()
            showVolumeHUD()
        } else {
            let display = brightnessDisplays().first { $0.isBuiltIn && $0.adjustable }?.id ?? CGMainDisplayID()
            showBrightnessHUD(level: brightness.brightness(of: display) ?? 0.5, display: display)
        }
    }

    // MARK: Changes made elsewhere

    private func volumeChangedElsewhere() {
        externalUpdates += 1
        guard isHUDVisible(.volume), hub.hud.volume != nil else { return }
        let symbol = HUDGlyphs.volume(device: shownDevice, mode: settings[Keys.volumeLabelMode],
                                      level: volume.volume, muted: volume.isMuted).symbol
        hub.hud.update(level: volume.volume, muted: volume.isMuted, symbol: symbol, for: .volume)
    }

    private func outputDeviceChanged() {
        updateRouting()
        if isHUDVisible(.volume) { showVolumeHUD() }
    }

    /// Follows the brightness while the HUD is shown (Control Center, ambient light), skipping
    /// Lintel's own writes for 0.45 s.
    private func watchBrightness(_ display: CGDirectDisplayID) {
        brightnessPoll?.cancel()
        brightnessPoll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, !Task.isCancelled, self.isHUDVisible(.brightness) else { return }
                guard !self.brightness.isSettling, let value = self.brightness.brightness(of: display),
                      let shown = self.hub.hud.brightness, abs(shown.level - value) > 0.004 else { continue }
                self.externalUpdates += 1
                self.hub.hud.update(level: value, muted: false, symbol: shown.symbol, for: .brightness)
            }
        }
    }

    // MARK: BetterDisplay

    private func showBetterDisplayEvent(_ event: BetterDisplayProtocol.OSDEvent) {
        guard settings[Keys.hud(event.kind).enabled] else { return }
        let screen = event.displayUUID.flatMap { uuid in NSScreen.screens.first { $0.displayUUID == uuid }?.displayUUID }
            ?? event.displayID.flatMap { Self.screen(for: $0) }
        let reading: HUDPresentationState.Reading
        if event.kind == .volume {
            reading = .init(level: event.level, muted: event.muted,
                            symbol: HUDGlyphs.speaker(level: event.level, muted: event.muted), label: HUDKind.volume.defaultLabel)
        } else {
            // BetterDisplay usually reports external displays; an online built-in target keeps the sun.
            let builtIn = event.displayID.map { id in NSScreen.screens.contains { $0.displayID == id } && CGDisplayIsBuiltin(id) != 0 } ?? false
            let external = !builtIn
            reading = .init(level: event.level, muted: false, symbol: external ? HUDGlyphs.externalDisplay : HUDGlyphs.sun,
                            label: HUDKind.brightness.defaultLabel, externalTarget: external)
        }
        lastAction = "betterDisplay \(event.kind.rawValue) \(event.level)"
        show(event.kind, reading: reading, screen: screen ?? Self.screenUnderPointer())
    }

    // MARK: Feedback sound

    private static let feedbackSoundPath = "/System/Library/LoginPlugins/BezelServices.loginPlugin/Contents/Resources/volume.aiff"

    /// System preference "Play feedback when volume is changed".
    var systemFeedbackEnabled: Bool { UserDefaults.standard.integer(forKey: "com.apple.sound.beep.feedback") != 0 }

    private func playFeedback(changed: Bool, unmuted: Bool) {
        guard let delay = VolumeFeedback.delay(feedbackEnabled: systemFeedbackEnabled, muted: volume.isMuted,
                                               changed: changed, unmuted: unmuted) else { return }
        let now = Self.now
        guard now - lastFeedback >= VolumeFeedback.minimumInterval else { return }
        lastFeedback = now
        Task { @MainActor [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard let self, !self.volume.isMuted else { return }
            if let sound = NSSound(contentsOfFile: Self.feedbackSoundPath, byReference: true) {
                sound.play()
                self.feedbackPlayed += 1
            }
        }
    }

    // MARK: Onboarding

    func showOnboarding(for kind: HUDKind) {
        if onboarding == nil { onboarding = AccessibilityOnboardingWindow(access: access) }
        onboarding?.present(for: kind)
    }

    // MARK: Displays

    static func screenUnderPointer() -> String? {
        let point = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) }?.displayUUID
    }

    static func screen(for display: CGDirectDisplayID) -> String? {
        NSScreen.screens.first { $0.displayID == display }?.displayUUID
    }
}
