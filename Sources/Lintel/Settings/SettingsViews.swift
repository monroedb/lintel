import AppKit
import LintelCore
import SwiftUI

/// Settings sections (Lintel's own grouping: Island · Alerts · Activities · App).
enum SettingsSection: String, CaseIterable, Identifiable, Hashable {
    case island, battery, devices, focus, brightness, volume, media, calendar, timer, shelf, general, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .island: return "Island"
        case .battery: return "Battery"
        case .devices: return "Audio Devices"
        case .focus: return "Focus"
        case .brightness: return "Brightness"
        case .volume: return "Volume"
        case .media: return "Media"
        case .calendar: return "Calendar"
        case .general: return "General"
        case .about: return "About"
        case .timer: return "Timer"
        case .shelf: return "Shelf"
        }
    }

    var symbol: String {
        switch self {
        case .island: return "rectangle.topthird.inset.filled"
        case .battery: return "battery.75percent"
        case .devices: return "headphones"
        case .focus: return "moon.fill"
        case .brightness: return "sun.max.fill"
        case .volume: return "speaker.wave.2.fill"
        case .media: return "music.note"
        case .calendar: return "calendar"
        case .general: return "gearshape.fill"
        case .about: return "info.circle.fill"
        case .timer: return "timer"
        case .shelf: return "tray.full.fill"
        }
    }

    static let groups: [(String, [SettingsSection])] = [
        ("Island", [.island]),
        ("Alerts", [.battery, .devices, .focus, .brightness, .volume]),
        ("Activities", [.media, .calendar, .timer, .shelf]),
        ("App", [.general, .about]),
    ]
}

struct SettingsRootView: View {
    let settings: SettingsStore
    let loginItems: LoginItemService
    @State private var selection: SettingsSection? = SettingsNavigation.shared.lastSection

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(SettingsSection.groups, id: \.0) { group in
                    Section(group.0) {
                        ForEach(group.1) { section in
                            Label {
                                Text(section.title)
                            } icon: {
                                Image(systemName: section.symbol).foregroundStyle(Brand.copper)
                            }
                            .tag(section)
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 200, max: 240)
        } detail: {
            switch selection ?? .island {
            case .island:
                IslandSettingsView(settings: settings)
            case .general:
                GeneralSettingsView(settings: settings, loginItems: loginItems)
            case .about:
                AboutSettingsView()
            case .battery:
                BatterySettingsView(settings: settings)
            case .devices:
                DeviceSettingsView(settings: settings)
            case .focus:
                FocusSettingsView(settings: settings)
            case .brightness, .volume:
                HUDSettingsView(kind: selection == .volume ? .volume : .brightness, settings: settings)
            case .media:
                MediaSettingsView(settings: settings)
            case .calendar:
                CalendarSettingsView(settings: settings)
            case .timer:
                TimerSettingsView(settings: settings)
            case .shelf:
                ShelfSettingsView(settings: settings)
            }
        }
        .tint(Brand.copper)
        .frame(minWidth: 640, minHeight: 460)
        // Requests from elsewhere (⌥ + a HUD key) to show a section.
        .onAppear { takeNavigationRequest() }
        .onChange(of: SettingsNavigation.shared.requested) { takeNavigationRequest() }
        .onChange(of: selection) { SettingsNavigation.shared.lastSection = selection ?? .island }
    }

    private func takeNavigationRequest() {
        guard let section = SettingsNavigation.shared.requested else { return }
        selection = section
        SettingsNavigation.shared.requested = nil
    }
}

/// App-wide settings: opening at login and the menu-bar item.
struct GeneralSettingsView: View {
    let settings: SettingsStore
    let loginItems: LoginItemService

    var body: some View {
        Form {
            Section {
                Toggle("Open at login", isOn: Binding(get: { loginItems.isEnabled },
                                                      set: { loginItems.setEnabled($0) }))
                if loginItems.needsApproval {
                    LabeledContent("Waiting for approval in System Settings") {
                        Button("Open Login Items…") { loginItems.openSystemSettings() }
                    }
                }
                if let error = loginItems.lastError {
                    Text(error).font(.callout).foregroundStyle(.red)
                }
                Toggle("Show in menu bar", isOn: settings.binding(Keys.showMenuBarItem))
            } footer: {
                Text("When the menu bar item is hidden, Settings… and Quit Lintel are in the island’s right-click menu, and opening Lintel again from Finder or Spotlight brings up Settings.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("General")
        .onAppear { loginItems.refresh() }
    }
}

struct IslandSettingsView: View {
    let settings: SettingsStore

    var body: some View {
        Form {
            Section("Placement") {
                Picker("Show on", selection: settings.binding(Keys.displaySelection)) {
                    ForEach(DisplaySelection.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                if settings[Keys.displaySelection] == .selected {
                    Picker("Display", selection: chosenDisplay) {
                        ForEach(NSScreen.screens, id: \.displayUUID) { screen in
                            Text(screen.localizedName).tag(Optional(screen.displayUUID))
                        }
                    }
                }
                Toggle("Draw a notch on displays without one", isOn: settings.binding(Keys.forceSimulatedNotch))
                Toggle("Hide from screenshots and recordings", isOn: settings.binding(Keys.hideFromScreenCapture))
                Toggle("Keep still when switching desktops", isOn: settings.binding(Keys.windowSpaceCapability))
                Toggle("Animate with Mission Control", isOn: settings.binding(Keys.animateMissionControl))
                    .disabled(!settings[Keys.hideInMissionControl])
                    .help("The island tucks into the notch as Mission Control opens and grows back after it closes.")
                if settings[Keys.windowSpaceCapability],
                   let status = PrivateCapabilityRegistry.shared.status(CGSWindowSpaceProvider.capabilityID), !status.isUsable {
                    Text("\(status.settingsLabel). The island slides with the desktop instead.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }

            Section {
                Toggle("Open when hovering", isOn: settings.binding(Keys.expandOnHover))
                LabeledContent("Hover delay") {
                    HStack {
                        Slider(value: settings.binding(Keys.hoverDelay), in: 0...1.5, step: 0.05)
                            .frame(width: 180)
                        Text(settings[Keys.hoverDelay], format: .number.precision(.fractionLength(2)))
                            .monospacedDigit()
                            .frame(width: 36, alignment: .trailing)
                        Text("s").foregroundStyle(.secondary)
                    }
                }
                .disabled(!settings[Keys.expandOnHover])
                Toggle("Haptic feedback", isOn: settings.binding(Keys.haptics))
                Toggle("Outline the island on dark backgrounds", isOn: settings.binding(Keys.contrastOutline))
                Toggle("Blur what's behind the open island", isOn: settings.binding(Keys.progressiveBlur))
            } header: {
                Text("Behaviour")
            } footer: {
                Text("When hovering doesn't open the island, click it instead.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section {
                Picker("When nothing is going on, open to", selection: settings.binding(Keys.idleActivity)) {
                    ForEach(IdleActivity.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Toggle("Open to the latest activity instead", isOn: settings.binding(Keys.followMostRecent))
            } header: {
                Text("Open island")
            } footer: {
                Text("With both media and an event under way, the island opens to both side by side.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section {
                Toggle("In full-screen apps", isOn: settings.binding(Keys.hideInFullScreen))
                Toggle("During Mission Control", isOn: settings.binding(Keys.hideInMissionControl))
                Toggle("While playing games", isOn: settings.binding(Keys.hideWhileGaming))
            } header: {
                Text("Step aside")
            } footer: {
                Text("In full screen only alerts appear; ongoing activities and peeks wait until you leave.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Swipe down to open, up to close", isOn: settings.binding(Keys.gestureToggle))
                Toggle("Swipe down on the open island to switch activity", isOn: settings.binding(Keys.gestureCycle))
                Toggle("Swipe up on an activity to put it away", isOn: settings.binding(Keys.gestureDismiss))
                Toggle("Swipe sideways to change track", isOn: settings.binding(Keys.gestureSkip))
                Toggle("Skip in the direction the content moves", isOn: settings.binding(Keys.gestureNaturalDirection))
            } header: {
                Text("Gestures")
            } footer: {
                Text("Swipes need a trackpad. A middle click also switches the activity. Activities you put away come back the next time the island closes.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section("Fine-tuning") {
                Stepper(value: settings.binding(Keys.widthTuning), in: -20...40, step: 1) {
                    LabeledContent("Extra width", value: "\(Int(settings[Keys.widthTuning])) pt")
                }
                Stepper(value: settings.binding(Keys.heightTuning), in: -6...12, step: 1) {
                    LabeledContent("Extra height", value: "\(Int(settings[Keys.heightTuning])) pt")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Island")
    }

    private var chosenDisplay: Binding<String?> {
        Binding(get: { settings[Keys.chosenDisplayUUID] },
                set: { uuid in
                    settings[Keys.chosenDisplayUUID] = uuid
                    settings[Keys.chosenDisplayName] = NSScreen.screens.first { $0.displayUUID == uuid }?.localizedName ?? ""
                })
    }
}

/// Seconds slider with a value readout.
struct SecondsSlider: View {
    let title: String
    let value: Binding<Double>
    let range: ClosedRange<Double>
    var step: Double = 0.5

    var body: some View {
        LabeledContent(title) {
            HStack {
                Slider(value: value, in: range, step: step).frame(width: 180)
                Text(value.wrappedValue, format: .number.precision(.fractionLength(1)))
                    .monospacedDigit()
                    .frame(width: 32, alignment: .trailing)
                Text("s").foregroundStyle(.secondary)
            }
        }
    }
}

struct AboutSettingsView: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(short) (\(build))"
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Version", value: version)
            }
            Section("Acknowledgements") {
                ThirdPartyNoticesView()
            }
        }
        .formStyle(.grouped)
        .navigationTitle("About")
    }
}
