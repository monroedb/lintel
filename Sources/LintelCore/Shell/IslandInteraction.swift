import Foundation

public enum IslandPhase: String, Sendable, Equatable {
    /// At rest (compact).
    case idle
    /// Pointer inside, not expanded: the compact shape is slightly inflated.
    case elevated
    /// Showing the expanded card.
    case expanded
}

public struct InteractionConfig: Sendable, Equatable {
    public var expandOnHover: Bool
    public var hoverDelay: Double
    public var collapseDelay: Double

    public init(expandOnHover: Bool, hoverDelay: Double, collapseDelay: Double = IslandTiming.collapseDelay) {
        self.expandOnHover = expandOnHover
        self.hoverDelay = max(0, hoverDelay)
        self.collapseDelay = max(0, collapseDelay)
    }
}

/// Side effects the controller must perform (timers are owned by the caller).
public enum InteractionEffect: Sendable, Equatable {
    case scheduleExpand(after: Double)
    case cancelExpand
    case scheduleCollapse(after: Double)
    case cancelCollapse
}

/// Pointer/click state machine for one island.
///
/// - entering elevates immediately; with hover-expansion it expands after the hover delay;
/// - leaving collapses after a short delay (≈ 50 ms);
/// - a click expands immediately; clicks inside the expanded card keep it open.
public struct IslandInteraction: Sendable, Equatable {
    public private(set) var phase: IslandPhase = .idle
    public private(set) var pointerInside = false
    /// Only a timer that was actually scheduled may act when it fires.
    private var expandPending = false
    private var collapsePending = false

    public init() {}

    public mutating func pointerEntered(_ config: InteractionConfig) -> [InteractionEffect] {
        guard !pointerInside else { return [] }
        pointerInside = true
        collapsePending = false
        var effects: [InteractionEffect] = [.cancelCollapse]
        if phase == .idle { phase = .elevated }
        if config.expandOnHover, phase != .expanded {
            expandPending = true
            effects.append(.scheduleExpand(after: config.hoverDelay))
        }
        return effects
    }

    public mutating func pointerExited(_ config: InteractionConfig) -> [InteractionEffect] {
        guard pointerInside else { return [] }
        pointerInside = false
        expandPending = false
        var effects: [InteractionEffect] = [.cancelExpand]
        if phase != .idle {
            collapsePending = true
            effects.append(.scheduleCollapse(after: config.collapseDelay))
        }
        return effects
    }

    public mutating func clicked() -> [InteractionEffect] {
        guard phase != .expanded else { return [] }
        phase = .expanded
        expandPending = false
        collapsePending = false
        return [.cancelExpand, .cancelCollapse]
    }

    public mutating func expandTimerFired() -> [InteractionEffect] {
        guard expandPending else { return [] }
        expandPending = false
        if pointerInside, phase != .expanded { phase = .expanded }
        return []
    }

    public mutating func collapseTimerFired() -> [InteractionEffect] {
        guard collapsePending else { return [] }
        collapsePending = false
        if !pointerInside { phase = .idle }
        return []
    }

    /// Programmatic open (swipe down, middle click): same as a click.
    public mutating func open() -> [InteractionEffect] { clicked() }

    /// Programmatic close (swipe up): back to the compact shape, still elevated while the pointer is
    /// inside. Hover-expansion does not re-trigger until the pointer leaves and re-enters.
    public mutating func close() -> [InteractionEffect] {
        guard phase == .expanded else { return [] }
        phase = pointerInside ? .elevated : .idle
        expandPending = false
        collapsePending = false
        return [.cancelExpand, .cancelCollapse]
    }

    /// Forces the island back to rest (e.g. when its display is removed or the island is hidden).
    public mutating func reset() {
        phase = .idle
        pointerInside = false
        expandPending = false
        collapsePending = false
    }
}
