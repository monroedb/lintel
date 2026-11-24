import Foundation

extension SwapTiming {
    /// Time the grow phase needs to settle (grow spring response 0.42 / damping 0.74: main motion
    /// ≈ 0.25 s, settled ≈ 0.45 s; measured 0.47 s in the recordings).
    public static let growSettle: Double = 0.45

    /// Time from posting a notification until it is fully shown. A notification's hold counts from
    /// there (the volume HUD "grows in ≈ 370–800 ms after the key, holds for the volume
    /// duration (1.5 s; about 1.6 s measured), then collapses"; the Focus alert appeared within
    /// ≈ 0.7 s and then "held about 5 s"), so it is posted for lead-in + duration. A HUD that is
    /// already showing gets no lead-in: further presses extend it from the press.
    public static func notificationLeadIn(from current: CompactPresentation, to target: CompactPresentation,
                                          expanded: Bool) -> Double {
        // On the open card the notification appears in a strip as the card grows.
        if expanded { return debounce + 0.3 }
        switch SwapPlan.between(current, target) {
        case .none, .contract: return 0
        case .grow, .morph: return debounce + growSettle
        case .contractThenGrow: return debounce + growDelay + growSettle
        }
    }
}

extension NotificationKind {
    /// The compact presentation that shows this notification.
    public var asPresentation: CompactPresentation { .notification(self) }
}
