import AppKit
import LintelCore
import Observation

/// What Settings shows about the alert sources (live).
@MainActor
@Observable
final class SystemAlertStatus {
    var power: PowerSnapshot = .noBattery()
    var bluetoothAccess: BluetoothAccess = .notDetermined
    var deviceLevels = ""
    var connectedDevices = 0
    var focusAccess: FocusAccess = .notDetermined
    var focusDatabase: FocusDatabaseStatus = .off
    var focusDetection: FocusDetection = .unavailable
    var focusNeedsDatabase = false
    var focusModes: [FocusModeDescriptor] = []
    var focusState: FocusState?
}

/// Battery, audio-device and Focus alerts. Reads the sources (`PowerSource`,
/// `AudioDeviceBattery`, `FocusStatusProvider`), lets the LintelCore monitors decide, posts the
/// alerts to the hub, keeps the Focus context and the waveform replacement up to date, and plays the
/// alert sounds.
@MainActor
final class SystemAlertController {
    /// The running controller, for the Settings rows (status, previews, access buttons).
    static weak var current: SystemAlertController?

    let settings: SettingsStore
    let hub: ActivityHub
    let status = SystemAlertStatus()
    let sounds = AlertSoundPlayer()
    private let power: PowerSource
    private let deviceSource: AudioDeviceConnectionSource
    private let deviceBattery: AudioDeviceBattery
    private let focus: FocusStatusProvider

    private var batteryMonitor = BatteryAlertMonitor()
    private var deviceMonitor = DeviceAlertMonitor()
    private var focusMonitor = FocusAlertMonitor()

    private var batteryTick: Task<Void, Never>?
    private var focusTick: Task<Void, Never>?
    private var deviceSettle: Task<Void, Never>?
    private var deviceBatteryTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    /// Recent decisions, newest last.
    private(set) var log: [String] = []

    /// Battery properties appear a moment after a device connects.
    static let deviceSettleDelay: Double = 1.0
    /// Levels have no change notification; poll while a warning could fire.
    static let deviceBatteryPoll: Double = 60

    static var now: Double { ProcessInfo.processInfo.systemUptime }

    init(settings: SettingsStore, hub: ActivityHub,
         power: PowerSource = IOKitPowerSource(),
         deviceSource: AudioDeviceConnectionSource = CoreAudioDeviceSource(),
         deviceBattery: AudioDeviceBattery = BluetoothDeviceBattery(),
         focus: FocusStatusProvider = SystemFocusStatusProvider()) {
        self.settings = settings
        self.hub = hub
        self.power = power
        self.deviceSource = deviceSource
        self.deviceBattery = deviceBattery
        self.focus = focus
    }

    func start() {
        Self.current = self
        applySettings()

        power.onChange = { [weak self] snapshot in self?.realPowerChanged(snapshot) }
        power.start()
        feedPower(power.snapshot) // baseline: no alert

        deviceSource.onChange = { [weak self] in self?.realDevicesChanged() }
        deviceBattery.onAccessChange = { [weak self] in self?.bluetoothAccessChanged() }
        deviceSource.start()
        feedDevices(withBatteries(deviceSource.devices)) // baseline: no alert

        focus.onChange = { [weak self] in self?.realFocusChanged() }
        focus.start()
        realFocusChanged() // baseline: context only

        observers.append(NotificationCenter.default.addObserver(forName: .lintelSettingDidChange, object: nil,
                                                                queue: .main) { [weak self] note in
            let key = note.userInfo?["key"] as? String ?? "*"
            MainActor.assumeIsolated { self?.settingChanged(key) }
        })
        refreshStatus()
    }

    // MARK: Settings

    private func settingChanged(_ key: String) {
        guard key == "*" || key.hasPrefix("alerts.") || key.hasPrefix("capability.") else { return }
        applySettings()
    }

    private func applySettings() {
        var battery = BatteryAlertConfig()
        battery.enabled = settings[Keys.batteryAlerts]
        battery.lowPowerAlert = settings[Keys.batteryLowPowerAlert]
        battery.lowWarning = settings[Keys.batteryLowWarning]
        battery.lowThreshold = settings[Keys.batteryLowThreshold]
        batteryMonitor.setConfig(battery)

        var devices = DeviceAlertConfig()
        devices.enabled = settings[Keys.deviceAlerts]
        devices.lowWarning = settings[Keys.deviceLowWarning]
        devices.lowThreshold = settings[Keys.deviceLowThreshold]
        deviceMonitor.setConfig(devices)
        (deviceBattery as? BluetoothDeviceBattery)?.enabled = settings[Keys.capabilityDeviceBattery]

        // Without the Communication Notifications entitlement the database is the only on/off source.
        let readDatabase = settings[Keys.focusModeDetails] || focus.needsDatabaseForStatus
        focus.setDatabaseReading(readDatabase, folder: nil)
        updateWaveformGlyph()
        updateDeviceBatteryPolling()
        refreshStatus()
    }

    // MARK: Battery

    private func realPowerChanged(_ snapshot: PowerSnapshot) {
        refreshStatus()
        feedPower(snapshot)
    }

    private func feedPower(_ snapshot: PowerSnapshot) {
        batteryMonitor.update(snapshot, now: Self.now).forEach(handleBattery)
        scheduleBatteryTick()
        refreshStatus()
    }

    private func scheduleBatteryTick() {
        batteryTick?.cancel()
        guard let deadline = batteryMonitor.nextDeadline else { return }
        batteryTick = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, deadline - Self.now)))
            guard !Task.isCancelled, let self else { return }
            self.batteryMonitor.tick(now: Self.now).forEach(self.handleBattery)
        }
    }

    private func handleBattery(_ alert: BatteryAlert) {
        guard let snapshot = batteryMonitor.snapshot else { return }
        let kind: NotificationKind
        switch alert {
        case .charging: kind = .charging
        case .lowBattery: kind = .lowBattery
        case .lowPowerMode: kind = .lowPowerMode
        }
        post(kind, .battery(BatteryAlertContent(alert: alert, snapshot: snapshot,
                                                hideLabel: settings[Keys.batteryHideLabel],
                                                hidePercentage: settings[Keys.batteryHidePercentage])))
        switch alert {
        case .lowBattery where settings[Keys.batteryLowSound]: play(.lowBattery, for: kind)
        case .lowPowerMode: play(.lowPower, for: kind)
        default: break
        }
    }

    // MARK: Audio devices

    private func realDevicesChanged() {
        refreshStatus()
        deviceSettle?.cancel()
        deviceSettle = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.deviceSettleDelay))
            guard !Task.isCancelled, let self else { return }
            self.feedDevices(self.withBatteries(self.deviceSource.devices))
        }
    }

    private func bluetoothAccessChanged() {
        updateDeviceBatteryPolling()
        refreshStatus()
    }

    private func withBatteries(_ devices: [ConnectedAudioDevice]) -> [ConnectedAudioDevice] {
        guard deviceBattery.isAvailable else { return devices }
        return devices.map { device in
            var device = device
            device.batteries = deviceBattery.levels(for: device)
            return device
        }
    }

    private func feedDevices(_ devices: [ConnectedAudioDevice]) {
        deviceMonitor.update(devices).forEach(handleDevice)
        updateDeviceBatteryPolling()
        refreshStatus()
    }

    private func handleDevice(_ alert: DeviceAlert) {
        let style = settings[Keys.deviceVisualStyle]
        let threshold = settings[Keys.deviceLowThreshold]
        switch alert {
        case .connected(let device):
            post(.deviceConnected, .device(DeviceAlertContent(device: device, low: false, style: style, lowThreshold: threshold)))
        case .lowBattery(let device):
            post(.deviceLowBattery, .device(DeviceAlertContent(device: device, low: true, style: style, lowThreshold: threshold)))
            if settings[Keys.deviceLowSound] { play(.deviceLowBattery, for: .deviceLowBattery) }
        }
    }

    private func updateDeviceBatteryPolling() {
        let needed = !deviceSource.devices.isEmpty && settings[Keys.deviceAlerts]
            && settings[Keys.deviceLowWarning] && deviceBattery.isAvailable
        if needed, deviceBatteryTimer == nil {
            let timer = Timer(timeInterval: Self.deviceBatteryPoll, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.feedDevices(self.withBatteries(self.deviceSource.devices))
                }
            }
            timer.tolerance = 10
            RunLoop.main.add(timer, forMode: .common)
            deviceBatteryTimer = timer
        } else if !needed {
            deviceBatteryTimer?.invalidate()
            deviceBatteryTimer = nil
        }
    }

    // MARK: Focus

    private func realFocusChanged() {
        refreshStatus()
        feedFocus(focus.state)
    }

    /// Unknown readings (no access) keep the last decision.
    private func feedFocus(_ state: FocusState?) {
        guard let state else { return }
        let isBaseline = focusMonitor.committed == nil
        focusMonitor.submit(state, now: Self.now)
        if isBaseline { focusCommitted() }
        scheduleFocusTick()
    }

    private func scheduleFocusTick() {
        focusTick?.cancel()
        guard let deadline = focusMonitor.nextDeadline else { return }
        focusTick = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, deadline - Self.now)))
            guard !Task.isCancelled, let self else { return }
            let alert = self.focusMonitor.tick(now: Self.now)
            self.focusCommitted()
            if let alert { self.handleFocus(alert) }
        }
    }

    /// The Focus context (notification filters) and the waveform replacement follow the decision.
    private func focusCommitted() {
        hub.setFocus(focusMonitor.current?.active ?? false)
        updateWaveformGlyph()
        refreshStatus()
    }

    private func handleFocus(_ alert: FocusAlert) {
        guard settings[Keys.focusAlerts] else { return }
        post(.focus, .focus(FocusAlertContent(mode: alert.mode, on: alert.isOn, hideLabel: settings[Keys.focusHideLabel])))
        if alert.isOn, alert.mode.identifier == FocusModeCatalog.sleep, settings[Keys.focusSleepSound] {
            play(.sleep, for: .focus)
        }
    }

    private func updateWaveformGlyph() {
        let glyph = settings[Keys.focusAlerts]
            ? FocusWaveformRule.replacement(for: focusMonitor.current, enabled: settings[Keys.focusReplacesWaveform],
                                            onlyMode: settings[Keys.focusReplacesWaveformMode])
            : nil
        if hub.focusGlyphForWaveform != glyph { hub.focusGlyphForWaveform = glyph }
    }

    // MARK: Posting and sounds

    private func post(_ kind: NotificationKind, _ payload: NotificationPayload) {
        hub.post(kind, payload: payload)
        record("post \(kind.rawValue): \(payload.label) \(payload.value ?? "")")
    }

    /// Sounds follow the same Focus filter as the alerts they belong to.
    private func play(_ sound: AlertSound, for kind: NotificationKind) {
        guard allows(kind) else {
            record("sound \(sound.rawValue) filtered")
            return
        }
        sounds.play(sound)
        record("sound \(sound.rawValue)")
    }

    func allows(_ kind: NotificationKind) -> Bool {
        let filters = NotificationFilters(
            allowedWhenFocused: Set(NotificationGroup.allCases.filter { settings[Keys.allowWhenFocused($0)] }))
        return filters.allows(kind, in: ActivityContext(focusActive: hub.focusActive))
    }

    private func record(_ line: String) {
        log.append(String(format: "%.3f ", Self.now) + line)
        if log.count > 40 { log.removeFirst(log.count - 40) }
    }

    // MARK: Settings actions

    func previewSound(_ sound: AlertSound) { sounds.play(sound) }

    func requestBluetoothAccess() {
        settings[Keys.deviceBluetoothPrompted] = true
        deviceBattery.requestAccess()
    }

    func requestFocusAccess() { focus.requestAccess() }

    private func refreshStatus() {
        status.power = batteryMonitor.snapshot ?? power.snapshot
        status.bluetoothAccess = BluetoothAccess.current
        status.deviceLevels = deviceBattery.status
        status.connectedDevices = deviceMonitor.entries.count
        status.focusAccess = focus.access
        status.focusDatabase = focus.databaseStatus
        status.focusDetection = focus.detection
        status.focusNeedsDatabase = focus.needsDatabaseForStatus
        if status.focusModes != focus.knownModes { status.focusModes = focus.knownModes }
        status.focusState = focusMonitor.current
    }
}
