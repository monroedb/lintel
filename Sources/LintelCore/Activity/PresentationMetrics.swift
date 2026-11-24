import CoreGraphics

/// Island sizes per presentation, from the design screenshots measured consistently on a
/// 185 × 33.5 pt notch. "Outer" widths are taken along the screen's top edge (ear to ear), "body"
/// widths below the ears:
///
/// | state | top row (2x) | body | Lintel drawn (body + ears) |
/// |---|---|---|---|
/// | live activity, alert (Focus) | 271–272 | 260 | 276 × 34.5 |
/// | HUD (volume, brightness) | 381 | 369 | 385 × 34.5 |
/// | expanded (media, calendar, both) | ≥ 380 | 345 | 385 × 175 |
///
/// The ears are concave quarter circles (8 pt compact, 20 pt expanded), so the true top-edge width is
/// body + 2 × ear; the first pixel row of a screenshot shows a little less.
public enum PresentationMetrics {
    /// Extra width on each side of the notch for each compact layout.
    public static let liveSlotWidth: CGFloat = 45.5
    public static let hudSlotWidth: CGFloat = 100
    public static let alertSlotWidth: CGFloat = 45.5
    public static let peekSlotWidth: CGFloat = 80
    public static let contentHeightBoost: CGFloat = 1
    public static let peekExtraHeight: CGFloat = 40

    /// Expanded card body (between the ears) and the concave ears that join it to the screen edge.
    public static let expandedBodyWidth: CGFloat = 345
    public static let expandedEarRadius: CGFloat = 20

    public static func compactSize(for presentation: CompactPresentation, base: CGSize) -> CGSize {
        func widened(_ slot: CGFloat, extraHeight: CGFloat = contentHeightBoost) -> CGSize {
            CGSize(width: base.width + 2 * slot, height: base.height + extraHeight)
        }
        switch presentation {
        case .idle: return base
        case .lock: return widened(alertSlotWidth)
        case .live(let kinds) where kinds.contains(.timer): return widened(timerSlotWidth)
        case .live: return widened(liveSlotWidth)
        case .notification(let kind): return widened(notificationSlotWidth(for: kind))
        case .peek: return widened(peekSlotWidth, extraHeight: peekExtraHeight)
        }
    }

    /// Body of the expanded card (content area width × full height).
    public static func expandedBodySize(for content: ExpandedContent) -> CGSize {
        CGSize(width: expandedBodyWidth, height: content == .calendar ? 175.5 : 175)
    }

    /// Drawn size of the expanded card: the body plus the ears on notch shapes (pills have none).
    public static func expandedSize(for content: ExpandedContent, withEars: Bool = true) -> CGSize {
        let body = expandedBodySize(for: content)
        return CGSize(width: body.width + (withEars ? 2 * expandedEarRadius : 0), height: body.height)
    }
}

/// Timings of compact-presentation swaps (measured volume HUD:
/// current activity contracts ≈ 0–250 ms, new content grows ≈ 370–800 ms, hold, contract ≈ 280 ms,
/// previous activity grows back).
public enum SwapTiming {
    public static let debounce: Double = 0.04
    public static let contractResponse: Double = 0.26
    public static let contractDamping: Double = 1.0
    /// Delay from the start of the contraction to the start of the growth.
    public static let growDelay: Double = 0.30
    public static let growResponse: Double = 0.42
    public static let growDamping: Double = 0.74
    public static let contentFadeOut: Double = 0.12
    public static let contentFadeInDelay: Double = 0.12
    public static let contentFadeIn: Double = 0.15
}
