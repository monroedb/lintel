import AppKit
import LintelCore
import SwiftUI

// Settings for the battery, audio-device and Focus alerts.

/// Percent slider with a value readout.
struct PercentSlider: View {
    let title: String
    let value: Binding<Double>
    let range: ClosedRange<Double>

    var body: some View {
        LabeledContent(title) {
            HStack {
                Slider(value: value, in: range, step: 1).frame(width: 180)
                Text("\(Int(value.wrappedValue))")
                    .monospacedDigit()
                    .frame(width: 32, alignment: .trailing)
                Text("%").foregroundStyle(.secondary)
            }
        }
    }
}

/// A switch for a sound, with a button that plays it.
struct SoundToggle: View {
    let title: String
    let isOn: Binding<Bool>
    let sound: AlertSound

    var body: some View {
        Toggle(isOn: isOn) {
            HStack(spacing: 6) {
                Text(title)
                Button {
                    SystemAlertController.current?.previewSound(sound)
                } label: {
                    Image(systemName: "play.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Play the sound")
                .accessibilityLabel("Play sound")
            }
        }
    }
}

private enum PrivacyPane {
    static func open(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Battery

struct BatterySettingsView: View {
    let settings: SettingsStore

    var body: some View {
        let power = SystemAlertController.current?.status.power
        let hasBattery = power?.hasBattery ?? true
        let enabled = settings[Keys.batteryAlerts]
        Form {
            Section {
                Toggle("Battery alerts", isOn: settings.binding(Keys.batteryAlerts))
                SecondsSlider(title: "Stay on screen for", value: settings.binding(Keys.duration(.charging)), range: 1...10)
                    .disabled(!enabled)
                Toggle("Alert when Low Power Mode turns on", isOn: settings.binding(Keys.batteryLowPowerAlert))
                    .disabled(!enabled)
            } footer: {
                Text(hasBattery ? "Shown when you connect a power adapter, when the battery runs low and when Low Power Mode turns on."
                                : "This Mac has no battery, so there are no battery alerts.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section("Low battery") {
                Toggle("Warn when the battery runs low", isOn: settings.binding(Keys.batteryLowWarning))
                PercentSlider(title: "Warn at", value: settings.binding(Keys.batteryLowThreshold), range: 5...50)
                    .disabled(!settings[Keys.batteryLowWarning])
                SoundToggle(title: "Play a sound", isOn: settings.binding(Keys.batteryLowSound), sound: .lowBattery)
                    .disabled(!settings[Keys.batteryLowWarning])
            }
            .disabled(!enabled)

            Section {
                Toggle("Hide the label", isOn: settings.binding(Keys.batteryHideLabel))
                Toggle("Hide the percentage", isOn: settings.binding(Keys.batteryHidePercentage))
            } header: {
                Text("Appearance")
            } footer: {
                if let power, power.hasBattery {
                    Text(Self.describe(power)).font(.footnote).foregroundStyle(.secondary)
                }
            }
            .disabled(!enabled)
        }
        .formStyle(.grouped)
        .disabled(!hasBattery)
        .navigationTitle("Battery")
    }

    static func describe(_ power: PowerSnapshot) -> String {
        var parts = ["Now \(AlertFormat.percent(power.level))"]
        if power.externalPower {
            parts.append(power.charging ? "charging" : "on power")
        } else {
            parts.append("on battery")
        }
        if let left = AlertFormat.duration(minutes: power.minutesRemaining) {
            parts.append(power.externalPower ? "\(left) to full" : "\(left) left")
        }
        if power.lowPowerMode { parts.append("Low Power Mode on") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Audio devices

struct DeviceSettingsView: View {
    let settings: SettingsStore

    var body: some View {
        let status = SystemAlertController.current?.status
        let enabled = settings[Keys.deviceAlerts]
        Form {
            Section {
                Toggle("Audio device alerts", isOn: settings.binding(Keys.deviceAlerts))
                SecondsSlider(title: "Stay on screen for", value: settings.binding(Keys.duration(.deviceConnected)), range: 1...10)
                    .disabled(!enabled)
                DeviceStylePicker(selection: settings.binding(Keys.deviceVisualStyle))
                    .disabled(!enabled)
            } footer: {
                Text("Shown when Bluetooth headphones or speakers connect, with their battery levels.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section("Low battery") {
                Toggle("Warn when a device's battery runs low", isOn: settings.binding(Keys.deviceLowWarning))
                PercentSlider(title: "Warn at", value: settings.binding(Keys.deviceLowThreshold), range: 5...50)
                    .disabled(!settings[Keys.deviceLowWarning])
                SoundToggle(title: "Play a sound", isOn: settings.binding(Keys.deviceLowSound), sound: .deviceLowBattery)
                    .disabled(!settings[Keys.deviceLowWarning])
            }
            .disabled(!enabled)

            Section {
                LabeledContent("Battery levels") {
                    HStack {
                        Text(Self.describe(status?.bluetoothAccess ?? .notDetermined, levels: status?.deviceLevels ?? ""))
                            .foregroundStyle(.secondary)
                        switch status?.bluetoothAccess ?? .notDetermined {
                        case .notDetermined:
                            Button("Allow Access…") { SystemAlertController.current?.requestBluetoothAccess() }
                        case .denied, .restricted:
                            Button("Open Privacy Settings…") { PrivacyPane.open("Privacy_Bluetooth") }
                        case .allowed:
                            EmptyView()
                        }
                    }
                }
            } header: {
                Text("Bluetooth")
            } footer: {
                Text("Connections are noticed without any permission. Battery levels and low-battery warnings need Bluetooth access.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Audio Devices")
    }

    /// `levels` is the battery reader's status: "available", "switched off" or why it can't read.
    static func describe(_ access: BluetoothAccess, levels: String) -> String {
        switch access {
        case .allowed:
            switch levels {
            case "available": return "Shown"
            case "switched off": return "Off"
            default: return "Not available on this Mac"
            }
        case .notDetermined: return "Need Bluetooth access"
        case .denied: return "Bluetooth access is off"
        case .restricted: return "Bluetooth access is restricted"
        }
    }
}

/// Two tiles previewing the device visual styles.
struct DeviceStylePicker: View {
    @Binding var selection: DeviceVisualStyle

    var body: some View {
        HStack(spacing: 12) {
            ForEach(DeviceVisualStyle.allCases, id: \.self) { style in
                Button {
                    selection = style
                } label: {
                    VStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(.black)
                            .frame(height: 48)
                            .overlay { DeviceVisual(model: .airpodsPro2, style: style, low: false) }
                            .overlay {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(selection == style ? Brand.copper : .secondary.opacity(0.25),
                                            lineWidth: selection == style ? 2.5 : 1)
                            }
                        Text(style.title)
                            .font(.callout.weight(selection == style ? .semibold : .regular))
                            .foregroundStyle(selection == style ? .primary : .secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(style.title) device style")
                .accessibilityAddTraits(selection == style ? .isSelected : [])
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Focus

struct FocusSettingsView: View {
    let settings: SettingsStore

    var body: some View {
        let status = SystemAlertController.current?.status
        let enabled = settings[Keys.focusAlerts]
        Form {
            Section {
                Toggle("Focus alerts", isOn: settings.binding(Keys.focusAlerts))
                SecondsSlider(title: "Stay on screen for", value: settings.binding(Keys.duration(.focus)), range: 1...10)
                    .disabled(!enabled)
                SoundToggle(title: "Play a sound when Sleep turns on", isOn: settings.binding(Keys.focusSleepSound), sound: .sleep)
                    .disabled(!enabled)
                Toggle("Hide On and Off", isOn: settings.binding(Keys.focusHideLabel))
                    .disabled(!enabled)
            } footer: {
                Text("Shown when a Focus turns on or off, with its symbol and colour.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Show the Focus symbol instead of the moving bars", isOn: settings.binding(Keys.focusReplacesWaveform))
                Picker("For", selection: settings.binding(Keys.focusReplacesWaveformMode)) {
                    Text("Any Focus").tag(String?.none)
                    Divider()
                    ForEach(Self.modes(status?.focusModes ?? []), id: \.identifier) { mode in
                        Label(mode.name, systemImage: SymbolLookup.first([mode.symbol, "moon.fill"])).tag(mode.identifier)
                    }
                }
                .disabled(!settings[Keys.focusReplacesWaveform])
            } header: {
                Text("While media plays")
            } footer: {
                Text("A chosen Focus can only be recognised when Lintel may identify which Focus is on (below).")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .disabled(!enabled)

            Section {
                ForEach(Self.filterGroups, id: \.self) { group in
                    Toggle(Self.title(group), isOn: settings.binding(Keys.allowWhenFocused(group)))
                }
            } header: {
                Text("Allowed during Focus")
            } footer: {
                Text("Alerts that are switched off stay quiet while any Focus is on.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section {
                let needsDatabase = status?.focusNeedsDatabase ?? false
                LabeledContent("Detects Focus with") {
                    Text(Self.describe(status?.focusDetection ?? .unavailable)).foregroundStyle(.secondary)
                }
                if !needsDatabase {
                    LabeledContent("Focus status") {
                        HStack {
                            Text(Self.describe(status?.focusAccess ?? .notDetermined)).foregroundStyle(.secondary)
                            switch status?.focusAccess ?? .notDetermined {
                            case .notDetermined:
                                Button("Allow Access…") { SystemAlertController.current?.requestFocusAccess() }
                            case .denied, .restricted:
                                Button("Open Privacy Settings…") { PrivacyPane.open("Privacy_Focus") }
                            case .authorized:
                                EmptyView()
                            }
                        }
                    }
                    Toggle("Identify which Focus is on", isOn: settings.binding(Keys.focusModeDetails))
                }
                if needsDatabase || settings[Keys.focusModeDetails] {
                    LabeledContent("Focus settings file") {
                        HStack {
                            Text(status?.focusDatabase == .reading ? "Read" : "Needs Full Disk Access").foregroundStyle(.secondary)
                            if status?.focusDatabase != .reading {
                                Button("Open Privacy Settings…") { PrivacyPane.open("Privacy_AllFiles") }
                            }
                        }
                    }
                }
            } header: {
                Text("Access")
            } footer: {
                Text(status?.focusNeedsDatabase ?? false
                     ? "macOS doesn’t share the Focus status with this copy of Lintel, so it reads the Focus settings file instead, which needs Full Disk Access (System Settings › Privacy & Security › Full Disk Access › +, then choose Lintel). It sees Focuses you turn on yourself, for example in Control Center; a Focus started by a schedule isn’t recorded there."
                     : "macOS tells Lintel whether a Focus is on once you allow it. Which Focus it is (name, symbol, colour) comes from the Focus settings file, which needs Full Disk Access; without it Lintel shows a moon.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Focus")
    }

    /// The alert groups a Focus can silence (time to leave always comes through; Focus changes
    /// themselves are never silenced).
    static let filterGroups = NotificationGroup.allCases.filter { $0 != .travel && $0 != .focus }

    static func title(_ group: NotificationGroup) -> String {
        switch group {
        case .battery: return "Battery"
        case .connectivity: return "Audio devices"
        case .focus: return "Focus"
        case .display: return "Brightness"
        case .sound: return "Volume"
        case .travel: return "Time to leave"
        }
    }

    /// Built-in modes plus custom modes from the Focus database.
    static func modes(_ known: [FocusModeDescriptor]) -> [FocusModeDescriptor] {
        var result = FocusModeCatalog.builtIn
        for mode in known where !result.contains(where: { $0.identifier == mode.identifier }) { result.append(mode) }
        return result
    }

    static func describe(_ detection: FocusDetection) -> String {
        switch detection {
        case .system: return "macOS Focus status"
        case .database: return "Focus settings file"
        case .unavailable: return "Not available yet"
        }
    }

    static func describe(_ access: FocusAccess) -> String {
        switch access {
        case .authorized: return "Allowed"
        case .notDetermined: return "Not allowed yet"
        case .denied: return "Not allowed"
        case .restricted: return "Unavailable"
        }
    }
}
