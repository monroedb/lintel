import AppKit
import LintelCore
import SwiftUI

// MARK: - Payloads

/// What a battery, audio-device or Focus alert shows (carried in `NotificationPayload.detail`).
enum SystemAlertDetail: Equatable {
    case battery(BatteryAlertContent)
    case device(DeviceAlertContent)
    case focus(FocusAlertContent)

    /// The payload's detail, or one derived from the plain payload (demo `notify` commands).
    static func resolve(_ kind: NotificationKind, _ payload: NotificationPayload) -> SystemAlertDetail {
        if let detail = payload.detail { return detail }
        let level = payload.value.flatMap { Int($0.filter(\.isNumber)) }
        switch kind {
        case .deviceConnected, .deviceLowBattery:
            let device = ConnectedAudioDevice(id: "demo", name: "Headphones", model: .headphones,
                                              batteries: level.map { DeviceBatteryLevels(single: $0) })
            return .device(DeviceAlertContent(device: device, low: kind == .deviceLowBattery, style: .symbol, lowThreshold: 20))
        case .focus:
            return .focus(FocusAlertContent(mode: FocusModeCatalog.generic, on: payload.value != "Off"))
        default:
            let alert: BatteryAlert = kind == .lowBattery ? .lowBattery : kind == .lowPowerMode ? .lowPowerMode : .charging
            let snapshot = PowerSnapshot(level: level ?? (alert == .lowBattery ? 10 : 80), externalPower: alert == .charging,
                                         charging: alert == .charging, lowPowerMode: alert == .lowPowerMode)
            return .battery(BatteryAlertContent(alert: alert, snapshot: snapshot))
        }
    }
}

struct BatteryAlertContent: Equatable {
    var alert: BatteryAlert
    var snapshot: PowerSnapshot
    var hideLabel = false
    var hidePercentage = false

    var label: String {
        switch alert {
        case .charging:
            if snapshot.charging { return "Charging" }
            return snapshot.charged ? "Charged" : "On Power"
        case .lowBattery: return "Low Battery"
        case .lowPowerMode: return "Low Power"
        }
    }

    /// Charging green, low-battery red, Low Power yellow (system palette, dark variants).
    var tint: Color {
        switch alert {
        case .charging: return Color(rgb: SRGBColor(hex: 0x30D158))
        case .lowBattery: return Color(rgb: SRGBColor(hex: 0xFF453A))
        case .lowPowerMode: return Color(rgb: SRGBColor(hex: 0xFFD60A))
        }
    }

    var remaining: String? { AlertFormat.duration(minutes: snapshot.minutesRemaining) }
}

struct DeviceAlertContent: Equatable {
    var device: ConnectedAudioDevice
    /// The low-battery warning rather than the connection alert.
    var low: Bool
    var style: DeviceVisualStyle
    var lowThreshold: Double
}

struct FocusAlertContent: Equatable {
    var mode: FocusModeDescriptor
    var on: Bool
    var hideLabel = false

    /// The mode's tint when turning on; grey when turning off.
    var color: Color { Color(rgb: on ? mode.tint : FocusModeCatalog.offGrey) }
}

extension NotificationPayload {
    static func battery(_ content: BatteryAlertContent) -> NotificationPayload {
        NotificationPayload(symbol: "battery.100percent", label: content.label, value: AlertFormat.percent(content.snapshot.level),
                            detail: .battery(content))
    }

    static func device(_ content: DeviceAlertContent) -> NotificationPayload {
        NotificationPayload(symbol: content.device.model.symbolCandidates.last ?? "headphones", label: content.device.name,
                            value: content.device.batteries?.listeningLevel.map(AlertFormat.percent), detail: .device(content))
    }

    static func focus(_ content: FocusAlertContent) -> NotificationPayload {
        NotificationPayload(symbol: content.mode.symbol, label: content.mode.name, value: content.on ? "On" : "Off",
                            detail: .focus(content))
    }
}

extension Color {
    init(rgb: SRGBColor) { self.init(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue, opacity: 1) }
}

/// Resolves the first SF Symbol name this macOS has (names differ between versions).
@MainActor
enum SymbolLookup {
    private static var cache: [[String]: String] = [:]

    static func first(_ candidates: [String]) -> String {
        if let hit = cache[candidates] { return hit }
        let found = candidates.first { NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil } ?? "questionmark"
        cache[candidates] = found
        return found
    }
}

// MARK: - Compact slots

/// Type scale fitted to the design's Focus alert (2x screenshots): moon 13.5–14 pt ink → 14 pt symbol;
/// "On" 15.5 pt and "Off" 17 pt ink, 9 pt cap height → 12 pt semibold.
private enum AlertType {
    static let symbol: CGFloat = 14
    static let text = Font.system(size: 12, weight: .semibold)
    static let secondary = Font.system(size: 11, weight: .semibold)
    /// The design's "On"/"Off" ends 10 pt inside the body edge.
    static let focusTextInset: CGFloat = 1.5
}

/// Leading slot of a system alert.
struct SystemAlertLeading: View {
    let kind: NotificationKind
    let payload: NotificationPayload
    let padding: CGFloat

    var body: some View {
        switch SystemAlertDetail.resolve(kind, payload) {
        case .battery(let content):
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    BatteryGlyph(level: content.snapshot.level, tint: content.tint,
                                 charging: content.alert == .charging && content.snapshot.charging)
                    if !content.hideLabel {
                        Text(content.label).font(AlertType.text).foregroundStyle(.white).fixedSize()
                    }
                }
                BatteryGlyph(level: content.snapshot.level, tint: content.tint,
                             charging: content.alert == .charging && content.snapshot.charging)
            }
            .padding(.leading, padding)
        case .device(let content):
            DeviceVisual(model: content.device.model, style: content.style, low: content.low)
                .padding(.leading, padding - 4)
        case .focus(let content):
            Image(systemName: SymbolLookup.first([content.mode.symbol, "moon.fill"]))
                .font(.system(size: AlertType.symbol, weight: .semibold))
                .foregroundStyle(content.color)
                .padding(.leading, padding)
        }
    }
}

/// Trailing slot of a system alert.
struct SystemAlertTrailing: View {
    let kind: NotificationKind
    let payload: NotificationPayload
    let padding: CGFloat

    var body: some View {
        switch SystemAlertDetail.resolve(kind, payload) {
        case .battery(let content):
            if !content.hidePercentage {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) {
                        if let remaining = content.remaining {
                            Text(remaining).font(AlertType.secondary).foregroundStyle(.white.opacity(0.5)).fixedSize()
                        }
                        percent(content)
                    }
                    percent(content)
                }
                .padding(.trailing, padding)
            }
        case .device(let content):
            DeviceLevels(content: content)
                .padding(.trailing, padding)
        case .focus(let content):
            if !content.hideLabel {
                Text(content.on ? "On" : "Off")
                    .font(AlertType.text)
                    .foregroundStyle(content.color)
                    .fixedSize()
                    .padding(.trailing, padding + AlertType.focusTextInset)
            }
        }
    }

    private func percent(_ content: BatteryAlertContent) -> some View {
        Text(AlertFormat.percent(content.snapshot.level))
            .font(AlertType.text.monospacedDigit())
            .foregroundStyle(content.tint)
            .fixedSize()
    }
}

// MARK: - Battery

/// A battery outline filled to the level, with a bolt while charging (Lintel's own glyph).
struct BatteryGlyph: View {
    let level: Int
    let tint: Color
    let charging: Bool

    var body: some View {
        HStack(spacing: 1) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3.2, style: .continuous)
                    .stroke(.white.opacity(0.42), lineWidth: 1.1)
                RoundedRectangle(cornerRadius: 1.7, style: .continuous)
                    .fill(tint)
                    .frame(width: max(2.5, 16.4 * CGFloat(min(100, max(0, level))) / 100))
                    .padding(2)
            }
            .frame(width: 21, height: 11)
            .overlay {
                if charging {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 8, weight: .black))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.6), radius: 0.5)
                }
            }
            RoundedRectangle(cornerRadius: 0.8)
                .fill(.white.opacity(0.42))
                .frame(width: 1.6, height: 4)
        }
        .accessibilityLabel("Battery \(level) percent")
    }
}

// MARK: - Audio devices

/// The device in the leading slot (40 pt). "3D" is Lintel's own animated rendition
/// (a lit symbol turning slowly in perspective); "Symbol" is the flat SF Symbol.
struct DeviceVisual: View {
    let model: AudioDeviceModel
    let style: DeviceVisualStyle
    let low: Bool

    var body: some View {
        let symbol = SymbolLookup.first(model.symbolCandidates)
        Group {
            if style == .rendered {
                RenderedDeviceGlyph(symbol: symbol)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 40, height: 26)
        .overlay(alignment: .bottomTrailing) {
            if low {
                Circle()
                    .fill(Color(rgb: SRGBColor(hex: 0xFF453A)))
                    .frame(width: 7, height: 7)
                    .overlay(Circle().stroke(.black, lineWidth: 1.5))
                    .offset(x: -3, y: -1)
            }
        }
        .accessibilityLabel(model.displayName)
    }
}

/// A turntable-like rendition: the symbol shaded top to bottom, a highlight sweeping across, and a
/// slow swing about the vertical axis in perspective.
struct RenderedDeviceGlyph: View {
    let symbol: String
    @State private var start = Date()
    /// The turntable runs at the display's frame rate: only while the island can be seen.
    @Environment(\.islandOnScreen) private var onScreen

    var body: some View {
        TimelineView(.animation(paused: !onScreen)) { context in
            let t = context.date.timeIntervalSince(start)
            let phase = t * 2 * .pi / 3.6
            let angle = sin(phase) * 34
            let sweep = CGFloat((sin(phase + .pi / 2) + 1) / 2)
            let glyph = Image(systemName: symbol).font(.system(size: 19, weight: .regular))
            glyph
                .foregroundStyle(LinearGradient(colors: [.white, Color(white: 0.6)], startPoint: .top, endPoint: .bottom))
                .overlay {
                    LinearGradient(stops: [.init(color: .clear, location: max(0, sweep - 0.25)),
                                           .init(color: .white.opacity(0.95), location: sweep),
                                           .init(color: .clear, location: min(1, sweep + 0.25))],
                                   startPoint: .leading, endPoint: .trailing)
                        .mask(glyph)
                        .blendMode(.plusLighter)
                }
                .rotation3DEffect(.degrees(angle), axis: (x: 0, y: 1, z: 0), perspective: 0.55)
                .shadow(color: .white.opacity(0.18), radius: 2.5)
        }
    }
}

/// Battery levels in the trailing slot: left / right / case chips, a single level, or the device
/// name while levels are unknown (they need Bluetooth access).
struct DeviceLevels: View {
    let content: DeviceAlertContent

    var body: some View {
        let levels = content.device.batteries
        if let levels, !levels.isEmpty {
            if levels.left == nil && levels.right == nil {
                // Headphones and speakers report one battery.
                single(levels.single ?? levels.chargingCase ?? 0)
            } else {
                ViewThatFits(in: .horizontal) {
                    chips(levels, includeCase: !content.low)
                    chips(levels, includeCase: false)
                    single(levels.listeningLevel ?? 0)
                }
            }
        } else {
            Text(content.device.name)
                .font(AlertType.text)
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private func color(_ value: Int) -> Color {
        Double(value) <= content.lowThreshold ? Color(rgb: SRGBColor(hex: 0xFF453A)) : .white
    }

    @ViewBuilder private func chips(_ levels: DeviceBatteryLevels, includeCase: Bool) -> some View {
        HStack(spacing: 8) {
            if let left = levels.left { chip(Text("L").font(.system(size: 9, weight: .heavy)), left) }
            if let right = levels.right { chip(Text("R").font(.system(size: 9, weight: .heavy)), right) }
            if includeCase, let chargingCase = levels.chargingCase {
                chip(Image(systemName: SymbolLookup.first(content.device.model.caseSymbolCandidates))
                        .font(.system(size: 9, weight: .semibold)), chargingCase)
            }
        }
        .fixedSize()
    }

    private func chip<Label: View>(_ label: Label, _ value: Int) -> some View {
        HStack(spacing: 2.5) {
            label.foregroundStyle(.white.opacity(0.5))
            Text("\(value)")
                .font(AlertType.text.monospacedDigit())
                .foregroundStyle(color(value))
        }
    }

    private func single(_ value: Int) -> some View {
        HStack(spacing: 5) {
            BatteryGlyph(level: value, tint: color(value) == .white ? Color(rgb: SRGBColor(hex: 0x30D158)) : color(value),
                         charging: false)
            Text(AlertFormat.percent(value))
                .font(AlertType.text.monospacedDigit())
                .foregroundStyle(color(value))
        }
        .fixedSize()
    }
}

// MARK: - Waveform replacement

/// The compact Now Playing waveform, or the Focus symbol while a Focus is on and "Replace waveform
/// during focus" applies.
struct FocusAwareWaveform: View {
    let hub: ActivityHub

    var body: some View {
        // Replaces the compact waveform; with "Disable compact waveform" there is nothing to replace.
        if let mode = hub.focusGlyphForWaveform, hub.nowPlaying.appearance.compactWaveform {
            let size = MediaWaveform.Style.compact.size
            Image(systemName: SymbolLookup.first([mode.symbol, "moon.fill"]))
                .font(.system(size: AlertType.symbol, weight: .semibold))
                .foregroundStyle(Color(rgb: mode.tint))
                .frame(width: size.width + 2, height: size.height + 2)
                .accessibilityLabel("\(mode.name) on")
        } else {
            NowPlayingCompactWaveform(center: hub.nowPlaying)
        }
    }
}
