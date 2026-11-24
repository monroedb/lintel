import AppKit
import LintelCore
import SwiftUI

/// Leading side of a HUD: glyph and label (speaker or sun glyph, "Sound" / "Display" or the
/// output device). Layout fitted to the reference screenshots: glyph centred in an 18 pt frame,
/// label 6.5 pt after it, 12 pt medium.
struct HUDLeadingView: View {
    let kind: HUDKind
    let payload: NotificationPayload
    let state: HUDPresentationState
    /// Width of the slot beside the notch, and the padding before the glyph.
    let slot: CGFloat
    let leadingPadding: CGFloat

    static let glyphFrame: CGFloat = 18
    static let labelGap: CGFloat = 6.5

    var body: some View {
        let reading = state.reading(for: kind, matching: payload)
        let appearance = state.appearance(for: kind)
        let symbol = reading?.symbol ?? payload.symbol
        let label = reading?.label ?? payload.label
        // The label needs about 90 pt; narrower slots (the open card's strip) show the glyph only.
        let labelRoom = slot - leadingPadding - Self.glyphFrame - Self.labelGap - 4
        let showsLabel = !appearance.hideLabel && slot >= HUDBarMetrics.minimumSlotForLabel && labelRoom > 20
        HStack(spacing: Self.labelGap) {
            HUDGlyph(symbol: symbol)
                .frame(width: Self.glyphFrame)
            if showsLabel {
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                    .truncationMode(.tail)
                    .frame(maxWidth: labelRoom, alignment: .leading)
            }
        }
        .foregroundStyle(.white)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
    }
}

/// HUD glyph. The muted speaker keeps a white body with a dimmer slash, and the sun is drawn a
/// point smaller than the speakers — both as in the reference screenshots.
struct HUDGlyph: View {
    let symbol: String

    var body: some View {
        if symbol == HUDGlyphs.muted {
            Image(systemName: symbol)
                .symbolRenderingMode(.palette)
                .foregroundStyle(Color(white: 0.61), Color.white)
                .font(.system(size: 13, weight: .semibold))
        } else {
            Image(systemName: symbol)
                .font(.system(size: symbol == HUDGlyphs.sun ? 12 : 13, weight: .semibold))
        }
    }
}

/// Trailing side of a HUD: the level bar, and the percentage when switched on.
struct HUDTrailingView: View {
    let kind: HUDKind
    let payload: NotificationPayload
    let state: HUDPresentationState
    /// Width of the slot beside the notch, and the padding after the bar.
    let slot: CGFloat
    let trailingPadding: CGFloat

    var body: some View {
        let reading = state.reading(for: kind, matching: payload)
        let appearance = state.appearance(for: kind)
        let level = reading?.shownLevel ?? payload.level ?? 0
        let percentRoom = appearance.showPercentage ? HUDBarMetrics.percentageWidth + HUDBarMetrics.percentageGap : 0
        let preferred = appearance.showPercentage ? HUDBarMetrics.trackWidthWithPercentage : HUDBarMetrics.trackWidth
        // Keep clear of the notch in narrow slots (the open card's strip).
        let barWidth = max(24, min(preferred, slot - trailingPadding - percentRoom - 4))
        HStack(spacing: HUDBarMetrics.percentageGap) {
            HUDLevelBar(kind: kind, level: level, appearance: appearance, overshoot: state.overshoot[kind])
                .frame(width: barWidth, height: HUDBarMetrics.trackHeight)
            if appearance.showPercentage {
                Text("\(HUDBarMetrics.percent(level))")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.92))
                    .contentTransition(.numericText(value: level))
                    .animation(.snappy(duration: 0.2), value: level)
                    .frame(width: HUDBarMetrics.percentageWidth, alignment: .trailing)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(HUDBarMetrics.percent(level)) percent")
    }
}

/// The level bar: a grey track and a fill in the chosen style, animated at the chosen speed, with a
/// rubber-band stretch when a press pushes past a bound (≈ 1 s).
struct HUDLevelBar: View {
    let kind: HUDKind
    let level: Double
    let appearance: HUDAppearance
    let overshoot: HUDPresentationState.Overshoot?

    /// Track grey measured on the reference screenshots (#363538 on black).
    static let trackColor = Color(white: 0.21)

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width, height = geometry.size.height
            let fill = HUDBarMetrics.fillWidth(level: level, trackWidth: width, trackHeight: height)
            ZStack(alignment: .leading) {
                Capsule().fill(Self.trackColor)
                fillView(trackWidth: width, height: height)
                    .mask(alignment: .leading) {
                        Capsule().frame(width: fill, height: height)
                    }
                    .shadow(color: glowColor.opacity(fill > 0 ? glowOpacity : 0), radius: glowRadius)
            }
        }
        .animation(barAnimation, value: level)
        .keyframeAnimator(initialValue: 0.0, trigger: overshoot?.token ?? 0) { content, stretch in
            content.scaleEffect(x: 1 + stretch * HUDBarMetrics.overshootStretch / max(1, HUDBarMetrics.trackWidth),
                                y: 1 - stretch * 0.22,
                                anchor: overshoot?.edge == .minimum ? .trailing : .leading)
        } keyframes: { _ in
            KeyframeTrack {
                CubicKeyframe(1, duration: 0.12)
                SpringKeyframe(0, duration: HUDBarMetrics.overshootDuration - 0.12, spring: .init(response: 0.42, dampingRatio: 0.48))
            }
        }
    }

    private var barAnimation: Animation? {
        switch appearance.speed {
        case .smooth: return .spring(response: HUDBarSpeed.smooth.response, dampingFraction: 0.9)
        case .fast: return .spring(response: HUDBarSpeed.fast.response, dampingFraction: 0.92)
        case .instant: return nil
        }
    }

    @ViewBuilder
    private func fillView(trackWidth: CGFloat, height: CGFloat) -> some View {
        switch appearance.style {
        case .white:
            Capsule().fill(Color.white).frame(width: trackWidth, height: height)
        case .accent:
            Capsule().fill(Color(nsColor: .controlAccentColor)).frame(width: trackWidth, height: height)
        case .vivid:
            if kind == .volume {
                // Level meter: green, warming to yellow and orange towards the top of the range.
                LinearGradient(stops: [
                    .init(color: HUDColors.meterGreen, location: 0),
                    .init(color: HUDColors.meterGreen, location: 0.55),
                    .init(color: HUDColors.meterYellow, location: 0.75),
                    .init(color: HUDColors.meterOrange, location: 0.92),
                ], startPoint: .leading, endPoint: .trailing)
                .frame(width: trackWidth, height: height)
            } else {
                // Glow: brightening towards the fill's end, with a bright halo (shadow below).
                LinearGradient(colors: [.white.opacity(0.42), .white], startPoint: .leading, endPoint: .trailing)
                    .frame(width: trackWidth, height: height)
            }
        }
    }

    private var glowColor: Color {
        guard appearance.style == .vivid else { return .clear }
        if kind == .brightness { return .white }
        return level > 0.75 ? HUDColors.meterOrange : HUDColors.meterGreen
    }

    private var glowOpacity: Double { appearance.style == .vivid ? (kind == .brightness ? 0.9 : 0.7) : 0 }
    private var glowRadius: CGFloat { kind == .brightness ? 4 : 3 }
}

enum HUDColors {
    static let meterGreen = Color(red: 0.30, green: 0.84, blue: 0.47)
    static let meterYellow = Color(red: 0.98, green: 0.80, blue: 0.26)
    static let meterOrange = Color(red: 0.97, green: 0.52, blue: 0.20)
}
