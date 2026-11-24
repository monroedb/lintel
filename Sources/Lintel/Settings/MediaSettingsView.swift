import AppKit
import LintelCore
import SwiftUI

/// Media section.
struct MediaSettingsView: View {
    let settings: SettingsStore
    private let status = MediaSourceStatus.shared

    var body: some View {
        Form {
            Section {
                Toggle("Show what's playing", isOn: settings.binding(Keys.mediaEnabled))
                SecondsSlider(title: "Keep after pausing", value: settings.binding(Keys.mediaIdleDuration), range: 1...10, step: 1)
                    .disabled(!settings[Keys.mediaEnabled])
            } header: {
                Text("Now Playing")
            } footer: {
                Text("Media shorter than 3 seconds and voice messages from chat apps are ignored.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section("Open player") {
                Picker("Badge after the title", selection: settings.binding(Keys.mediaTitleBadge)) {
                    ForEach(MediaTitleBadge.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Progress bar", selection: settings.binding(Keys.mediaProgressStyle)) {
                    ForEach(MediaProgressStyle.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Extra button", selection: settings.binding(Keys.mediaExtraControl)) {
                    ForEach(MediaExtraControl.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Toggle("Don't flip the artwork when the track changes", isOn: settings.binding(Keys.mediaDisableArtworkFlip))
            }

            Section {
                Toggle("Live waveform from the playing app", isOn: settings.binding(Keys.mediaLiveWaveform))
                Toggle("Hide the waveform in the closed island", isOn: settings.binding(Keys.mediaDisableCompactWaveform))
            } header: {
                Text("Waveform")
            } footer: {
                Text("The live waveform needs permission to record system audio. Without it, or while the output is silent, Lintel animates the waveform instead.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section("Behaviour") {
                Toggle("Hide while the playing app is in front", isOn: settings.binding(Keys.mediaHideWhileSourceActive))
                Toggle("Tidy titles (drop “feat.”, “Remastered” and similar)", isOn: settings.binding(Keys.mediaStripTitleExtras))
            }

            Section {
                Toggle(isOn: settings.binding(Keys.mediaAutomaticSource)) {
                    HStack(spacing: 4) {
                        Text("Follow the app that's playing")
                        if settings[Keys.mediaAutomaticSource], let source = status.source {
                            Text("· \(source)").foregroundStyle(.secondary)
                        }
                    }
                }
                Picker("Source", selection: settings.binding(Keys.mediaSource)) {
                    ForEach(MediaSourceChoice.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .disabled(settings[Keys.mediaAutomaticSource])
                Toggle("Use the System source", isOn: settings.binding(Keys.mediaSystemAdapter))
                LabeledContent("System source", value: status.adapter)
            } header: {
                Text("Source")
            } footer: {
                Text("System shows what's playing in any app. Music and Spotify can also be read directly, which adds favourites, repeat one and share links; macOS asks once for permission to control them.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Quick Peek", isOn: settings.binding(Keys.mediaPeek))
                Toggle("Peek when the track changes", isOn: settings.binding(Keys.mediaPeekOnChange))
                    .disabled(!settings[Keys.mediaPeek])
                SecondsSlider(title: "Peek for", value: settings.binding(Keys.mediaPeekDuration), range: 1...6)
                    .disabled(!settings[Keys.mediaPeek])
            } header: {
                Text("Quick Peek")
            } footer: {
                Text("Shows the new track for a moment when it changes on its own while the island shows something else.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Media")
    }
}

/// Third-party notices (the adapter's licence ships in THIRD_PARTY_NOTICES.md and the
/// About window; no endorsement is implied).
enum ThirdPartyNotices {
    static let aboutLine = "Includes MediaRemote Adapter, © 2025 Jonas van den Berg and contributors, under the BSD 3-Clause License (see Settings › About). No endorsement is implied."

    /// The bundled THIRD_PARTY_NOTICES.md (copied into the app by scripts/build-app.sh).
    static var text: String {
        if let url = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md"),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            return text
        }
        return "MediaRemote Adapter — Copyright (c) 2025, Jonas van den Berg and contributors. BSD 3-Clause License."
    }
}

struct ThirdPartyNoticesView: View {
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("MediaRemote Adapter (ungive/mediaremote-adapter) reads system-wide Now Playing. © 2025 Jonas van den Berg and contributors, BSD 3-Clause License. No endorsement is implied.")
                .foregroundStyle(.secondary)
            DisclosureGroup("Licence text", isExpanded: $expanded) {
                ScrollView {
                    Text(ThirdPartyNotices.text)
                        .font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 180)
            }
        }
    }
}
