import CoreGraphics

/// Trackpad swipe recognition on the island.
///
/// Distances are finger movement in points: +x = right, +y = down. Only phased (trackpad) scroll
/// events are fed in; mouse wheels are ignored by the caller.
public struct SwipeRecognizer: Sendable {
    public struct Config: Equatable, Sendable {
        public var horizontalThreshold: CGFloat = 60
        public var verticalThreshold: CGFloat = 40
        public var cycleArmThreshold: CGFloat = 50
        public var axisLockDistance: CGFloat = 8
        public var maxStretch: CGFloat = 12
        public var stretchFactor: CGFloat = 0.25
        public var toggleEnabled = true
        public var cycleEnabled = true
        public var dismissEnabled = true
        public var skipEnabled = true
        /// "Natural movement": content follows the finger, so swiping left goes to the next item.
        public var naturalDirection = false

        public init() {}
    }

    public struct State: Equatable, Sendable {
        public var expanded: Bool
        public var hasLiveActivity: Bool
        public var hasMedia: Bool

        public init(expanded: Bool, hasLiveActivity: Bool, hasMedia: Bool) {
            self.expanded = expanded
            self.hasLiveActivity = hasLiveActivity
            self.hasMedia = hasMedia
        }
    }

    public enum Action: Equatable, Sendable {
        case open, close, cycle, dismiss, skipNext, skipPrevious
    }

    public enum Feedback: Equatable, Sendable {
        /// A threshold was crossed (haptic tick).
        case thresholdCrossed
    }

    public struct Output: Equatable, Sendable {
        public var action: Action?
        public var feedback: Feedback?
        /// Rubber-band offset to apply to the island while the gesture lasts.
        public var stretch: CGSize
    }

    private enum Axis: Equatable, Sendable { case horizontal, vertical }

    public var config: Config
    private var total = CGSize.zero
    private var axis: Axis?
    private var fired = false
    private var cycleArmed = false
    private var active = false

    public init(config: Config = Config()) {
        self.config = config
    }

    public mutating func began(state: State) -> Output {
        total = .zero
        axis = nil
        fired = false
        cycleArmed = false
        active = true
        return Output(action: nil, feedback: nil, stretch: .zero)
    }

    public mutating func changed(dx: CGFloat, dy: CGFloat, state: State) -> Output {
        guard active else { return Output(action: nil, feedback: nil, stretch: .zero) }
        total.width += dx
        total.height += dy
        if axis == nil, max(abs(total.width), abs(total.height)) >= config.axisLockDistance {
            axis = abs(total.width) > abs(total.height) ? .horizontal : .vertical
        }
        var action: Action?
        var feedback: Feedback?
        switch axis {
        case .horizontal?:
            if !fired, config.skipEnabled, state.hasMedia, abs(total.width) >= config.horizontalThreshold {
                fired = true
                let fingerRight = total.width > 0
                action = (fingerRight != config.naturalDirection) ? .skipNext : .skipPrevious
                feedback = .thresholdCrossed
            }
        case .vertical?:
            let down = total.height > 0
            if state.expanded {
                if down {
                    if config.cycleEnabled, !fired, !cycleArmed, total.height >= config.cycleArmThreshold {
                        cycleArmed = true
                        feedback = .thresholdCrossed
                    } else if cycleArmed, total.height < config.cycleArmThreshold {
                        cycleArmed = false // pulled back: disarm
                    }
                } else if !fired, config.toggleEnabled, -total.height >= config.verticalThreshold {
                    fired = true
                    cycleArmed = false
                    action = .close
                    feedback = .thresholdCrossed
                }
            } else if !fired {
                if down, config.toggleEnabled, total.height >= config.verticalThreshold {
                    fired = true
                    action = .open
                    feedback = .thresholdCrossed
                } else if !down, config.dismissEnabled, state.hasLiveActivity, -total.height >= config.verticalThreshold {
                    fired = true
                    action = .dismiss
                    feedback = .thresholdCrossed
                }
            }
        case nil:
            break
        }
        return Output(action: action, feedback: feedback, stretch: stretch)
    }

    public mutating func ended(state: State) -> Output {
        defer {
            active = false
            total = .zero
            axis = nil
        }
        if cycleArmed, !fired, state.expanded {
            fired = true
            cycleArmed = false
            return Output(action: .cycle, feedback: nil, stretch: .zero)
        }
        return Output(action: nil, feedback: nil, stretch: .zero)
    }

    public mutating func cancelled() -> Output {
        active = false
        total = .zero
        axis = nil
        cycleArmed = false
        return Output(action: nil, feedback: nil, stretch: .zero)
    }

    private var stretch: CGSize {
        func band(_ v: CGFloat) -> CGFloat {
            let magnitude = min(config.maxStretch, abs(v) * config.stretchFactor)
            return v < 0 ? -magnitude : magnitude
        }
        switch axis {
        case .horizontal?: return CGSize(width: band(total.width), height: 0)
        case .vertical?: return CGSize(width: 0, height: band(total.height))
        case nil: return .zero
        }
    }

    /// Converts AppKit scroll deltas to finger movement (+x right, +y down).
    public static func fingerDelta(scrollingDeltaX: CGFloat, scrollingDeltaY: CGFloat, invertedFromDevice: Bool) -> CGSize {
        invertedFromDevice ? CGSize(width: scrollingDeltaX, height: scrollingDeltaY)
                           : CGSize(width: -scrollingDeltaX, height: -scrollingDeltaY)
    }
}
