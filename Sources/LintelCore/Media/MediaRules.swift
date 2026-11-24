import Foundation

/// Which media may take over the island: media shorter than
/// 3 s is ignored, and messaging apps are never sources, so voice notes don't take over the island.
public enum MediaSourceRules {
    public static let minimumDuration: Double = 3

    /// Messaging apps excluded as sources (WhatsApp, Signal, Slack, Teams, WeChat).
    public static let messagingApps: Set<String> = [
        "net.whatsapp.WhatsApp", "desktop.WhatsApp", "WhatsApp",
        "org.whispersystems.signal-desktop",
        "com.tinyspeck.slackmacgap",
        "com.microsoft.teams", "com.microsoft.teams2",
        "com.tencent.xinWeChat",
    ]

    public enum Verdict: String, Equatable, Sendable {
        case accepted, tooShort, messagingApp, ownApp
    }

    public static func verdict(for info: NowPlayingInfo, ownBundleID: String? = nil) -> Verdict {
        for candidate in [info.bundleID, info.parentBundleID].compactMap({ $0 }) {
            if let ownBundleID, candidate == ownBundleID { return .ownApp }
            if isMessagingApp(candidate) { return .messagingApp }
        }
        if let duration = info.knownDuration, duration < minimumDuration { return .tooShort }
        return .accepted
    }

    /// Matches the app itself and its helper processes (`<bundle id>.helper…`).
    public static func isMessagingApp(_ bundleID: String) -> Bool {
        if messagingApps.contains(bundleID) { return true }
        return messagingApps.contains { bundleID.hasPrefix($0 + ".") }
    }
}

/// "Hide media title extras": strips decorations such as featured artists and remaster or edition
/// suffixes from titles. The title is never emptied.
public enum MediaTitleCleaner {
    /// Words that mark a bracketed or dash-separated segment as decoration.
    private static let decorationPatterns: [String] = [
        #"^(feat\.?|ft\.?|featuring|with)\s"#,
        #"remaster"#,
        #"\bdeluxe\b"#,
        #"\bbonus track\b"#,
        #"\b(radio|single|album|extended|original) (edit|version|mix)\b"#,
        #"^edit$"#,
        #"\b(explicit|clean)( version)?$"#,
        #"^(mono|stereo)( version)?$"#,
        #"\banniversary( edition)?\b"#,
        #"\bexpanded( edition)?\b"#,
        #"\bspecial edition\b"#,
        #"\bofficial( music)? (video|audio)\b"#,
        #"\b(lyric|lyrics) video\b"#,
        #"\bvisuali[sz]er\b"#,
        #"\bfrom .+ soundtrack\b"#,
    ]

    public static func clean(_ title: String) -> String {
        var result = title
        // Bracketed segments: "(feat. X)", "[2011 Remaster]".
        result = removeSegments(in: result, pattern: #"\s*[\(\[]([^\(\)\[\]]*)[\)\]]"#)
        // Dash suffixes: " - Remastered 2011", " – Radio Edit".
        result = removeSegments(in: result, pattern: #"\s+[-–—]\s+([^-–—]+)$"#)
        // Unbracketed featuring at the end: "Song feat. X".
        if let range = result.range(of: #"\s+(feat\.|ft\.|featuring)\s.+$"#, options: [.regularExpression, .caseInsensitive]) {
            result.removeSubrange(range)
        }
        result = result.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? title : result
    }

    private static func removeSegments(in text: String, pattern: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        var result = text
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed()
        for match in matches {
            guard let whole = Range(match.range, in: result), let inner = Range(match.range(at: 1), in: result) else { continue }
            let content = result[inner].trimmingCharacters(in: .whitespaces)
            if isDecoration(content) { result.removeSubrange(whole) }
        }
        return result
    }

    static func isDecoration(_ segment: String) -> Bool {
        let lower = segment.lowercased()
        return decorationPatterns.contains { lower.range(of: $0, options: .regularExpression) != nil }
    }
}

/// Browsers whose media Lintel can focus.
public enum BrowserKind: String, Sendable, CaseIterable {
    case safari, safariTechnologyPreview, chrome, dia

    /// WebKit's GPU process plays Safari's media.
    public static let webKitGPUBundleID = "com.apple.WebKit.GPU"

    public var bundleID: String {
        switch self {
        case .safari: return "com.apple.Safari"
        case .safariTechnologyPreview: return "com.apple.SafariTechnologyPreview"
        case .chrome: return "com.google.Chrome"
        case .dia: return "company.thebrowser.dia"
        }
    }

    /// Name used in AppleScript `tell application`.
    public var scriptName: String {
        switch self {
        case .safari: return "Safari"
        case .safariTechnologyPreview: return "Safari Technology Preview"
        case .chrome: return "Google Chrome"
        case .dia: return "Dia"
        }
    }

    /// Safari-style dictionaries (`current tab`, `name`) vs Chromium-style (`active tab index`, `title`).
    public var isWebKit: Bool { self == .safari || self == .safariTechnologyPreview }

    public init?(bundleID: String?) {
        guard let bundleID else { return nil }
        if bundleID == Self.webKitGPUBundleID { self = .safari; return }
        guard let match = Self.allCases.first(where: { $0.bundleID == bundleID }) else { return nil }
        self = match
    }
}
