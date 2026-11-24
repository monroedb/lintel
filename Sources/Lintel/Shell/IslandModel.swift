import CoreGraphics
import LintelCore
import Observation

/// Observable view state for one island.
@MainActor
@Observable
final class IslandModel {
    var plan: IslandPlan
    var phase: IslandPhase = .idle
    /// Expanded content visibility (blurs in after the shape grows, out before it shrinks).
    var contentVisible = false
    /// Compact content visibility (blurs out during swaps and while expanded).
    var compactContentVisible = true
    /// What the compact content shows.
    var displayed: CompactPresentation = .idle
    /// Whose size the compact shape has: leads `displayed` while growing, trails it while contracting.
    var shapePresentation: CompactPresentation = .idle
    /// What the expanded card shows.
    var expandedContent: ExpandedContent = .media
    /// Notification shown in a band at the top of the expanded card (the card grows so it never
    /// overlaps the expanded content).
    var expandedNotification: NotificationKind?
    /// Rubber-band offset while a swipe is in progress (+height = pulled down).
    var stretch: CGSize = .zero
    /// Contrast outline drawn around the island.
    var showsOutline = false
    /// Debug override: show an idle pill that would normally be hidden.
    var forceVisibleWhenIdle = false
    /// Tucked into the notch (or the pill) while Mission Control is shown: drawn at the plan's tuck
    /// size whatever the phase. Animated separately from
    /// `contentTucked` so the content fades faster than the shape shrinks.
    var tucked = false
    /// Content hidden while tucked.
    var contentTucked = false
    /// The timer page's Ruler picker on this island.
    let timerRuler = TimerRulerModel()
    /// The island can be seen: not hidden by a rule (Mission Control, gaming) and the displays
    /// awake and unlocked. Off screen, what only matters to the eye pauses (`islandOnScreen`).
    var onScreen = true
    /// The compact content has faded out behind the open card: its animations and ticks pause.
    var compactSuspended = false

    init(plan: IslandPlan) {
        self.plan = plan
    }

    var baseSize: CGSize { plan.compactSize }

    /// Size of the compact shape (no elevation, no stretch).
    var compactSize: CGSize { PresentationMetrics.compactSize(for: shapePresentation, base: baseSize) }

    var expandedSize: CGSize {
        var size = PresentationMetrics.expandedSize(for: expandedContent, withEars: plan.shape != .pill)
        if expandedNotification != nil { size.height += bandHeight }
        return size
    }

    /// Content area of the expanded card (between the ears).
    var expandedBodySize: CGSize { PresentationMetrics.expandedBodySize(for: expandedContent) }

    /// Height of the strip level with the notch (or the pill) that compact content lives in.
    var bandHeight: CGFloat { baseSize.height }

    /// Size the island is drawn at for a phase (without the swipe stretch).
    func size(for phase: IslandPhase) -> CGSize {
        switch phase {
        case .idle:
            return compactSize
        case .elevated:
            return CGSize(width: compactSize.width + IslandMetrics.elevationDelta.width,
                          height: compactSize.height + IslandMetrics.elevationDelta.height)
        case .expanded:
            return expandedSize
        }
    }

    var drawnSize: CGSize {
        if tucked { return plan.tuckSize }
        let size = size(for: phase)
        return CGSize(width: size.width, height: max(bandHeight * 0.6, size.height + stretch.height))
    }

    var isVisible: Bool {
        let resting = phase == .idle && shapePresentation == .idle && displayed == .idle
        return !(plan.hiddenWhenIdle && resting) || forceVisibleWhenIdle
    }

    var bottomCornerRadius: CGFloat {
        if tucked { return plan.shape == .pill ? drawnSize.height / 2 : IslandMetrics.compactCornerRadius }
        if phase == .expanded { return IslandMetrics.expandedCornerRadius }
        if plan.shape == .pill { return min(drawnSize.height / 2, IslandMetrics.expandedCornerRadius) }
        // Taller compact content (Quick Peek) gets rounder corners.
        let extra = max(0, drawnSize.height - bandHeight)
        return min(IslandMetrics.expandedCornerRadius, IslandMetrics.compactCornerRadius + extra * 0.3)
    }

    var earRadius: CGFloat {
        if tucked { return plan.shape == .pill ? 0 : IslandMetrics.earRadius }
        switch (plan.shape, phase) {
        case (.pill, _): return 0
        case (_, .expanded): return PresentationMetrics.expandedEarRadius
        case (_, .elevated): return IslandMetrics.elevatedEarRadius
        default: return IslandMetrics.earRadius
        }
    }

    /// Top corners for the pill (rounded); notch shapes are flush with the screen top.
    var topCornerRadius: CGFloat {
        guard plan.shape == .pill else { return 0 }
        if tucked { return drawnSize.height / 2 }
        return phase == .expanded ? IslandMetrics.expandedCornerRadius : min(drawnSize.height / 2, IslandMetrics.expandedCornerRadius)
    }

    /// Width of the area at the top centre that the hardware notch covers (0 on pills).
    var notchWidth: CGFloat { plan.shape == .pill ? 0 : baseSize.width }
}
