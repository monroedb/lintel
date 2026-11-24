import CoreGraphics
import Foundation

/// The two system indicators Lintel replaces.
public enum HUDKind: String, CaseIterable, Sendable, Codable {
    case volume, brightness

    /// The transient notification that shows this HUD in the island.
    public var notification: NotificationKind { self == .volume ? .volume : .brightness }

    public init?(notification: NotificationKind) {
        switch notification {
        case .volume: self = .volume
        case .brightness: self = .brightness
        default: return nil
        }
    }

    /// Label shown beside the glyph ("Sound" / "Display").
    public var defaultLabel: String { self == .volume ? "Sound" : "Display" }
}

/// Colour of the level bar: white, the system accent colour, or the HUD's own look — a level meter
/// that warms towards orange at high volume, or a glow for brightness ("White / Accent /
/// Decibel | Glow"; stored values are Lintel's own).
public enum HUDBarStyle: String, SettingChoice {
    case white, accent, vivid
}

/// How the level bar moves to a new value (Smooth / Fast (default) / Instant).
public enum HUDBarSpeed: String, SettingChoice {
    case smooth, fast, instant

    /// Spring response of the bar animation in seconds; 0 means no animation.
    public var response: Double {
        switch self {
        case .smooth: return 0.45
        case .fast: return 0.16
        case .instant: return 0
        }
    }

    /// Brightness writes ramp over this long with the Smooth speed ("smooth set … used by the
    /// Smooth speed"); other speeds set the value at once.
    public var brightnessRamp: Double { self == .smooth ? 0.25 : 0 }
}

/// What the volume HUD's leading glyph and label show ("Show symbol" / "Show device", default
/// device).
public enum VolumeLabelMode: String, SettingChoice {
    case symbol, device
}

/// Which display the brightness keys adjust (the "managed" display — automatic, internal,
/// external; ctrl + key alternates).
public enum BrightnessTargetMode: String, SettingChoice {
    case automatic, builtIn, external
}

/// Edge of the level range a key press pushed against.
public enum LevelEdge: String, Sendable, Codable {
    case minimum, maximum
}

/// HUD appearance settings in one value (per HUD kind).
public struct HUDAppearance: Equatable, Sendable {
    public var style: HUDBarStyle
    public var speed: HUDBarSpeed
    public var showPercentage: Bool
    public var hideLabel: Bool

    public init(style: HUDBarStyle = .white, speed: HUDBarSpeed = .fast, showPercentage: Bool = false, hideLabel: Bool = false) {
        self.style = style
        self.speed = speed
        self.showPercentage = showPercentage
        self.hideLabel = hideLabel
    }
}

/// Layout of the HUD bar, fitted to the design screenshots (at 2x):
/// glyph centred 18 pt from the body's leading edge, label from
/// 34.5 pt, level track 67.5 × 4.4 pt ending 11.5 pt from the trailing edge, vertically centred.
public enum HUDBarMetrics {
    public static let trackWidth: CGFloat = 67.5
    public static let trackHeight: CGFloat = 4.4
    /// Track width when the percentage is shown beside it.
    public static let trackWidthWithPercentage: CGFloat = 44
    public static let percentageWidth: CGFloat = 25
    public static let percentageGap: CGFloat = 6
    /// Slot width below which the label is dropped (the open card's notification strip).
    public static let minimumSlotForLabel: CGFloat = 90
    /// Rubber-band of the level bar when a press pushes past a bound (≈ 1 s).
    public static let overshootStretch: CGFloat = 7
    public static let overshootDuration: Double = 1.0

    /// Fill width for a level: an empty track at 0, at least a dot (the track height) above it.
    public static func fillWidth(level: Double, trackWidth: CGFloat, trackHeight: CGFloat = trackHeight) -> CGFloat {
        let clamped = min(1, max(0, level))
        guard clamped > 0 else { return 0 }
        return max(trackHeight, trackWidth * CGFloat(clamped))
    }

    /// Whole percent shown with "Show percentage".
    public static func percent(_ level: Double) -> Int { Int((min(1, max(0, level)) * 100).rounded()) }
}
