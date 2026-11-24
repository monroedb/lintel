import CoreGraphics
import Foundation
import LintelCore

/// Checks for battery, audio-device and Focus alerts (sources, monitors, formats,
/// sizes and settings defaults).
func runAlertChecks() {
    m5PowerParsing()
    m5BatteryMonitor()
    m5FocusCatalogAndMonitor()
    m5FocusDatabase()
    m5Devices()
    m5DeviceMonitor()
    m5Metrics()
}

private func m5PowerParsing() {
    let onBattery: [String: Any] = ["Type": "InternalBattery", "Is Present": true, "Current Capacity": 93, "Max Capacity": 100,
                                    "Power Source State": "Battery Power", "Is Charging": false, "Time to Empty": 432,
                                    "Time to Full Charge": 0]
    let p = PowerSnapshot.parse(descriptions: [onBattery], lowPowerMode: false)
    check(p.hasBattery && p.level == 93 && !p.externalPower && !p.charging, "IOKit description on battery (got \(p))")
    check(p.minutesToEmpty == 432 && p.minutesToFull == nil && p.minutesRemaining == 432, "time to empty read in minutes")

    var charging = onBattery
    charging["Power Source State"] = "AC Power"
    charging["Is Charging"] = true
    charging["Time to Full Charge"] = 75
    charging["Time to Empty"] = -1
    let c = PowerSnapshot.parse(descriptions: [["Type": "UPS"], charging], lowPowerMode: true)
    check(c.externalPower && c.charging && !c.charged && c.lowPowerMode, "charging on AC with Low Power Mode")
    check(c.minutesToFull == 75 && c.minutesToEmpty == nil && c.minutesRemaining == 75, "time to full while charging")

    charging["Time to Full Charge"] = -1
    check(PowerSnapshot.parse(descriptions: [charging], lowPowerMode: false).minutesToFull == nil, "-1 (still estimating) → unknown")

    var full = charging
    full["Is Charging"] = false
    full["Current Capacity"] = 100
    let f = PowerSnapshot.parse(descriptions: [full], lowPowerMode: false)
    check(f.charged && !f.charging && f.minutesRemaining == nil, "full on AC reads as charged")

    var scaled = onBattery
    scaled["Current Capacity"] = 2_100
    scaled["Max Capacity"] = 4_200
    check(PowerSnapshot.parse(descriptions: [scaled], lowPowerMode: false).level == 50, "capacity scaled to percent")

    let desktop = PowerSnapshot.parse(descriptions: [], lowPowerMode: true)
    check(!desktop.hasBattery && desktop.lowPowerMode, "no internal battery → no battery")
    var absent = onBattery
    absent["Is Present"] = false
    check(!PowerSnapshot.parse(descriptions: [absent], lowPowerMode: false).hasBattery, "battery not present → no battery")

    check(AlertFormat.duration(minutes: 125) == "2h 5m" && AlertFormat.duration(minutes: 45) == "45m"
          && AlertFormat.duration(minutes: 120) == "2h", "remaining time format")
    check(AlertFormat.duration(minutes: nil) == nil && AlertFormat.duration(minutes: 0) == nil
          && AlertFormat.duration(minutes: 7_000) == nil, "unknown or implausible estimates hidden")
    check(AlertFormat.percent(80) == "80 %", "percent format")
}

private func m5BatteryMonitor() {
    func snap(_ level: Int, ac: Bool, lpm: Bool = false) -> PowerSnapshot {
        PowerSnapshot(level: level, externalPower: ac, charging: ac && level < 100, lowPowerMode: lpm)
    }
    let debounce = BatteryAlertConfig.chargeDebounce

    // Charging: debounced, flicker suppressed, baseline silent.
    var m = BatteryAlertMonitor()
    check(m.update(snap(50, ac: true), now: 0).isEmpty && m.nextDeadline == nil, "first reading is the baseline (no alert)")
    m.update(snap(50, ac: false), now: 1)
    check(m.update(snap(50, ac: true), now: 2).isEmpty, "plugging in doesn't alert immediately")
    check(m.nextDeadline == 2 + debounce, "charging alert scheduled after the debounce")
    check(m.tick(now: 2 + debounce - 0.01).isEmpty, "not before the debounce ends")
    check(m.tick(now: 2 + debounce) == [.charging], "charging alert after the debounce")
    check(m.tick(now: 10).isEmpty, "charging alert fires once")
    m.update(snap(51, ac: true), now: 11)
    check(m.tick(now: 20).isEmpty, "staying on AC doesn't re-alert")
    m.update(snap(51, ac: false), now: 30)
    m.update(snap(51, ac: true), now: 30.2)
    m.update(snap(51, ac: false), now: 30.4)
    check(m.nextDeadline == nil && m.tick(now: 31.5).isEmpty, "adapter flicker within the debounce: no alert")

    // Low Power Mode.
    check(m.update(snap(51, ac: false, lpm: true), now: 40) == [.lowPowerMode], "Low Power Mode turning on alerts")
    check(m.update(snap(51, ac: false, lpm: true), now: 41).isEmpty, "Low Power Mode staying on: no repeat")
    check(m.update(snap(51, ac: false), now: 42).isEmpty, "Low Power Mode turning off: no alert")
    var config = BatteryAlertConfig()
    config.lowPowerAlert = false
    m.setConfig(config)
    check(m.update(snap(51, ac: false, lpm: true), now: 43).isEmpty, "'Notify on low power mode' off suppresses it")

    // Low battery: once per crossing, 2 % hysteresis, only on battery.
    var low = BatteryAlertMonitor()
    low.update(snap(14, ac: false), now: 0)
    check(low.lowArmed, "armed above the threshold")
    check(low.update(snap(11, ac: false), now: 1).isEmpty, "11 % > 10 % threshold: no warning")
    check(low.update(snap(10, ac: false), now: 2) == [.lowBattery], "warns at the threshold (10 %)")
    check(low.update(snap(9, ac: false), now: 3).isEmpty && low.update(snap(5, ac: false), now: 4).isEmpty,
          "once per crossing")
    low.update(snap(11, ac: true), now: 5)
    low.update(snap(11, ac: false), now: 6)
    check(low.update(snap(10, ac: false), now: 7).isEmpty, "rising to 11 % (< threshold + 2) doesn't re-arm")
    low.update(snap(12, ac: true), now: 8)
    check(low.lowArmed, "re-armed at threshold + 2 %")
    check(low.update(snap(9, ac: true), now: 9).isEmpty, "no warning on a power adapter")
    check(low.update(snap(9, ac: false), now: 10) == [.lowBattery], "warns once unplugged below the threshold while armed")

    var startLow = BatteryAlertMonitor()
    startLow.update(snap(6, ac: false), now: 0)
    check(!startLow.lowArmed && startLow.update(snap(5, ac: false), now: 1).isEmpty, "starting below the threshold: no crossing")

    var quiet = BatteryAlertMonitor()
    var warnOff = BatteryAlertConfig()
    warnOff.lowWarning = false
    quiet.setConfig(warnOff)
    quiet.update(snap(15, ac: false), now: 0)
    check(quiet.update(snap(10, ac: false), now: 1).isEmpty && !quiet.lowArmed, "'Warn on low battery' off: silent, still disarms")

    var disabled = BatteryAlertMonitor()
    var off = BatteryAlertConfig()
    off.enabled = false
    disabled.setConfig(off)
    disabled.update(snap(15, ac: false), now: 0)
    check(disabled.update(snap(10, ac: false, lpm: true), now: 1).isEmpty, "master switch off: no low or LPM alert")
    disabled.update(snap(10, ac: true), now: 2)
    check(disabled.tick(now: 5).isEmpty, "master switch off: no charging alert")

    var retuned = BatteryAlertMonitor()
    retuned.update(snap(15, ac: false), now: 0)
    var twenty = BatteryAlertConfig()
    twenty.lowThreshold = 20
    retuned.setConfig(twenty)
    check(!retuned.lowArmed, "raising the threshold above the level disarms")
    twenty.lowThreshold = 12
    retuned.setConfig(twenty)
    check(retuned.lowArmed && retuned.update(snap(12, ac: false), now: 1) == [.lowBattery], "new threshold applies")

    var desktop = BatteryAlertMonitor()
    desktop.update(.noBattery(), now: 0)
    check(desktop.update(.noBattery(lowPowerMode: true), now: 1).isEmpty, "no battery: no alerts at all")
}

private func m5FocusCatalogAndMonitor() {
    let dnd = FocusModeCatalog.builtIn(FocusModeCatalog.doNotDisturb)
    check(dnd?.symbol == "moon.fill" && dnd?.tint == SRGBColor(89.0 / 255, 91.0 / 255, 239.0 / 255),
          "Do Not Disturb: moon, indigo as measured (89, 91, 239)")
    check(FocusModeCatalog.builtIn(FocusModeCatalog.sleep)?.name == "Sleep", "Sleep is a built-in mode")
    check(FocusModeCatalog.builtIn.count == 10, "ten built-in modes")
    check(Set(FocusModeCatalog.builtIn.compactMap(\.identifier)).count == 10, "built-in identifiers are unique")
    check(FocusModeCatalog.builtIn("com.example.custom") == nil, "unknown identifier is not built in")
    check(FocusModeCatalog.tint(systemColorName: "systemPinkColor") == SRGBColor(hex: 0xFF375F)
          && FocusModeCatalog.tint(systemColorName: "Indigo") == FocusModeCatalog.indigo
          && FocusModeCatalog.tint(systemColorName: "systemPlaidColor") == nil, "system colour names map to tints")
    check(SRGBColor(hex: 0xFF8000) == SRGBColor(1, 128.0 / 255, 0), "hex colours")

    let reading = FocusModeCatalog.builtIn("com.apple.focus.reading")!
    var m = FocusAlertMonitor()
    check(!m.submit(FocusState(active: false), now: 0) && m.nextDeadline == nil, "first reading is the baseline")
    check(m.submit(FocusState(active: true, mode: dnd), now: 1), "turning on starts a pending decision")
    check(m.tick(now: 1.1) == nil, "decision waits for the settle time")
    check(m.tick(now: 1 + FocusAlertMonitor.settle) == .on(dnd!), "on alert after settling")
    m.submit(FocusState(active: false), now: 5)
    check(m.tick(now: 6) == .off(dnd!), "off alert carries the mode that was on")

    m.submit(FocusState(active: true), now: 10)
    m.submit(FocusState(active: true, mode: reading), now: 10.1)
    check(m.tick(now: 10 + FocusAlertMonitor.settle) == .on(reading), "unknown then known mode within the settle → one alert")
    m.submit(FocusState(active: true, mode: dnd), now: 12)
    check(m.tick(now: 13) == .on(dnd!), "switching modes while on alerts for the new mode")
    m.submit(FocusState(active: true, mode: dnd), now: 14)
    check(m.nextDeadline == nil, "an unchanged reading is ignored")
    m.submit(FocusState(active: false), now: 15)
    m.submit(FocusState(active: true, mode: dnd), now: 15.05)
    check(m.tick(now: 16) == nil, "off and back on within the settle: no alert")

    var unknown = FocusAlertMonitor()
    unknown.submit(FocusState(active: false), now: 0)
    unknown.submit(FocusState(active: true), now: 1)
    let generic = unknown.tick(now: 2)
    check(generic == .on(FocusModeCatalog.generic) && generic?.mode.symbol == "moon.fill", "unknown mode → generic moon")
    unknown.submit(FocusState(active: false), now: 3)
    check(unknown.tick(now: 4) == .off(FocusModeCatalog.generic) && unknown.current?.active == false, "generic off")

    // Replace waveform during Focus.
    let on = FocusState(active: true, mode: reading)
    check(FocusWaveformRule.replacement(for: on, enabled: false, onlyMode: nil) == nil, "replacement off by default")
    check(FocusWaveformRule.replacement(for: on, enabled: true, onlyMode: nil) == reading, "any Focus replaces the waveform")
    check(FocusWaveformRule.replacement(for: on, enabled: true, onlyMode: "com.apple.focus.reading") == reading, "chosen mode matches")
    check(FocusWaveformRule.replacement(for: on, enabled: true, onlyMode: FocusModeCatalog.sleep) == nil, "other mode: waveform stays")
    check(FocusWaveformRule.replacement(for: FocusState(active: true), enabled: true, onlyMode: FocusModeCatalog.sleep) == nil,
          "unknown mode can't match a chosen mode")
    check(FocusWaveformRule.replacement(for: FocusState(active: true), enabled: true, onlyMode: nil) == FocusModeCatalog.generic,
          "unknown mode with 'Any' shows the generic symbol")
    check(FocusWaveformRule.replacement(for: FocusState(active: false, mode: reading), enabled: true, onlyMode: nil) == nil,
          "no Focus: waveform stays")
}

private func m5FocusDatabase() {
    let configurations = """
    {"data":[{"modeConfigurations":{
      "com.apple.focus.reading":{"mode":{"name":"Reading","modeIdentifier":"com.apple.focus.reading",
        "symbolImageName":"book.fill","tintColorName":"systemOrangeColor","semanticType":2}},
      "B1A2-CUSTOM":{"mode":{"name":"Studio","modeIdentifier":"B1A2-CUSTOM","symbolImageName":"paintbrush.fill",
        "tintColorName":"systemPinkColor"}},
      "com.apple.donotdisturb.mode.default":{"mode":{"name":"","modeIdentifier":"com.apple.donotdisturb.mode.default"}}
    }}]}
    """
    let assertions = """
    {"data":[{"storeAssertionRecords":[
      {"assertionDetails":{"assertionDetailsModeIdentifier":"com.apple.focus.reading","assertionDetailsReason":"user-action"},
       "assertionStartDateTimestamp":700000000.5},
      {"assertionDetails":{"assertionDetailsModeIdentifier":"B1A2-CUSTOM"},"assertionStartDateTimestamp":700000100}
    ]}]}
    """
    let db = FocusDatabase.parse(assertions: Data(assertions.utf8), configurations: Data(configurations.utf8))
    check(db.modes.map(\.name) == ["Do Not Disturb", "Reading", "Studio"],
          "configured modes read; an empty built-in name falls back to the catalog (got \(db.modes.map(\.name)))")
    check(db.activeIdentifier == "B1A2-CUSTOM", "latest assertion wins")
    let custom = db.activeMode
    check(custom?.name == "Studio" && custom?.symbol == "paintbrush.fill" && custom?.tint == SRGBColor(hex: 0xFF375F),
          "custom mode: own name, symbol and tint")
    check(db.descriptor(for: "com.apple.focus.reading")?.tint == SRGBColor(hex: 0xFF9F0A), "configured tint used")
    check(db.descriptor(for: FocusModeCatalog.doNotDisturb)?.name == "Do Not Disturb", "built-in fallback for unlisted modes")

    let none = FocusDatabase.parse(assertions: Data(#"{"data":[{"storeAssertionRecords":[]}]}"#.utf8), configurations: nil)
    check(none.activeIdentifier == nil && none.modes.isEmpty, "no assertion → no active mode")
    let garbage = FocusDatabase.parse(assertions: Data("not json".utf8), configurations: Data("[1,2".utf8))
    check(garbage == FocusDatabase.Snapshot(activeIdentifier: nil, modes: []), "unreadable files → unknown, no crash")
    let unordered = FocusDatabase.parse(assertions: Data(#"""
        {"storeAssertionRecords":[{"assertionDetails":{"assertionDetailsModeIdentifier":"a"}},
                                  {"assertionDetails":{"assertionDetailsModeIdentifier":"b"}}]}
        """#.utf8), configurations: nil)
    check(unordered.activeIdentifier == "b", "without timestamps the last record wins")

    // Combining the status center (on/off) with the database (mode).
    check(FocusState.combine(isFocused: nil, database: nil) == nil, "no source → unknown")
    check(FocusState.combine(isFocused: true, database: nil) == FocusState(active: true), "status only → on, mode unknown")
    check(FocusState.combine(isFocused: false, database: db) == FocusState(active: false), "status off wins over a stale record")
    check(FocusState.combine(isFocused: true, database: db) == FocusState(active: true, mode: custom),
          "status on + database → the recorded mode")
    check(FocusState.combine(isFocused: nil, database: db) == FocusState(active: true, mode: custom),
          "database only: a recorded activation means on")
    check(FocusState.combine(isFocused: nil, database: none) == FocusState(active: false), "database only, no record → off")
}

private func m5Devices() {
    check(AudioDeviceClassifier.model(name: "Living Room", productID: 0x2014, vendorID: 0x4C) == .airpodsPro2,
          "Apple product ID identifies AirPods Pro 2")
    check(AudioDeviceClassifier.model(name: "x", productID: 0x200A) == .airpodsMax, "product ID without vendor")
    check(AudioDeviceClassifier.model(name: "x", productID: 0x2014, vendorID: 0x1234) == .headphones,
          "non-Apple vendor ignores the Apple table")
    check(AudioDeviceClassifier.model(name: "Sam’s AirPods Pro") == .airpodsPro, "name: AirPods Pro")
    check(AudioDeviceClassifier.model(name: "AirPods Max") == .airpodsMax, "name: AirPods Max")
    check(AudioDeviceClassifier.model(name: "AirPods") == .airpods && AudioDeviceClassifier.model(name: "AirPods 4") == .airpods4,
          "name: AirPods")
    check(AudioDeviceClassifier.model(name: "Beats Studio Pro") == .beatsHeadphones
          && AudioDeviceClassifier.model(name: "Beats Fit Pro") == .beatsEarbuds
          && AudioDeviceClassifier.model(name: "Powerbeats Pro") == .powerbeats, "name: Beats families")
    check(AudioDeviceClassifier.model(name: "Kitchen HomePod mini") == .homepodMini, "name: HomePod mini")
    check(AudioDeviceClassifier.model(name: "SoundLink Flex") == .speaker, "name: speaker")
    check(AudioDeviceClassifier.model(name: "WH-1000XM5") == .headphones, "unknown name → headphones")
    check(AudioDeviceClassifier.model(name: "Device", terminal: .speaker) == .speaker, "terminal type fallback")
    let parsed = AudioDeviceClassifier.productAndVendor(fromModelUID: "2014 4c")
    check(parsed?.product == 0x2014 && parsed?.vendor == 0x4C, "model UID '2014 4c' → product, vendor")
    check(AudioDeviceClassifier.productAndVendor(fromModelUID: "AppleHDA:12") == nil
          && AudioDeviceClassifier.productAndVendor(fromModelUID: nil) == nil, "other model UIDs ignored")
    check(ConnectedAudioDevice.address(fromUID: "D4-90-9C-AB-CD-EF:output") == "d4-90-9c-ab-cd-ef", "address from device UID")
    check(ConnectedAudioDevice.address(fromUID: "BuiltInSpeakerDevice") == nil, "no address in other UIDs")

    let levels = DeviceBatteryLevels(left: 80, right: 0, chargingCase: 60, single: nil)
    check(levels.right == nil && levels.left == 80, "0 means not reported")
    check(levels.listeningLevel == 80, "case excluded from the listening level")
    check(DeviceBatteryLevels(left: 30, right: 25, chargingCase: 5).listeningLevel == 25, "lowest bud decides")
    check(DeviceBatteryLevels(single: 64).listeningLevel == 64 && DeviceBatteryLevels().isEmpty, "single battery; empty")
    check(AudioDeviceModel.airpodsPro2.isBudPair && !AudioDeviceModel.airpodsMax.isBudPair, "bud pairs vs headphones")
    check(AudioDeviceModel.allCases.allSatisfy { !$0.symbolCandidates.isEmpty && !$0.displayName.isEmpty }, "every model has a symbol")
}

private func m5DeviceMonitor() {
    func pods(_ id: String = "pods", left: Int? = 80, right: Int? = 75, chargingCase: Int? = 60) -> ConnectedAudioDevice {
        ConnectedAudioDevice(id: id, name: "AirPods Pro", model: .airpodsPro2,
                             batteries: DeviceBatteryLevels(left: left, right: right, chargingCase: chargingCase))
    }
    var m = DeviceAlertMonitor()
    check(m.update([pods("already")]).isEmpty, "devices connected at start are the baseline")
    check(m.update([pods("already"), pods()]) == [.connected(pods())], "a new device alerts")
    check(m.update([pods("already"), pods()]).isEmpty, "still connected: no repeat")
    m.update([pods("already")])
    check(m.entries["pods"] == nil, "disconnected device forgotten")
    check(m.update([pods("already"), pods()]) == [.connected(pods())], "reconnecting alerts again")
    check(m.update([pods("already"), pods(left: 15, right: 18)]).isEmpty, "low warning is off by default")

    var warn = DeviceAlertMonitor()
    var config = DeviceAlertConfig()
    config.lowWarning = true
    warn.setConfig(config)
    warn.update([])
    warn.update([pods()])
    check(warn.update([pods(left: 21, right: 30)]).isEmpty, "21 % > 20 % threshold")
    check(warn.update([pods(left: 20, right: 30)]) == [.lowBattery(pods(left: 20, right: 30))], "warns at the threshold")
    check(warn.update([pods(left: 10, right: 30)]).isEmpty, "once per crossing")
    check(warn.update([pods(left: 21, right: 30)]).isEmpty && warn.update([pods(left: 20, right: 30)]).isEmpty,
          "21 % doesn't re-arm (hysteresis 2 %)")
    warn.update([pods(left: 22, right: 30)])
    check(warn.update([pods(left: 19, right: 30)]).count == 1, "re-armed at threshold + 2 %")
    check(warn.update([pods(left: 19, right: 30, chargingCase: 3)]).isEmpty, "a low case alone doesn't warn")

    var unknownFirst = DeviceAlertMonitor()
    unknownFirst.setConfig(config)
    unknownFirst.update([])
    _ = unknownFirst.update([pods(left: nil, right: nil, chargingCase: nil)])
    check(unknownFirst.update([pods(left: 12, right: 14)]).count == 1, "levels unknown at connect, then low → warns")

    var off = DeviceAlertMonitor()
    var disabled = DeviceAlertConfig()
    disabled.enabled = false
    disabled.lowWarning = true
    off.setConfig(disabled)
    off.update([])
    check(off.update([pods()]).isEmpty && off.update([pods(left: 5)]).isEmpty, "master switch off: no device alerts")
}

private func m5Metrics() {
    let base = CGSize(width: 185, height: 33.5)
    let ears = 2 * IslandMetrics.earRadius
    let wide = PresentationMetrics.compactSize(for: .notification(.charging), base: base)
    check(wide == CGSize(width: 425, height: 34.5) && wide.width - ears == 409, "battery alert 425 × 34.5 drawn, body 409")
    check(PresentationMetrics.compactSize(for: .notification(.deviceConnected), base: base) == wide, "device alert as wide")
    check(PresentationMetrics.compactSize(for: .notification(.focus), base: base).width - ears == 260, "Focus alert body stays 260")
    check(PresentationMetrics.compactSize(for: .notification(.volume), base: base).width - ears == 369, "HUD body stays 369")
    check(NotificationKind.allCases.filter(\.isSystemAlert).count == 6 && !NotificationKind.volume.isSystemAlert,
          "six system alert kinds")

    MainActor.assumeIsolated {
        let suite = "lintel.checks.m5.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = SettingsStore(defaults: defaults, center: NotificationCenter())
        check(store[Keys.batteryAlerts] && store[Keys.batteryLowPowerAlert] && store[Keys.batteryLowWarning]
              && store[Keys.batteryLowSound] && !store[Keys.batteryHideLabel] && !store[Keys.batteryHidePercentage],
              "battery defaults (on, on, on, sound on, label and % shown)")
        check(store[Keys.batteryLowThreshold] == 10 && store[Keys.duration(.charging)] == 5, "battery threshold 10 %, 5 s")
        check(store[Keys.deviceAlerts] && !store[Keys.deviceLowWarning] && !store[Keys.deviceLowSound]
              && store[Keys.deviceLowThreshold] == 20 && store[Keys.deviceVisualStyle] == .rendered
              && store[Keys.duration(.deviceConnected)] == 5, "connectivity defaults (on, warn off, 20 %, 3D, 5 s)")
        check(store[Keys.focusAlerts] && !store[Keys.focusSleepSound] && !store[Keys.focusReplacesWaveform]
              && store[Keys.focusReplacesWaveformMode] == nil && !store[Keys.focusHideLabel] && store[Keys.duration(.focus)] == 5,
              "Focus defaults (on, sleep sound off, replace off / any mode, label shown, 5 s)")
        check(!store[Keys.focusModeDetails] && store[Keys.capabilityDeviceBattery], "mode details off by default")
        store[Keys.deviceVisualStyle] = .symbol
        check(defaults.string(forKey: "alerts.devices.visual") == "symbol", "visual style stored as raw value")
        store[Keys.focusReplacesWaveformMode] = FocusModeCatalog.sleep
        check(store[Keys.focusReplacesWaveformMode] == FocusModeCatalog.sleep, "chosen Focus mode stored")
        defaults.removePersistentDomain(forName: suite)
    }
}
