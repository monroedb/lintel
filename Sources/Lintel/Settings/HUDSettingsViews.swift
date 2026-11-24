import AppKit
import LintelCore
import Observation
import SwiftUI

/// Lets other parts of the app open Settings on a given section (⌥ + a HUD key).
@MainActor
@Observable
final class SettingsNavigation {
    static let shared = SettingsNavigation()
    var requested: SettingsSection?
    /// The page last shown: a Settings window made again (after the closed one was released)
    /// opens on it, as the kept window did.
    @ObservationIgnored var lastSection: SettingsSection = .island

    static func section(for kind: HUDKind) -> SettingsSection { kind == .volume ? .volume : .brightness }
}

/// The Volume and Brightness sections. Without Accessibility access only the switch and the access
/// request are shown (HUD settings hidden without Accessibility).
struct HUDSettingsView: View {
    let kind: HUDKind
    let settings: SettingsStore

    private var keys: HUDSettingKeys { Keys.hud(kind) }
    private var service: SystemHUDService? { SystemHUDService.current }
    private var noun: String { kind == .volume ? "volume" : "brightness" }

    var body: some View {
        let access = service?.access
        let enabled = settings[keys.enabled]
        let showsRows = access?.showsHUDSettings ?? false
        Form {
            Section {
                Toggle(isOn: settings.binding(keys.enabled)) {
                    Label("Show \(noun) changes in the island", systemImage: kind == .volume ? "speaker.wave.2.fill" : "sun.max.fill")
                }
                if enabled, let access, !access.isTrusted {
                    AccessibilityRequestRow(access: access)
                }
            } footer: {
                Text(kind == .volume
                     ? "Replaces the system’s volume indicator when you press the volume or mute keys."
                     : "Replaces the system’s brightness indicator when you press the brightness keys.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            if showsRows {
                Section {
                    SecondsSlider(title: "Stay on screen for", value: linked(\.duration), range: 0.5...5)
                    HUDTilePicker(selection: linked(\.style), options: HUDBarStyle.allCases) { style, _ in
                        HUDStyleTile(kind: kind, style: style)
                    } caption: { style in
                        Self.title(style, kind: kind)
                    }
                    Toggle("Show percentage", isOn: linked(\.showPercentage))
                    Toggle("Hide label", isOn: linked(\.hideLabel))
                    HUDTilePicker(selection: linked(\.speed), options: HUDBarSpeed.allCases) { speed, selected in
                        HUDSpeedTile(speed: speed, selected: selected)
                    } caption: { speed in
                        Self.title(speed)
                    }
                    if kind == .volume {
                        HUDTilePicker(selection: settings.binding(Keys.volumeLabelMode), options: VolumeLabelMode.allCases) { mode, _ in
                            VolumeLabelTile(mode: mode, device: service?.volume.device)
                        } caption: { mode in
                            mode == .symbol ? "Speaker symbol" : "Output device"
                        }
                    }
                    HStack {
                        Text(kind == .volume ? "Hold ⌥⇧ for finer steps; ⌥ with a volume key opens this page."
                                             : "Hold ⌥⇧ for finer steps; ⌥ with a brightness key opens this page.")
                            .font(.footnote).foregroundStyle(.secondary)
                        Spacer()
                        Button("Preview") { service?.preview(kind) }
                    }
                } header: {
                    Text("Look")
                }

                Section {
                    Toggle("Use the same look for volume and brightness", isOn: linkBinding)
                } footer: {
                    Text("Changes to duration, style, speed, percentage and label then apply to both.")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                if kind == .brightness {
                    Section("Displays") {
                        Picker("Brightness keys adjust", selection: settings.binding(Keys.brightnessTarget)) {
                            Text("Display under the pointer").tag(BrightnessTargetMode.automatic)
                            Text("Built-in display").tag(BrightnessTargetMode.builtIn)
                            Text("External display").tag(BrightnessTargetMode.external)
                        }
                        Toggle("Control the built-in display directly", isOn: settings.binding(Keys.displayServicesCapability))
                        LabeledContent("Built-in display control",
                                       value: PrivateCapabilityRegistry.shared.status(DisplayServicesBrightnessController.capabilityID)?.settingsLabel ?? "—")
                        LabeledContent("BetterDisplay", value: betterDisplayStatus)
                    }
                } else {
                    Section {
                        LabeledContent("Feedback sound", value: service?.systemFeedbackEnabled == true ? "On" : "Off")
                    } footer: {
                        Text("Follows “Play feedback when volume is changed” in System Settings › Sound.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(kind == .volume ? "Volume" : "Brightness")
    }

    private var betterDisplayStatus: String {
        guard let bridge = service?.betterDisplay, bridge.isRunning else { return "Not running" }
        return bridge.integrationRequested ? "Connected — Lintel shows its changes" : "Running"
    }

    /// Binding that also writes the other HUD's key while the looks are linked.
    private func linked<Value: SettingValue>(_ path: KeyPath<HUDSettingKeys, SettingKey<Value>>) -> Binding<Value> {
        let key = keys[keyPath: path]
        let other = Keys.hud(kind == .volume ? .brightness : .volume)[keyPath: path]
        return Binding(get: { settings[key] }, set: { value in
            settings[key] = value
            if settings[Keys.linkHUDAppearance] { settings[other] = value }
        })
    }

    private var linkBinding: Binding<Bool> {
        Binding(get: { settings[Keys.linkHUDAppearance] }, set: { on in
            settings[Keys.linkHUDAppearance] = on
            guard on else { return }
            // Linking copies this section's look to the other HUD.
            let other = Keys.hud(kind == .volume ? .brightness : .volume)
            settings[other.style] = settings[keys.style]
            settings[other.speed] = settings[keys.speed]
            settings[other.showPercentage] = settings[keys.showPercentage]
            settings[other.hideLabel] = settings[keys.hideLabel]
            settings[other.duration] = settings[keys.duration]
        })
    }

    static func title(_ style: HUDBarStyle, kind: HUDKind) -> String {
        switch style {
        case .white: return "White"
        case .accent: return "Accent"
        case .vivid: return kind == .volume ? "Meter" : "Glow"
        }
    }

    static func title(_ speed: HUDBarSpeed) -> String {
        switch speed {
        case .smooth: return "Smooth"
        case .fast: return "Fast"
        case .instant: return "Instant"
        }
    }
}

/// Shown while a HUD is on but Accessibility access is missing.
struct AccessibilityRequestRow: View {
    let access: AccessibilityAccess

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "hand.raised.fill")
                .foregroundStyle(Brand.copper)
                .font(.system(size: 15))
            VStack(alignment: .leading, spacing: 6) {
                Text("Needs Accessibility access")
                    .font(.body.weight(.semibold))
                Text("Until it’s allowed, macOS keeps showing its own indicator and these options stay hidden.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if HUDAccessGuidance.evaluate(hudEnabled: true, trusted: access.isTrusted, prompted: access.wasPrompted,
                                              signatureChanged: access.signatureChange != nil) == .reAdd {
                    // Asked before (or the signature changed) and still not trusted: a switch that looks
                    // on was recorded for another signature (the log names both).
                    if access.signatureChange != nil {
                        Text("Lintel was replaced since it last ran, and permissions given to the earlier copy don’t apply to this one, even where System Settings shows them on.")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("If Lintel is already switched on in that list, the switch belongs to an earlier copy of Lintel, and switching it off and on doesn’t change that. Select Lintel there, remove it with −, then click + and choose \(Bundle.main.bundlePath).")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                Button(access.wasPrompted ? "Open Accessibility Settings…" : "Allow in System Settings…") { access.requestAccess() }
            }
        }
        .padding(.vertical, 2)
    }
}

/// Row of selectable tiles with captions (selected tile outlined in the accent colour).
struct HUDTilePicker<Value: Hashable, Tile: View>: View {
    @Binding var selection: Value
    let options: [Value]
    @ViewBuilder let tile: (Value, Bool) -> Tile
    let caption: (Value) -> String

    var body: some View {
        HStack(spacing: 10) {
            ForEach(options, id: \.self) { option in
                let selected = option == selection
                Button {
                    selection = option
                } label: {
                    VStack(spacing: 6) {
                        tile(option, selected)
                            .frame(maxWidth: .infinity)
                            .frame(height: 40)
                            .padding(3)
                            .overlay {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(selected ? Brand.copper : Color.clear, lineWidth: 2.5)
                            }
                        Text(caption(option))
                            .font(.callout.weight(selected ? .semibold : .regular))
                            .foregroundStyle(selected ? .primary : .secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(caption(option))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(.vertical, 4)
    }
}

/// Bar sample in a style, on black like the island.
struct HUDStyleTile: View {
    let kind: HUDKind
    let style: HUDBarStyle

    var body: some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(Color.black)
            .overlay {
                HUDLevelBar(kind: kind, level: 0.72, appearance: HUDAppearance(style: style), overshoot: nil)
                    .frame(width: 64, height: HUDBarMetrics.trackHeight)
            }
    }
}

struct HUDSpeedTile: View {
    let speed: HUDBarSpeed
    let selected: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(Color.primary.opacity(selected ? 0.10 : 0.05))
            .overlay {
                Image(systemName: speed == .smooth ? "tortoise.fill" : speed == .fast ? "hare.fill" : "bolt.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(selected ? Brand.copper : .secondary)
            }
    }
}

struct VolumeLabelTile: View {
    let mode: VolumeLabelMode
    let device: OutputDeviceInfo?

    var body: some View {
        let deviceSymbol = device.map { $0.isBuiltInSpeakers ? "headphones" : HUDGlyphs.deviceSymbol($0) } ?? "headphones"
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(Color.black)
            .overlay {
                Image(systemName: mode == .symbol ? "speaker.wave.2.fill" : deviceSymbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
            }
    }
}
