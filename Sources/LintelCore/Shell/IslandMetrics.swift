import CoreGraphics

/// Size and timing constants for the island, tuned by measurement.
public enum IslandMetrics {
    /// Fixed canvas every island state is drawn in, anchored top-centre.
    public static let canvasSize = CGSize(width: 624, height: 320)
    /// Hover "elevation": how much the compact shape inflates while the pointer is inside.
    public static let elevationDelta = CGSize(width: 24, height: 5.5)
    /// Bottom corner radii, fitted to the design's screenshots (compact 12, expanded ≈ 32).
    public static let compactCornerRadius: CGFloat = 12
    public static let expandedCornerRadius: CGFloat = 32
    /// Compact "ear" radius where the silhouette meets the screen top edge (fitted: 8).
    public static let earRadius: CGFloat = 8
    /// Ears grow slightly while hovered (fitted to the elevated screenshot: body 281, top 295).
    public static let elevatedEarRadius: CGFloat = 9.5

    // Pill / simulated notch for displays without a notch.
    public static let pillIdleWidth: CGFloat = 168
    public static let pillVerticalMargin: CGFloat = 3
    public static let pillMinimumHeight: CGFloat = 18
    public static let simulatedNotchWidth: CGFloat = 185
    /// Hover zone for an idle (hidden) pill.
    public static let pillHoverZoneWidth: CGFloat = 240

    /// Extra margin while the pointer is already inside, to avoid edge flicker.
    public static let exitTolerance: CGFloat = 4
}

public enum IslandTiming {
    /// Extra delay between pointer exit and collapse start. The target is ≈ 50 ms from exit to
    /// visible collapse; event delivery and the first animation frame already account for that
    /// (measured 100–120 ms with an additional 50 ms delay), so none is added.
    public static let collapseDelay: Double = 0
    /// Spring parameters, tuned against the design's measurements:
    /// expand ≈ 230 ms main motion / ≈ 450 ms settle with slight overshoot; collapse ≈ 250 ms;
    /// elevation ≈ 150 ms.
    public static let expandResponse: Double = 0.42
    public static let expandDamping: Double = 0.74
    public static let collapseResponse: Double = 0.36
    public static let collapseDamping: Double = 0.90
    public static let elevateResponse: Double = 0.22
    public static let elevateDamping: Double = 0.82
    /// Content blur in/out.
    public static let contentBlurRadius: Double = 8
    public static let contentFadeDuration: Double = 0.12
}

/// Mission Control transitions: the island tucks into the notch
/// with Mission Control's zoom-out and grows back once the desktop has zoomed in again.
public enum MissionControlTiming {
    /// The tuck follows Mission Control's zoom-out, measured on macOS 27 as a fast ease-out (half way
    /// at ≈ 60 ms, 90 % at ≈ 150 ms, settled at ≈ 0.3 s): a critically damped spring with a 0.24 s
    /// response has the same shape.
    public static let tuckResponse: Double = 0.24
    public static let tuckDamping: Double = 1.0
    /// About when that spring has settled (the pill's fade-out runs this long).
    public static let tuckDuration: Double = 0.30
    /// From this point the window itself fades out too (a window-server property, so it works when
    /// Mission Control's cold start freezes the island's drawing; measured: frozen up to ≈ 0.45 s).
    /// Normally the island is almost inside the notch by then, so the fade can't be seen.
    public static let windowFadeDelay: Double = 0.20
    public static let windowFadeDuration: Double = 0.18
    /// The content fades out faster than the shape shrinks.
    public static let contentFadeOut: Double = 0.10
    /// When growing back, the content fades in once the shape has mostly grown (as the card's 160 ms).
    public static let contentFadeInDelay: Double = 0.16
    /// Pill and simulated notch: the panels fade in this fast as the island grows back.
    public static let untuckFadeIn: Double = 0.12
}
