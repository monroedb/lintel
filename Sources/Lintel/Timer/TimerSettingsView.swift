import LintelCore
import SwiftUI

/// Settings › Activities › Timer.
struct TimerSettingsView: View {
    let settings: SettingsStore

    private var enabled: Bool { settings[Keys.timerEnabled] }

    var body: some View {
        Form {
            Section {
                Toggle("Show timers in the island", isOn: settings.binding(Keys.timerEnabled))
                Picker("Picker style", selection: settings.binding(Keys.timerPickerStyle)) {
                    Text("Ruler").tag(TimerPickerStyle.ruler)
                    Text("Classic").tag(TimerPickerStyle.classic)
                }
                .pickerStyle(.segmented)
                .disabled(!enabled)
            } header: {
                Text("Timer")
            } footer: {
                Text("Start a timer from the open island, a right-click on the island or the menu bar. Ruler: scrub the minutes with two fingers, the wheel, a drag or the arrow keys, then Start Timer or Return. Classic: tiles from 1 to 30 minutes and Custom. Swipe down on the open island to reach the timer page.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section {
                TimerPresetsEditor(settings: settings)
            } header: {
                Text("Quick presets")
            } footer: {
                Text("One click starts a timer: the pills under the ruler, Start Timer in the island's right-click menu and Timer in the menu bar. Up to \(TimerQuickPresets.maximumCount), from 1 to 1440 minutes.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .disabled(!enabled)

            Section {
                LabeledContent("Play a sound") {
                    HStack(spacing: 10) {
                        Button {
                            TimerFeature.shared?.sound.play()
                        } label: {
                            Image(systemName: "play.fill")
                        }
                        .buttonStyle(.borderless)
                        .help("Play")
                        .accessibilityLabel("Play the timer sound")
                        Toggle("Play a sound", isOn: settings.binding(Keys.timerSound)).labelsHidden().toggleStyle(.switch)
                    }
                }
                Toggle("Keep ringing until dismissed", isOn: settings.binding(Keys.timerRepeatAlert))
                Toggle("Open the island", isOn: settings.binding(Keys.timerOpenOnFinish))
            } header: {
                Text("When a timer ends")
            } footer: {
                Text("It rings every 3 seconds for up to 2 minutes, then waits quietly in the island until you dismiss it. Without repeating it rings once and the alert closes after 10 seconds. Haptics follow Island › Haptic feedback.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .disabled(!enabled)
        }
        .formStyle(.grouped)
        .navigationTitle("Timer")
    }
}

/// The quick presets: one removable chip per preset, a minutes
/// field with Add, and Restore Defaults.
struct TimerPresetsEditor: View {
    let settings: SettingsStore
    @State private var draft = ""
    @State private var message: String?

    var body: some View {
        let presets = settings[Keys.timerPresets]
        VStack(alignment: .leading, spacing: 10) {
            if presets.minutes.isEmpty {
                Text("No quick presets: the menus offer Custom… only.")
                    .foregroundStyle(.secondary)
            } else {
                PresetChipFlow(spacing: 6) {
                    ForEach(presets.minutes, id: \.self) { minutes in
                        PresetChip(minutes: minutes) {
                            settings[Keys.timerPresets] = presets.removing(minutes)
                            message = nil
                        }
                    }
                }
            }
            HStack(spacing: 8) {
                TextField("Minutes", text: $draft, prompt: Text("Minutes"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)
                    .onSubmit(add)
                    .accessibilityLabel("Preset in minutes")
                Button("Add", action: add)
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || presets.minutes.count >= TimerQuickPresets.maximumCount)
                Spacer()
                Button("Restore Defaults") {
                    settings[Keys.timerPresets] = .standard
                    message = nil
                }
                .disabled(presets == .standard)
            }
            if let message {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(Brand.ember)
            }
        }
        .padding(.vertical, 2)
    }

    private func add() {
        switch settings[Keys.timerPresets].adding(draft) {
        case .added(let presets):
            settings[Keys.timerPresets] = presets
            draft = ""
            message = nil
        case let other:
            message = TimerQuickPresets.message(for: other)
        }
    }
}

private struct PresetChip: View {
    let minutes: Int
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(minutes == 1 ? "1 minute" : "\(minutes) min")
                .monospacedDigit()
            Button(action: remove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(minutes == 1 ? "Remove 1 minute" : "Remove \(minutes) minutes")
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.secondary.opacity(0.14)))
    }
}

/// Lays chips out in rows, wrapping at the available width.
private struct PresetChipFlow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map { $0.width }.max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + CGFloat(max(0, rows.count - 1)) * spacing
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: .unspecified)
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = rows[rows.count - 1].indices.isEmpty ? size.width : rows[rows.count - 1].width + spacing + size.width
            if needed > width, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows.filter { !$0.indices.isEmpty }
    }
}
