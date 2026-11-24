import Foundation

/// How the compact island moves from the presentation it shows to a new one
/// (measured volume HUD: the current activity blurs out
/// while the shape contracts to the notch, then the new content grows in).
public enum SwapPlan: Equatable, Sendable {
    /// Same presentation: content updates in place (e.g. a HUD level change).
    case none
    /// Related live content (e.g. media → media + calendar): resize directly and cross-fade.
    case morph
    /// From idle: grow straight to the new size.
    case grow
    /// To idle: content blurs out while the shape contracts to the notch.
    case contract
    /// Different content: contract to the notch, then grow the new content.
    case contractThenGrow

    public static func between(_ from: CompactPresentation, _ to: CompactPresentation) -> SwapPlan {
        if from == to { return .none }
        switch (from, to) {
        case (.idle, _): return .grow
        case (_, .idle): return .contract
        // Live activities share the island, and a Quick Peek is a partial expansion of it: resize directly.
        case (.live, .live), (.live, .peek), (.peek, .live), (.peek, .peek): return .morph
        // Volume ↔ brightness HUD: same bar, swap the content in place.
        case (.notification(let a), .notification(let b)) where a.isHUD && b.isHUD: return .morph
        default: return .contractThenGrow
        }
    }
}

/// Drops haptic triggers that follow the previous one too closely, so a burst produces one tick.
public struct HapticGate: Sendable {
    public var interval: Double
    private var last: Double?

    public init(interval: Double = 0.12) {
        self.interval = interval
    }

    public mutating func shouldFire(now: Double) -> Bool {
        if let last, now - last < interval { return false }
        last = now
        return true
    }
}

extension ExpandedContent {
    /// Maps the idle-activity setting to expanded content.
    public init(idle: IdleActivity) {
        switch idle {
        case .nothing: self = .nothing
        case .media: self = .media
        case .calendar: self = .calendar
        case .both: self = .both
        case .timer: self = .timer
        }
    }
}
