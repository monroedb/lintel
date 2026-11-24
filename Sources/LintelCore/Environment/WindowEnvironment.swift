import CoreGraphics

/// One on-screen window as reported by `CGWindowListCopyWindowInfo` (no window names needed, so no
/// Screen Recording permission). Bounds use CoreGraphics global coordinates (origin top-left).
public struct WindowRecord: Equatable, Sendable {
    public var ownerName: String
    public var ownerPID: Int32
    public var layer: Int
    public var bounds: CGRect

    public init(ownerName: String, ownerPID: Int32, layer: Int, bounds: CGRect) {
        self.ownerName = ownerName
        self.ownerPID = ownerPID
        self.layer = layer
        self.bounds = bounds
    }
}

/// A display in CoreGraphics global coordinates (origin top-left).
public struct DisplayRecord: Equatable, Sendable {
    public var id: UInt32
    public var bounds: CGRect
    public var menuBarHeight: CGFloat

    public init(id: UInt32, bounds: CGRect, menuBarHeight: CGFloat) {
        self.id = id
        self.bounds = bounds
        self.menuBarHeight = menuBarHeight
    }
}

/// Public window-list heuristics for Mission Control and full screen.
///
/// Observed on macOS 27: while Mission Control is open, the WindowManager process owns a window at
/// layer 19 covering the display (plus a layer-14 Spaces bar). In a normal space the Dock owns a
/// layer-20 window covering each display; in a native full-screen space that window is absent and
/// the full-screen app covers the display below the menu-bar strip.
public enum WindowEnvironment {
    public static let missionControlOwner = "WindowManager"
    public static let missionControlLayer = 19
    public static let dockOwner = "Dock"
    public static let dockLayer = 20

    public static func missionControlActive(windows: [WindowRecord], displays: [DisplayRecord]) -> Bool {
        windows.contains { w in
            w.ownerName == missionControlOwner && w.layer == missionControlLayer &&
                displays.contains { coversMost(w.bounds, $0.bounds) }
        }
    }

    /// Displays whose current space is a native full-screen space.
    public static func fullScreenDisplays(windows: [WindowRecord], displays: [DisplayRecord],
                                          frontmostPID: Int32?) -> Set<UInt32> {
        var result = Set<UInt32>()
        for display in displays {
            let dockPresent = windows.contains { $0.ownerName == dockOwner && $0.layer == dockLayer && coversMost($0.bounds, display.bounds) }
            if dockPresent { continue }
            let covered = windows.contains { w in
                w.layer == 0 && w.ownerName != dockOwner &&
                    (frontmostPID == nil || w.ownerPID == frontmostPID) &&
                    abs(w.bounds.minX - display.bounds.minX) <= 1 && abs(w.bounds.width - display.bounds.width) <= 1 &&
                    w.bounds.minY <= display.bounds.minY + display.menuBarHeight + 1 &&
                    w.bounds.maxY >= display.bounds.maxY - 1
            }
            if covered { result.insert(display.id) }
        }
        return result
    }

    private static func coversMost(_ window: CGRect, _ display: CGRect) -> Bool {
        let inter = window.intersection(display)
        guard !inter.isNull else { return false }
        return inter.width * inter.height >= 0.9 * display.width * display.height
    }
}

/// Decides whether the frontmost app is a game (public metadata first).
public enum GameClassifier {
    /// Bundle identifiers of game launchers/streamers whose category isn't "games".
    public static let knownGameBundleIDs: Set<String> = [
        "com.nvidia.gfnpc.mall",        // GeForce NOW
    ]
    /// Path fragments of game installs.
    public static let gamePathFragments = ["/steamapps/common/", "/Epic Games/", "/Games/"]

    public static func isGame(bundleID: String?, category: String?, bundlePath: String?) -> Bool {
        if let category = category?.lowercased(),
           category == "public.app-category.games" || (category.hasPrefix("public.app-category.") && category.hasSuffix("-games")) {
            return true
        }
        if let bundleID, knownGameBundleIDs.contains(bundleID) { return true }
        if let path = bundlePath, gamePathFragments.contains(where: { path.contains($0) }) { return true }
        return false
    }
}

/// What the island may show given the hiding rules.
public enum IslandVisibility: Equatable, Sendable {
    case visible
    /// Live activities and peeks suppressed; notifications and interaction still work (full screen).
    case liveActivitiesSuppressed
    /// Fully hidden and non-interactive (Mission Control, gaming).
    case hidden

    public static func resolve(fullScreen: Bool, missionControl: Bool, gaming: Bool,
                               hideInFullScreen: Bool, hideInMissionControl: Bool, hideWhileGaming: Bool) -> IslandVisibility {
        if missionControl && hideInMissionControl { return .hidden }
        if gaming && hideWhileGaming { return .hidden }
        if fullScreen && hideInFullScreen { return .liveActivitiesSuppressed }
        return .visible
    }
}

/// Luminance helpers for the contrast outline.
public enum Luminance {
    public static let outlineThreshold = 0.25

    /// Relative luminance of an sRGB colour (components 0…1).
    public static func relative(r: Double, g: Double, b: Double) -> Double {
        func lin(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }

    /// Mean relative luminance of 8-bit RGBA pixels.
    public static func mean(rgba: [UInt8]) -> Double {
        guard rgba.count >= 4 else { return 1 }
        var sum = 0.0
        var count = 0
        var i = 0
        while i + 3 < rgba.count {
            sum += relative(r: Double(rgba[i]) / 255, g: Double(rgba[i + 1]) / 255, b: Double(rgba[i + 2]) / 255)
            count += 1
            i += 4
        }
        return sum / Double(count)
    }

    public static func shouldOutline(luminance: Double) -> Bool { luminance < outlineThreshold }
}
