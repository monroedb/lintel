import Foundation

/// What kind of media is playing (podcast and live-stream indicators).
public enum MediaKind: String, Sendable, Codable, CaseIterable {
    case music, podcast, video, liveStream, other
}

/// Audio-format badge.
public enum AudioFormatBadge: String, Sendable, Codable, CaseIterable {
    case lossless, hiResLossless, dolbyAtmos

    public var label: String {
        switch self {
        case .lossless: return "Lossless"
        case .hiResLossless: return "Hi-Res Lossless"
        case .dolbyAtmos: return "Dolby Atmos"
        }
    }
}

public enum MediaRepeatMode: String, Sendable, Codable, CaseIterable {
    case off, one, all

    /// Order used by the repeat button: off → all → one → off.
    public var next: MediaRepeatMode {
        switch self {
        case .off: return .all
        case .all: return .one
        case .one: return .off
        }
    }
}

/// What the current source can do with the current item.
public struct MediaCapabilities: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let playPause = MediaCapabilities(rawValue: 1 << 0)
    public static let nextPrevious = MediaCapabilities(rawValue: 1 << 1)
    public static let seek = MediaCapabilities(rawValue: 1 << 2)
    /// Back / forward by a fixed interval (podcasts).
    public static let skipInterval = MediaCapabilities(rawValue: 1 << 3)
    public static let rate = MediaCapabilities(rawValue: 1 << 4)
    public static let shuffle = MediaCapabilities(rawValue: 1 << 5)
    public static let repeatMode = MediaCapabilities(rawValue: 1 << 6)
    public static let favorite = MediaCapabilities(rawValue: 1 << 7)
    public static let link = MediaCapabilities(rawValue: 1 << 8)

    public static let transport: MediaCapabilities = [.playPause, .nextPrevious, .seek]
}

/// Commands Lintel sends to the playing app.
public enum MediaCommand: Equatable, Sendable {
    case play, pause, togglePlayPause, next, previous
    /// Absolute position in seconds.
    case seek(to: Double)
    /// Relative jump in seconds (negative = back).
    case skip(by: Double)
    case setRate(Double)
    case setShuffle(Bool)
    case setRepeat(MediaRepeatMode)
    case setFavorite(Bool)

    /// Skips change the track; a track change shortly after one is "user initiated" (no Quick Peek).
    public var changesTrack: Bool { self == .next || self == .previous }
}

/// The incoming track announced during an AutoMix crossfade.
public struct AutoMixIncoming: Equatable, Sendable {
    public var title: String
    public var artist: String
    public var album: String

    public init(title: String, artist: String = "", album: String = "") {
        self.title = title
        self.artist = artist
        self.album = album
    }
}

/// One snapshot of system-wide Now Playing, from any provider (MediaRemote adapter, AppleScript).
/// Times are seconds; `elapsed` is the position at `timestamp`.
public struct NowPlayingInfo: Equatable, Sendable {
    public var title: String
    public var artist: String
    public var album: String
    public var duration: Double?
    public var elapsed: Double?
    public var timestamp: Date?
    /// Playback rate while playing (1 = normal speed).
    public var rate: Double
    public var playing: Bool
    /// The process that reported the media (for browsers, WebKit's GPU process).
    public var bundleID: String?
    public var parentBundleID: String?
    public var processID: Int32?
    public var artworkData: Data?
    public var kind: MediaKind
    public var explicit: Bool?
    public var format: AudioFormatBadge?
    public var favorite: Bool?
    public var shuffle: Bool?
    public var repeatMode: MediaRepeatMode?
    public var capabilities: MediaCapabilities
    /// A shareable link or URI when the source knows one (Spotify URI, store URL).
    public var link: String?
    /// The provider's own item identifier, when it has one.
    public var itemID: String?
    /// AutoMix: the track mixing in, when the source reports one.
    public var incoming: AutoMixIncoming?

    public init(title: String, artist: String = "", album: String = "", duration: Double? = nil,
                elapsed: Double? = nil, timestamp: Date? = nil, rate: Double = 1, playing: Bool = true,
                bundleID: String? = nil, parentBundleID: String? = nil, processID: Int32? = nil,
                artworkData: Data? = nil, kind: MediaKind = .music, explicit: Bool? = nil,
                format: AudioFormatBadge? = nil, favorite: Bool? = nil, shuffle: Bool? = nil,
                repeatMode: MediaRepeatMode? = nil, capabilities: MediaCapabilities = .transport,
                link: String? = nil, itemID: String? = nil, incoming: AutoMixIncoming? = nil) {
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.elapsed = elapsed
        self.timestamp = timestamp
        self.rate = rate
        self.playing = playing
        self.bundleID = bundleID
        self.parentBundleID = parentBundleID
        self.processID = processID
        self.artworkData = artworkData
        self.kind = kind
        self.explicit = explicit
        self.format = format
        self.favorite = favorite
        self.shuffle = shuffle
        self.repeatMode = repeatMode
        self.capabilities = capabilities
        self.link = link
        self.itemID = itemID
        self.incoming = incoming
    }

    /// The app the user knows as the source: the parent app of a helper process, and Safari for
    /// WebKit's GPU process.
    public var sourceBundleID: String? {
        if let parentBundleID, !parentBundleID.isEmpty { return parentBundleID }
        if bundleID == BrowserKind.webKitGPUBundleID { return BrowserKind.safari.bundleID }
        return bundleID
    }

    /// Identifies the item across updates (same fields the adapter uses to tell items apart).
    public var identity: String {
        [sourceBundleID ?? "", title, artist, album].joined(separator: "\u{1F}")
    }

    /// Known, positive duration (nil for live streams and unknown lengths).
    public var knownDuration: Double? {
        guard let duration, duration.isFinite, duration > 0 else { return nil }
        return duration
    }

    /// Playback position at `date`, advancing with the rate while playing, clamped to the duration.
    public func position(at date: Date) -> Double {
        guard let elapsed, elapsed.isFinite else { return 0 }
        var value = elapsed
        if playing, let timestamp {
            let speed = rate > 0 ? rate : 1
            value += max(0, date.timeIntervalSince(timestamp)) * speed
        }
        if let duration = knownDuration { value = min(value, duration) }
        return max(0, value)
    }
}

// MARK: - mediaremote-adapter payloads

/// One value of a `mediaremote-adapter` JSON payload.
public enum AdapterValue: Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    public init?(json: Any) {
        switch json {
        case let string as String:
            self = .string(string)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else {
                self = .number(number.doubleValue)
            }
        case is NSNull:
            self = .null
        default:
            return nil
        }
    }

    public var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var number: Double? {
        switch self {
        case .number(let value): return value
        case .bool(let value): return value ? 1 : 0
        case .string(let value): return Double(value)
        case .null: return nil
        }
    }

    public var bool: Bool? {
        switch self {
        case .bool(let value): return value
        case .number(let value): return value != 0
        default: return nil
        }
    }
}

/// Accumulates the output of `mediaremote-adapter.pl … stream`: each line is
/// `{"type":"data","diff":Bool,"payload":{…}}`. A full payload replaces the state; a diff updates
/// it and `null` removes a key. An empty full payload means nothing is playing.
public struct AdapterStreamState: Sendable {
    public private(set) var payload: [String: AdapterValue] = [:]
    public private(set) var messages = 0

    public init() {}

    /// Applies one JSON line; returns false when it isn't a data message.
    @discardableResult
    public mutating func apply(line: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: line),
              let message = object as? [String: Any] else { return false }
        return apply(message: message)
    }

    @discardableResult
    public mutating func apply(message: [String: Any]) -> Bool {
        guard message["type"] as? String == "data", let raw = message["payload"] as? [String: Any] else { return false }
        let diff = (message["diff"] as? Bool) ?? false
        if !diff { payload.removeAll() }
        for (key, value) in raw {
            guard let converted = AdapterValue(json: value) else { continue }
            if converted == .null {
                payload[key] = nil
            } else {
                payload[key] = converted
            }
        }
        messages += 1
        return true
    }

    public var info: NowPlayingInfo? { NowPlayingInfo(adapterPayload: payload) }
}

extension NowPlayingInfo {
    /// Builds the info from an adapter payload (`--micros` keys preferred). Nil when there is no
    /// title (the adapter's "nothing playing").
    public init?(adapterPayload p: [String: AdapterValue]) {
        guard let title = p["title"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
            return nil
        }
        func seconds(_ micros: String, _ plain: String) -> Double? {
            if let value = p[micros]?.number { return value / 1_000_000 }
            return p[plain]?.number
        }
        let playing = p["playing"]?.bool ?? false
        let duration = seconds("durationMicros", "duration")
        var timestamp: Date?
        if let micros = p["timestampEpochMicros"]?.number {
            timestamp = Date(timeIntervalSince1970: micros / 1_000_000)
        } else if let text = p["timestamp"]?.string {
            timestamp = ISO8601DateFormatter().date(from: text)
        }
        let rawRate = p["playbackRate"]?.number ?? (playing ? 1 : 0)
        // No `.rate`: the adapter's speed command reaches players as rate 1.0 (verified on macOS 27),
        // so the Speed menu isn't offered for the System source.
        var capabilities: MediaCapabilities = [.playPause, .nextPrevious]
        if let duration, duration > 0 { capabilities.insert(.seek) }
        if p["supportsFastForward15Seconds"]?.bool == true || p["supportsRewind15Seconds"]?.bool == true {
            capabilities.insert(.skipInterval)
        }
        var shuffle: Bool?
        if let mode = p["shuffleMode"]?.number {
            shuffle = mode >= 2 // 1 = off, 2 = albums, 3 = tracks
            capabilities.insert(.shuffle)
        }
        var repeatMode: MediaRepeatMode?
        if let mode = p["repeatMode"]?.number {
            repeatMode = mode == 2 ? .one : (mode == 3 ? .all : .off) // 1 = off, 2 = track, 3 = playlist
            capabilities.insert(.repeatMode)
        }
        let kind = MediaKind(mediaType: p["mediaType"]?.string, duration: duration)
        if kind == .podcast { capabilities.insert(.skipInterval) }
        let pid = p["processIdentifier"]?.number.map { Int32(truncatingIfNeeded: Int($0)) }
        self.init(title: title,
                  artist: p["artist"]?.string ?? "",
                  album: p["album"]?.string ?? "",
                  duration: duration,
                  elapsed: seconds("elapsedTimeMicros", "elapsedTime"),
                  timestamp: timestamp,
                  rate: playing ? (rawRate > 0 ? rawRate : 1) : rawRate,
                  playing: playing,
                  bundleID: p["bundleIdentifier"]?.string,
                  parentBundleID: p["parentApplicationBundleIdentifier"]?.string,
                  processID: pid,
                  artworkData: p["artworkData"]?.string.flatMap { Data(base64Encoded: $0, options: .ignoreUnknownCharacters) },
                  kind: kind,
                  favorite: p["isLiked"]?.bool,
                  shuffle: shuffle,
                  repeatMode: repeatMode,
                  capabilities: capabilities,
                  itemID: p["contentItemIdentifier"]?.string ?? p["uniqueIdentifier"]?.number.map { String(Int($0)) })
    }
}

extension MediaKind {
    /// Classifies MediaRemote's media type; a missing duration means a live stream.
    public init(mediaType: String?, duration: Double?) {
        let type = (mediaType ?? "").lowercased()
        if type.contains("podcast") {
            self = .podcast
        } else if duration == nil || (duration ?? 0) <= 0 {
            self = .liveStream
        } else if type.contains("video") || type.contains("movie") || type.contains("tv") {
            self = .video
        } else {
            self = .music
        }
    }
}

/// Elapsed / remaining time labels and the progress bar between them.
/// The bar keeps the reference span (53…286.5 pt on the 345 pt
/// body) and only gives way when a label is wider than the reference labels (≥ 10 min, ≥ 1 h).
public enum PlayerProgressLayout {
    public static func format(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.isFinite ? seconds.rounded(.down) : 0))
        if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60) }
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    /// Bar start and end for the measured label widths.
    public static func bar(width: Double, labelInset: Double, referenceStart: Double, referenceEnd: Double,
                           elapsedWidth: Double, remainingWidth: Double, gap: Double = 6) -> (start: Double, end: Double) {
        let start = max(referenceStart, labelInset + elapsedWidth + gap)
        let end = min(referenceEnd, width - labelInset - remainingWidth - gap)
        return (start, max(start + 20, end))
    }
}
