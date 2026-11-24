import Foundation

/// Players with an AppleScript dictionary ("Spotify").
public enum ScriptablePlayer: String, Sendable, CaseIterable {
    case music, spotify

    public var bundleID: String {
        switch self {
        case .music: return "com.apple.Music"
        case .spotify: return "com.spotify.client"
        }
    }

    public var scriptName: String {
        switch self {
        case .music: return "Music"
        case .spotify: return "Spotify"
        }
    }

    /// Distributed notification posted by the player on every state change (no permission needed).
    public var stateNotification: String {
        switch self {
        case .music: return "com.apple.Music.playerInfo"
        case .spotify: return "com.spotify.client.PlaybackStateChanged"
        }
    }

    /// What the AppleScript dictionary adds beyond transport control.
    public var scriptCapabilities: MediaCapabilities {
        switch self {
        case .music: return [.playPause, .nextPrevious, .seek, .shuffle, .repeatMode, .favorite, .link]
        case .spotify: return [.playPause, .nextPrevious, .seek, .shuffle, .repeatMode, .link]
        }
    }
}

/// AppleScript sources for Music and Spotify: script texts and reply parsing. Scripts run with a
/// timeout off the main thread (scripts into other apps can block) and never launch
/// the player (every script checks `is running` first).
public enum MediaScripts {
    /// Separates reply fields (ASCII unit separator; never part of titles).
    public static let separator = "\u{1F}"

    /// An AppleScript string literal.
    public static func literal(_ text: String) -> String {
        let escaped = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private static func guarded(_ player: ScriptablePlayer, _ body: String) -> String {
        """
        if application \(literal(player.scriptName)) is running then
        tell application \(literal(player.scriptName))
        \(body)
        end tell
        end if
        return "notRunning"
        """
    }

    /// Reads the full player state as one separated line.
    public static func stateQuery(_ player: ScriptablePlayer) -> String {
        let sep = "(ASCII character 31)"
        switch player {
        case .music:
            return guarded(player, """
            set s to (player state as text)
            if s is "stopped" then return "stopped"
            set t to current track
            set f to "false"
            set k to ""
            set r to ""
            set m to ""
            set p to ""
            try
            set f to (favorited of t) as text
            end try
            try
            set k to (kind of t) as text
            set r to (sample rate of t) as text
            end try
            try
            set m to (media kind of t) as text
            end try
            try
            set p to persistent ID of t
            end try
            return s & \(sep) & (name of t) & \(sep) & (artist of t) & \(sep) & (album of t) & \(sep) & ((duration of t) as text) & \(sep) & ((player position) as text) & \(sep) & f & \(sep) & ((shuffle enabled) as text) & \(sep) & ((song repeat) as text) & \(sep) & p & \(sep) & k & \(sep) & r & \(sep) & m
            """)
        case .spotify:
            return guarded(player, """
            set s to (player state as text)
            if s is "stopped" then return "stopped"
            set t to current track
            return s & \(sep) & (name of t) & \(sep) & (artist of t) & \(sep) & (album of t) & \(sep) & ((duration of t) as text) & \(sep) & ((player position) as text) & \(sep) & ((starred of t) as text) & \(sep) & (shuffling as text) & \(sep) & (repeating as text) & \(sep) & (spotify url of t) & \(sep) & (artwork url of t)
            """)
        }
    }

    /// Reads only the position (polled every second while the player is visible).
    public static func positionQuery(_ player: ScriptablePlayer) -> String {
        guarded(player, "return (player position) as text")
    }

    public struct State: Equatable, Sendable {
        public var info: NowPlayingInfo?
        /// Spotify's artwork URL (Music artwork is exported to a file separately).
        public var artworkURL: String?
        public var running: Bool
    }

    /// Parses a `stateQuery` reply. Numbers use the script's locale; both "." and "," decimals work.
    public static func parseState(_ reply: String, player: ScriptablePlayer, now: Date = Date()) -> State {
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if text == "notRunning" || text.isEmpty { return State(info: nil, running: false) }
        if text == "stopped" { return State(info: nil, running: true) }
        let f = text.components(separatedBy: separator)
        func field(_ index: Int) -> String { index < f.count ? f[index] : "" }
        func number(_ index: Int) -> Double? { Double(field(index).replacingOccurrences(of: ",", with: ".")) }
        guard f.count >= 9, !field(1).isEmpty else { return State(info: nil, running: true) }
        let playing = field(0) == "playing"
        var info = NowPlayingInfo(title: field(1), artist: field(2), album: field(3), playing: playing,
                                  bundleID: player.bundleID, capabilities: player.scriptCapabilities)
        info.elapsed = number(5)
        info.timestamp = now
        info.shuffle = field(7) == "true"
        info.favorite = field(6) == "true"
        var artworkURL: String?
        switch player {
        case .music:
            info.duration = number(4)
            switch field(8) {
            case "one": info.repeatMode = .one
            case "all": info.repeatMode = .all
            default: info.repeatMode = .off
            }
            info.itemID = field(9).isEmpty ? nil : field(9)
            info.format = audioFormat(kind: field(10), sampleRate: number(11))
            info.kind = field(12).lowercased().contains("podcast") ? .podcast : .music
            if info.kind == .podcast { info.capabilities.insert(.skipInterval) }
        case .spotify:
            info.duration = number(4).map { $0 / 1000 } // milliseconds
            info.repeatMode = field(8) == "true" ? .all : .off
            info.capabilities.remove(.favorite) // `starred` is read-only
            info.link = field(9).isEmpty ? nil : field(9)
            info.itemID = info.link
            artworkURL = field(10).isEmpty ? nil : field(10)
            if info.link?.hasPrefix("spotify:episode:") == true {
                info.kind = .podcast
                info.capabilities.insert(.skipInterval)
            }
        }
        return State(info: info, artworkURL: artworkURL, running: true)
    }

    /// Lossless and hi-res from Music's track kind and sample rate (> 48 kHz = hi-res).
    public static func audioFormat(kind: String, sampleRate: Double?) -> AudioFormatBadge? {
        let lower = kind.lowercased()
        if lower.contains("atmos") { return .dolbyAtmos }
        guard lower.contains("lossless") || lower.contains("alac") || lower.contains("aiff") || lower.contains("wav") else {
            return nil
        }
        if let sampleRate, sampleRate > 48_000 { return .hiResLossless }
        return .lossless
    }

    /// The script for a command, or nil when the player can't do it.
    public static func command(_ command: MediaCommand, player: ScriptablePlayer, current: NowPlayingInfo? = nil) -> String? {
        let body: String
        switch command {
        case .play: body = "play"
        case .pause: body = "pause"
        case .togglePlayPause: body = "playpause"
        case .next: body = "next track"
        case .previous: body = "previous track"
        case .seek(let position):
            body = "set player position to \(format(max(0, position)))"
        case .skip(let delta):
            body = "set player position to ((player position) + (\(format(delta))))"
        case .setRate:
            return nil
        case .setShuffle(let on):
            body = player == .music ? "set shuffle enabled to \(on)" : "set shuffling to \(on)"
        case .setRepeat(let mode):
            switch player {
            case .music:
                body = "set song repeat to \(mode == .one ? "one" : (mode == .all ? "all" : "off"))"
            case .spotify:
                body = "set repeating to \(mode != .off)"
            }
        case .setFavorite(let on):
            guard player == .music else { return nil }
            body = "set favorited of current track to \(on)"
        }
        return guarded(player, body + "\nreturn \"ok\"")
    }

    /// Exports Music's current artwork to a file; replies "ok" or "none".
    public static func exportMusicArtwork(to path: String) -> String {
        """
        if application "Music" is running then
        tell application "Music"
        if (count of artworks of current track) is 0 then return "none"
        set d to raw data of artwork 1 of current track
        end tell
        set f to open for access (POSIX file \(literal(path))) with write permission
        set eof of f to 0
        write d to f
        close access f
        return "ok"
        end if
        return "notRunning"
        """
    }

    /// Selects the tab whose title contains the media title and raises its window.
    /// Replies "found" or "none".
    public static func focusBrowserTab(_ browser: BrowserKind, titleContains title: String) -> String {
        let app = literal(browser.scriptName)
        let needle = literal(title)
        if browser.isWebKit {
            return """
            if application \(app) is running then
            tell application \(app)
            repeat with w in windows
            repeat with t in tabs of w
            if (name of t) contains \(needle) then
            set current tab of w to t
            set index of w to 1
            activate
            return "found"
            end if
            end repeat
            end repeat
            end tell
            end if
            return "none"
            """
        }
        return """
        if application \(app) is running then
        tell application \(app)
        repeat with w in windows
        set i to 0
        repeat with t in tabs of w
        set i to i + 1
        if (title of t) contains \(needle) then
        set active tab index of w to i
        set index of w to 1
        activate
        return "found"
        end if
        end repeat
        end repeat
        end tell
        end if
        return "none"
        """
    }

    /// The URL of the tab whose title contains the media title ("" when none).
    public static func browserTabURL(_ browser: BrowserKind, titleContains title: String) -> String {
        let app = literal(browser.scriptName)
        let needle = literal(title)
        let nameProperty = browser.isWebKit ? "name" : "title"
        return """
        if application \(app) is running then
        tell application \(app)
        repeat with w in windows
        repeat with t in tabs of w
        if (\(nameProperty) of t) contains \(needle) then return (URL of t)
        end repeat
        end repeat
        end tell
        end if
        return ""
        """
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}

/// Parses the player's state notification (`com.apple.Music.playerInfo`,
/// `com.spotify.client.PlaybackStateChanged`), which needs no Automation permission.
public enum PlayerNotification {
    public static func info(from userInfo: [String: Any], player: ScriptablePlayer, now: Date = Date()) -> NowPlayingInfo? {
        let state = (userInfo["Player State"] as? String ?? "").lowercased()
        guard state != "stopped", let title = userInfo["Name"] as? String, !title.isEmpty else { return nil }
        var info = NowPlayingInfo(title: title,
                                  artist: userInfo["Artist"] as? String ?? "",
                                  album: userInfo["Album"] as? String ?? "",
                                  playing: state == "playing",
                                  bundleID: player.bundleID,
                                  capabilities: player.scriptCapabilities)
        func number(_ key: String) -> Double? { (userInfo[key] as? NSNumber)?.doubleValue }
        switch player {
        case .music:
            info.duration = number("Total Time").map { $0 / 1000 }
            if let id = userInfo["PersistentID"] as? NSNumber { info.itemID = String(id.int64Value, radix: 16, uppercase: true) }
            info.link = userInfo["Store URL"] as? String
        case .spotify:
            info.duration = number("Duration").map { $0 / 1000 }
            info.elapsed = number("Playback Position")
            info.timestamp = info.elapsed == nil ? nil : now
            info.link = userInfo["Track ID"] as? String
            info.itemID = info.link
            info.capabilities.remove(.favorite)
            if info.link?.hasPrefix("spotify:episode:") == true { info.kind = .podcast }
        }
        if info.knownDuration == nil, info.kind == .music { info.kind = .liveStream }
        return info
    }
}

/// Share links.
public enum MediaLinks {
    /// `spotify:track:ID` → `https://open.spotify.com/track/ID` (tracks, episodes, albums, playlists, shows).
    public static func spotifyWebURL(fromURI uri: String) -> String? {
        let parts = uri.split(separator: ":").map(String.init)
        guard parts.count == 3, parts[0] == "spotify", !parts[2].isEmpty,
              ["track", "episode", "album", "playlist", "show", "artist"].contains(parts[1]) else { return nil }
        return "https://open.spotify.com/\(parts[1])/\(parts[2])"
    }

    /// Keeps only the identifying parameters of YouTube and YouTube Music links; other URLs are
    /// returned unchanged.
    public static func cleanedBrowserURL(_ text: String) -> String {
        guard var components = URLComponents(string: text), let host = components.host?.lowercased() else { return text }
        let isYouTube = host == "youtube.com" || host.hasSuffix(".youtube.com")
        guard isYouTube, components.path == "/watch" else { return text }
        let keep: Set<String> = ["v", "t"]
        components.queryItems = components.queryItems?.filter { keep.contains($0.name) }
        if components.queryItems?.isEmpty == true { components.queryItems = nil }
        return components.string ?? text
    }

    /// iTunes Search API query used to resolve an Apple Music share link for title and artist.
    public static func appleMusicLookupURL(title: String, artist: String, country: String = "US") -> URL? {
        var components = URLComponents(string: "https://itunes.apple.com/search")
        components?.queryItems = [
            URLQueryItem(name: "term", value: "\(artist) \(title)".trimmingCharacters(in: .whitespaces)),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "5"),
            URLQueryItem(name: "country", value: country),
        ]
        return components?.url
    }

    /// Picks the best `trackViewUrl` from a search response (exact title match first).
    public static func appleMusicLink(fromSearchResponse data: Data, title: String, artist: String) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = object["results"] as? [[String: Any]] else { return nil }
        func norm(_ s: String) -> String { s.lowercased().trimmingCharacters(in: .whitespaces) }
        let exact = results.first {
            norm($0["trackName"] as? String ?? "") == norm(title) && norm($0["artistName"] as? String ?? "") == norm(artist)
        }
        let chosen = exact ?? results.first { norm($0["trackName"] as? String ?? "") == norm(title) } ?? results.first
        return (chosen?["trackViewUrl"] as? String).map(cleanAppleMusicURL)
    }

    /// Drops tracking parameters (`uo`, `at`) but keeps the track selector `i`.
    public static func cleanAppleMusicURL(_ text: String) -> String {
        guard var components = URLComponents(string: text) else { return text }
        components.queryItems = components.queryItems?.filter { $0.name == "i" }
        if components.queryItems?.isEmpty == true { components.queryItems = nil }
        return components.string ?? text
    }
}
