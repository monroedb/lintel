import LintelCore
import SwiftUI

extension Brand {
    /// The ruler's selected tick and label: light copper #FFC9A0.
    static let copperLight = Color(red: 0xFF / 255, green: 0xC9 / 255, blue: 0xA0 / 255)
}

/// Positions of the Ruler picker, in the timer page's coordinates: the page
/// starts `TimerCardLayout.contentTop` (38 pt) below the card's top, so y = card y − 38.
enum TimerRulerLayout {
    static let pageTop = TimerCardLayout.contentTop
    static let labelCenter: CGFloat = 46 - pageTop
    static let tickTop: CGFloat = 56 - pageTop
    static let tickHeight: CGFloat = 24
    static let tickWidth: CGFloat = 2
    static let markerApex: CGFloat = 84 - pageTop
    static let marker = CGSize(width: 10, height: 7)
    /// The drag area: labels, ticks and marker (card y 38 … 92).
    static let stripHeight: CGFloat = 92 - pageTop
    static let side: CGFloat = 18
    static let startTop: CGFloat = 99 - pageTop
    static let startHeight: CGFloat = 28
    static let presetsTop: CGFloat = 135 - pageTop
    static let presetHeight: CGFloat = 20
    static let digitsCenter: CGFloat = 127 - pageTop
    static let digitsSize: CGFloat = 36
    static let labelSize: CGFloat = 10.5
    static let dimTick = 0.32
    static let dimLabel = 0.45
}

/// The open island's timer page without a timer, Ruler style: the ruler, the marker, Start Timer,
/// the selected duration and the quick presets.
struct TimerRulerPage: View {
    let timer: TimerCenter
    let ruler: TimerRulerModel
    let width: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            TimerRulerStrip(ruler: ruler)
                .frame(width: width, height: TimerRulerLayout.stripHeight)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .local)
                        .onChanged { ruler.drag(translation: $0.translation.width) }
                        .onEnded { _ in ruler.dragEnded() }
                )
                .accessibilityElement()
                .accessibilityLabel("Timer duration")
                .accessibilityValue(ruler.selected == 1 ? "1 minute" : "\(ruler.selected) minutes")
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: ruler.key(.step(1))
                    case .decrement: ruler.key(.step(-1))
                    @unknown default: break
                    }
                }
            RulerMarker()
                .fill(Brand.copper)
                .overlay { RulerMarker().stroke(Brand.copper, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round)) }
                .frame(width: TimerRulerLayout.marker.width, height: TimerRulerLayout.marker.height)
                .offset(x: (width - TimerRulerLayout.marker.width) / 2, y: TimerRulerLayout.markerApex)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            TimerStartPill(ruler: ruler)
                .offset(x: TimerRulerLayout.side, y: TimerRulerLayout.startTop)
            TimerPresetPills(timer: timer, ruler: ruler)
                .offset(x: TimerRulerLayout.side, y: TimerRulerLayout.presetsTop)
            TimerRulerDigits(ruler: ruler)
                .frame(width: width - 2 * TimerRulerLayout.side, height: 46, alignment: .trailing)
                .offset(x: TimerRulerLayout.side, y: TimerRulerLayout.digitsCenter - 23)
                .allowsHitTesting(false)
        }
        .frame(width: width, alignment: .topLeading)
        .onAppear { ruler.reset(to: timer.rulerMinutes) }
    }
}

/// Labels and ticks, drawn for the visible minutes only, with the edge fade.
struct TimerRulerStrip: View {
    let ruler: TimerRulerModel

    var body: some View {
        // Read here so SwiftUI follows them (the canvas closure runs outside the body).
        let position = ruler.position
        let selected = ruler.selected
        let scale = ruler.scale
        Canvas { context, _ in
            let labelFont = Font.system(size: TimerRulerLayout.labelSize, weight: .semibold, design: .rounded).monospacedDigit()
            for minute in scale.visibleMinutes(position: position) {
                let x = scale.x(of: minute, position: position)
                let fade = scale.edgeOpacity(x: x)
                guard fade > 0 else { continue }
                let tone = scale.tone(of: minute, selected: selected)
                let tick: Color
                switch tone {
                case .selected: tick = Brand.copperLight
                case .passed: tick = Brand.copper
                case .ahead: tick = Brand.copper.opacity(TimerRulerLayout.dimTick)
                }
                let rect = CGRect(x: x - TimerRulerLayout.tickWidth / 2, y: TimerRulerLayout.tickTop,
                                  width: TimerRulerLayout.tickWidth, height: TimerRulerLayout.tickHeight)
                var layer = context
                layer.opacity = fade
                layer.fill(Path(roundedRect: rect, cornerRadius: TimerRulerLayout.tickWidth / 2), with: .color(tick))
                guard scale.isLabelled(minute) else { continue }
                let label: Color = minute == selected ? Brand.copperLight
                    : minute < selected ? Brand.copper : Brand.copper.opacity(TimerRulerLayout.dimLabel)
                layer.draw(Text("\(minute)").font(labelFont).foregroundColor(label),
                           at: CGPoint(x: x, y: TimerRulerLayout.labelCenter), anchor: .center)
            }
        }
    }
}

/// The copper triangle under the ruler's centre, pointing up.
struct RulerMarker: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// The orange-tinted "Start Timer" pill.
struct TimerStartPill: View {
    let ruler: TimerRulerModel
    @State private var hovered = false

    var body: some View {
        Button { ruler.startTimer() } label: {
            Text("Start Timer")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Brand.copper)
                .padding(.horizontal, 14)
                .frame(height: TimerRulerLayout.startHeight)
                .background(Capsule().fill(Brand.copper.opacity(hovered ? 0.30 : 0.22)))
                .contentShape(Capsule())
        }
        .buttonStyle(PressScaleStyle())
        .onHover { hovered = $0 }
        .accessibilityLabel("Start Timer")
        .accessibilityValue(ruler.selected == 1 ? "1 minute" : "\(ruler.selected) minutes")
    }
}

/// The selected duration in large copper digits (`15:00`, `1:18:00`), following the ruler live.
struct TimerRulerDigits: View {
    let ruler: TimerRulerModel

    var body: some View {
        Text(ruler.scale.clock(ruler.selected))
            .font(.system(size: TimerRulerLayout.digitsSize, weight: .regular, design: .rounded).monospacedDigit())
            .foregroundStyle(Brand.copper)
            .lineLimit(1)
            .accessibilityHidden(true)
    }
}

/// One small pill per quick preset, then "min"; a click starts that preset.
struct TimerPresetPills: View {
    let timer: TimerCenter
    let ruler: TimerRulerModel

    var body: some View {
        if !timer.presets.isEmpty {
            HStack(spacing: 5) {
                ForEach(timer.presets, id: \.self) { minutes in
                    TimerPresetPill(minutes: minutes) { ruler.startPreset(minutes) }
                }
                Text("min")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
                    .padding(.leading, 1)
                    .accessibilityHidden(true)
            }
        }
    }
}

private struct TimerPresetPill: View {
    let minutes: Int
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Text("\(minutes)")
                .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 8)
                .frame(minWidth: 26, minHeight: TimerRulerLayout.presetHeight, maxHeight: TimerRulerLayout.presetHeight)
                .background(Capsule().fill(.white.opacity(hovered ? 0.18 : 0.10)))
                .contentShape(Capsule())
        }
        .buttonStyle(PressScaleStyle())
        .onHover { hovered = $0 }
        .accessibilityLabel(minutes == 1 ? "Start a 1 minute timer" : "Start a \(minutes) minute timer")
    }
}
