import AppKit
import LintelCore

/// Estimates how dark the backdrop behind the island is, from the desktop picture under the top
/// centre of the screen (public desktop-picture luminance). Results are
/// cached per picture and screen size; callers refresh on wallpaper or space changes. Rotating
/// folders and pictures in protected folders aren't read; the coordinator then falls back to the
/// menu bar's appearance.
@MainActor
final class BackdropLuminanceSampler {
    private var cache: [String: Double] = [:]

    func luminance(for screen: NSScreen) -> Double? {
        guard let url = NSWorkspace.shared.desktopImageURL(for: screen), Self.isReadableWithoutPrompt(url) else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else { return nil }
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? 0
        let key = "\(url.path)|\(modified)|\(Int(screen.frame.width))x\(Int(screen.frame.height))"
        if let cached = cache[key] { return cached }
        guard let value = WallpaperSampler.sample(url: url, screenSize: screen.frame.size) else { return nil }
        cache[key] = value
        return value
    }

    func invalidate() { cache.removeAll() }

    /// Only pictures in system or unprotected locations are read: touching Desktop, Documents,
    /// Downloads or iCloud Drive would make macOS ask the user for folder access.
    static func isReadableWithoutPrompt(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let allowed = ["/System/Library/", "/Library/", home + "/Library/Application Support/com.apple.mobileAssetDesktop/",
                       home + "/Pictures/"]
        return allowed.contains { path.hasPrefix($0) }
    }
}
