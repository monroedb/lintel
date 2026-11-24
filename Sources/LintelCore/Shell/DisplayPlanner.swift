import CoreGraphics

/// A display as seen by the planner. Frames use AppKit global coordinates (origin at the
/// bottom-left of the primary display, y grows upward).
public struct ScreenDescriptor: Sendable, Equatable {
    public var uuid: String
    public var name: String
    public var frame: CGRect
    /// Hardware notch size, from the auxiliary top areas and the top safe-area inset; nil if none.
    public var notchSize: CGSize?
    /// Height of the menu bar strip at the top of this display.
    public var menuBarHeight: CGFloat
    public var isBuiltIn: Bool
    /// The display that carries the menu bar ("Main display").
    public var isPrimary: Bool

    public init(uuid: String, name: String, frame: CGRect, notchSize: CGSize?, menuBarHeight: CGFloat,
                isBuiltIn: Bool, isPrimary: Bool) {
        self.uuid = uuid
        self.name = name
        self.frame = frame
        self.notchSize = notchSize
        self.menuBarHeight = menuBarHeight
        self.isBuiltIn = isBuiltIn
        self.isPrimary = isPrimary
    }

    /// Notch size derived from the auxiliary areas left and right of the camera housing.
    public static func notchSize(screenWidth: CGFloat, auxLeftWidth: CGFloat?, auxRightWidth: CGFloat?,
                                 safeAreaTop: CGFloat) -> CGSize? {
        guard let left = auxLeftWidth, let right = auxRightWidth, safeAreaTop > 0 else { return nil }
        let width = screenWidth - left - right
        guard width > 0 else { return nil }
        return CGSize(width: width, height: safeAreaTop)
    }
}

public enum IslandShape: String, Sendable, Equatable {
    /// Follows the hardware notch silhouette.
    case notch
    /// A notch silhouette drawn on a display without a notch ("Force simulated notch").
    case simulatedNotch
    /// A capsule inside the menu bar on a display without a notch.
    case pill
}

/// Where and how one display's island is drawn.
public struct IslandPlan: Sendable, Equatable {
    public var screenUUID: String
    public var screenName: String
    public var shape: IslandShape
    /// Panel frame in AppKit global coordinates.
    public var canvas: CGRect
    /// Island size at rest (including tuning).
    public var compactSize: CGSize
    /// Distance from the canvas top to the island top (0 for notch shapes, centred in the menu bar for the pill).
    public var topInset: CGFloat
    /// Whether the island is invisible while idle (pill without activity).
    public var hiddenWhenIdle: Bool
    /// The shape the island tucks into while Mission Control is shown:
    /// the hardware notch exactly (no tuning), the simulated
    /// notch, or the pill.
    public var tuckSize: CGSize
    /// Whether that shape disappears behind real hardware (the notch). Otherwise the island fades
    /// out as it tucks in and fades in as it grows back.
    public var tuckHiddenByHardware: Bool { shape == .notch }

    public init(screenUUID: String, screenName: String, shape: IslandShape, canvas: CGRect, compactSize: CGSize,
                topInset: CGFloat, hiddenWhenIdle: Bool, tuckSize: CGSize? = nil) {
        self.screenUUID = screenUUID
        self.screenName = screenName
        self.shape = shape
        self.canvas = canvas
        self.compactSize = compactSize
        self.topInset = topInset
        self.hiddenWhenIdle = hiddenWhenIdle
        self.tuckSize = tuckSize ?? compactSize
    }

    /// Island rect in AppKit global coordinates for a given drawn size.
    public func islandRect(size: CGSize) -> CGRect {
        CGRect(x: canvas.midX - size.width / 2,
               y: canvas.maxY - topInset - size.height,
               width: size.width, height: size.height)
    }

    /// Region that starts a hover while idle.
    public var hoverZone: CGRect {
        if hiddenWhenIdle {
            let height = topInset * 2 + compactSize.height
            return CGRect(x: canvas.midX - IslandMetrics.pillHoverZoneWidth / 2, y: canvas.maxY - height,
                          width: IslandMetrics.pillHoverZoneWidth, height: height)
        }
        return islandRect(size: compactSize)
    }
}

public enum DisplayPlanner {
    /// Chooses the displays that get an island and computes each island's geometry.
    public static func plan(screens: [ScreenDescriptor],
                            selection: DisplaySelection,
                            chosenUUID: String?,
                            forceSimulatedNotch: Bool,
                            tuning: CGSize,
                            treatAllAsNotchless: Bool = false) -> [IslandPlan] {
        guard !screens.isEmpty else { return [] }
        let primary = screens.first(where: \.isPrimary) ?? screens[0]
        let targets: [ScreenDescriptor]
        switch selection {
        case .all:
            targets = screens
        case .main:
            targets = [primary]
        case .builtIn:
            targets = [screens.first(where: \.isBuiltIn) ?? primary]
        case .selected:
            targets = [screens.first(where: { $0.uuid == chosenUUID }) ?? primary]
        }
        return targets.map { plan(for: $0, forceSimulatedNotch: forceSimulatedNotch, tuning: tuning,
                                  treatAsNotchless: treatAllAsNotchless) }
    }

    public static func plan(for screen: ScreenDescriptor, forceSimulatedNotch: Bool, tuning: CGSize,
                            treatAsNotchless: Bool = false) -> IslandPlan {
        let canvas = CGRect(x: (screen.frame.midX - IslandMetrics.canvasSize.width / 2).rounded(),
                            y: screen.frame.maxY - IslandMetrics.canvasSize.height,
                            width: IslandMetrics.canvasSize.width, height: IslandMetrics.canvasSize.height)
        let notch = treatAsNotchless ? nil : screen.notchSize
        if let notch {
            let size = CGSize(width: notch.width + tuning.width, height: notch.height + tuning.height)
            return IslandPlan(screenUUID: screen.uuid, screenName: screen.name, shape: .notch, canvas: canvas,
                              compactSize: size, topInset: 0, hiddenWhenIdle: false, tuckSize: notch)
        }
        if forceSimulatedNotch {
            let size = CGSize(width: IslandMetrics.simulatedNotchWidth + tuning.width,
                              height: screen.menuBarHeight + tuning.height)
            return IslandPlan(screenUUID: screen.uuid, screenName: screen.name, shape: .simulatedNotch,
                              canvas: canvas, compactSize: size, topInset: 0, hiddenWhenIdle: false,
                              tuckSize: CGSize(width: IslandMetrics.simulatedNotchWidth, height: screen.menuBarHeight))
        }
        let pillHeight = max(IslandMetrics.pillMinimumHeight, screen.menuBarHeight - 2 * IslandMetrics.pillVerticalMargin)
        let size = CGSize(width: IslandMetrics.pillIdleWidth + tuning.width, height: pillHeight + tuning.height)
        let inset = max(0, (screen.menuBarHeight - size.height) / 2)
        return IslandPlan(screenUUID: screen.uuid, screenName: screen.name, shape: .pill, canvas: canvas,
                          compactSize: size, topInset: inset, hiddenWhenIdle: true, tuckSize: size)
    }
}
