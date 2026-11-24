import LintelCore
import SwiftUI

/// Island outline: a notch silhouette flush with the screen top (concave circular "ears" where it
/// meets the top edge, rounded bottom corners), or a rounded capsule/card for the pill. Radii were
/// fitted to the design's screenshots: ears 8 pt compact / 20 pt expanded, bottom corners 12 / 32 pt.
struct IslandOutline: Shape {
    var bottomRadius: CGFloat
    var earRadius: CGFloat
    var topRadius: CGFloat
    /// When false (stroke only), the notch silhouette's edge along the screen top is left open.
    var closedTop = true

    var animatableData: AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(bottomRadius, AnimatablePair(earRadius, topRadius)) }
        set {
            bottomRadius = newValue.first
            earRadius = newValue.second.first
            topRadius = newValue.second.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        guard w > 0, h > 0 else { return Path() }
        var path = Path()
        if topRadius > 0.01 {
            // Pill / card: rounded on all four corners.
            let tr = min(topRadius, w / 2, h / 2)
            let br = min(bottomRadius, w / 2, h / 2)
            path.move(to: CGPoint(x: tr, y: 0))
            path.addLine(to: CGPoint(x: w - tr, y: 0))
            path.addArc(tangent1End: CGPoint(x: w, y: 0), tangent2End: CGPoint(x: w, y: tr), radius: tr)
            path.addLine(to: CGPoint(x: w, y: h - br))
            path.addArc(tangent1End: CGPoint(x: w, y: h), tangent2End: CGPoint(x: w - br, y: h), radius: br)
            path.addLine(to: CGPoint(x: br, y: h))
            path.addArc(tangent1End: CGPoint(x: 0, y: h), tangent2End: CGPoint(x: 0, y: h - br), radius: br)
            path.addLine(to: CGPoint(x: 0, y: tr))
            path.addArc(tangent1End: CGPoint(x: 0, y: 0), tangent2End: CGPoint(x: tr, y: 0), radius: tr)
            path.closeSubpath()
            return path
        }
        // Ears: concave quarter circles joining the screen's top edge to the body's sides.
        let ear = min(earRadius, w / 4, h / 2)
        let r = max(0, min(bottomRadius, (w - 2 * ear) / 2, h - ear))
        path.move(to: CGPoint(x: 0, y: 0))
        if ear > 0.01 {
            path.addArc(tangent1End: CGPoint(x: ear, y: 0), tangent2End: CGPoint(x: ear, y: ear), radius: ear)
        }
        path.addLine(to: CGPoint(x: ear, y: h - r))
        path.addArc(tangent1End: CGPoint(x: ear, y: h), tangent2End: CGPoint(x: ear + r, y: h), radius: r)
        path.addLine(to: CGPoint(x: w - ear - r, y: h))
        path.addArc(tangent1End: CGPoint(x: w - ear, y: h), tangent2End: CGPoint(x: w - ear, y: h - r), radius: r)
        path.addLine(to: CGPoint(x: w - ear, y: ear))
        if ear > 0.01 {
            path.addArc(tangent1End: CGPoint(x: w - ear, y: 0), tangent2End: CGPoint(x: w, y: 0), radius: ear)
        } else {
            path.addLine(to: CGPoint(x: w, y: 0))
        }
        if closedTop { path.closeSubpath() }
        return path
    }
}

extension EnvironmentValues {
    /// Whether the island content around this view can be seen:
    /// false while the island is hidden (Mission Control, gaming), while the displays sleep or the
    /// session is locked, for the compact content behind the open card and for the card's content
    /// while it's closed. Repeating work that only matters to the eye pauses meanwhile: the
    /// waveform's bars rest, timer, calendar and clock ticks stop.
    @Entry var islandOnScreen = true
}

/// Re-renders at every minute while the island content can be seen (`islandOnScreen`); otherwise
/// renders once and catches up when it can be seen again.
struct MinuteTicks<Content: View>: View {
    @ViewBuilder let content: (Date) -> Content
    @Environment(\.islandOnScreen) private var onScreen

    var body: some View {
        if onScreen {
            TimelineView(.everyMinute) { context in content(context.date) }
        } else {
            content(Date())
        }
    }
}

/// Root of the content panel: a 624×320 transparent canvas with the island at the top centre.
struct IslandView: View {
    let model: IslandModel
    let hub: ActivityHub

    var body: some View {
        let size = model.drawnSize
        let outline = IslandOutline(bottomRadius: model.bottomCornerRadius, earRadius: model.earRadius,
                                    topRadius: model.topCornerRadius)
        let expanded = model.phase == .expanded
        VStack(spacing: 0) {
            outline
                .fill(Color.black)
                .overlay(alignment: .top) {
                    let shown = model.compactContentVisible && !expanded && !model.contentTucked
                    CompactContentView(presentation: model.displayed, hub: hub, base: model.baseSize,
                                       size: size, edgeInset: model.plan.shape == .pill ? 4 : IslandMetrics.earRadius)
                        .opacity(shown ? 1 : 0)
                        .blur(radius: shown ? 0 : IslandTiming.contentBlurRadius)
                        .environment(\.islandOnScreen, model.onScreen && !model.compactSuspended)
                }
                .overlay(alignment: .top) {
                    let shown = model.contentVisible && !model.contentTucked
                    expandedLayer
                        .opacity(shown ? 1 : 0)
                        .blur(radius: shown ? 0 : IslandTiming.contentBlurRadius)
                        .environment(\.islandOnScreen, model.onScreen && expanded)
                }
                .clipShape(outline)
                .overlay {
                    if model.showsOutline && !model.contentTucked {
                        IslandOutline(bottomRadius: model.bottomCornerRadius, earRadius: model.earRadius,
                                      topRadius: model.topCornerRadius, closedTop: false)
                            .stroke(.white.opacity(0.18), lineWidth: 1)
                    }
                }
                .frame(width: size.width, height: size.height)
                .shadow(color: .black.opacity(expanded && !model.tucked ? 0.32 : 0), radius: 16, x: 0, y: 6)
                .offset(x: model.stretch.width)
                .opacity(model.isVisible ? 1 : 0)
                .padding(.top, model.plan.topInset)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Lintel island")
                .accessibilityValue(accessibilityValue)
            Spacer(minLength: 0)
        }
        .frame(width: IslandMetrics.canvasSize.width, height: IslandMetrics.canvasSize.height, alignment: .top)
    }

    /// Expanded content laid out at the final card size, with the notification band on top.
    private var expandedLayer: some View {
        let card = model.expandedBodySize
        return VStack(spacing: 0) {
            if let kind = model.expandedNotification {
                NotificationBand(kind: kind, hub: hub, base: model.baseSize, width: card.width,
                                 edgeInset: model.plan.shape == .pill ? 4 : IslandMetrics.earRadius)
                    .frame(width: card.width, height: model.bandHeight)
            }
            ExpandedContentView(content: model.expandedContent, hub: hub, size: card, bandHeight: model.bandHeight,
                                ruler: model.timerRuler)
        }
        .frame(width: card.width, alignment: .top)
    }

    /// What VoiceOver reads after "Lintel island".
    private var accessibilityValue: String {
        if model.phase == .expanded { return "open, \(model.expandedContent.spokenName)" }
        return model.displayed.spokenName ?? "closed"
    }
}
