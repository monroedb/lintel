import Foundation

/// Whether the media live activity is shown: from the moment
/// playback runs, and for the idle duration after it pauses or the item disappears. A paused item
/// never brings the activity up by itself. With another live activity on the island the media part
/// leaves sooner (the calendar glyph returned within about 1 s of pausing).
public struct MediaPresence: Equatable, Sendable {
    /// Grace used while another live activity shares the island (measured ≈ 1 s).
    public static let sharedIslandGrace: Double = 1

    public private(set) var visible = false
    public private(set) var hideDeadline: Double?

    public init() {}

    public static func grace(idleDuration: Double, otherLiveActivity: Bool) -> Double {
        let idle = max(0, idleDuration)
        return otherLiveActivity ? min(idle, sharedIslandGrace) : idle
    }

    /// Returns true when `visible` changed.
    @discardableResult
    public mutating func update(hasItem: Bool, playing: Bool, idleDuration: Double, otherLiveActivity: Bool,
                                now: Double) -> Bool {
        let before = visible
        if hasItem && playing {
            visible = true
            hideDeadline = nil
        } else if visible {
            if hideDeadline == nil {
                hideDeadline = now + Self.grace(idleDuration: idleDuration, otherLiveActivity: otherLiveActivity)
            }
            if let deadline = hideDeadline, now >= deadline {
                visible = false
                hideDeadline = nil
            }
        } else {
            hideDeadline = nil
        }
        return before != visible
    }

    /// Ends the activity once the grace has run out; returns true when `visible` changed.
    @discardableResult
    public mutating func tick(now: Double) -> Bool {
        guard visible, let deadline = hideDeadline, now >= deadline else { return false }
        visible = false
        hideDeadline = nil
        return true
    }

    /// Ends the activity immediately (Now Playing switched off, source app quit).
    public mutating func reset() {
        visible = false
        hideDeadline = nil
    }
}

/// Classifies track changes for Quick Peek: a change is "user initiated" when it
/// follows a skip sent by Lintel within a short window; only changes while playing are reported.
public struct TrackChangeTracker: Equatable, Sendable {
    public static let userSkipWindow: Double = 4

    public struct Change: Equatable, Sendable {
        public var from: String
        public var to: String
        public var userInitiated: Bool

        public init(from: String, to: String, userInitiated: Bool) {
            self.from = from
            self.to = to
            self.userInitiated = userInitiated
        }
    }

    public private(set) var lastIdentity: String?
    public private(set) var lastUserSkip: Double?

    public init() {}

    public mutating func noteUserSkip(now: Double) {
        lastUserSkip = now
    }

    public mutating func observe(identity: String?, playing: Bool, now: Double) -> Change? {
        guard let identity else { return nil }
        defer { lastIdentity = identity }
        guard let previous = lastIdentity, previous != identity, playing else { return nil }
        let userInitiated = lastUserSkip.map { now - $0 <= Self.userSkipWindow } ?? false
        if userInitiated { lastUserSkip = nil }
        return Change(from: previous, to: identity, userInitiated: userInitiated)
    }
}

/// When the playback position is refreshed: every 1.0 s, but only while an
/// island is open or the lock-screen player is visible; otherwise there is no polling.
public struct PositionPollingPolicy: Equatable, Sendable {
    public static let interval: Double = 1.0

    public var openIslands: Set<String> = []
    public var lockScreenPlayerVisible = false
    public var hasItem = false

    public init() {}

    public var isActive: Bool {
        hasItem && (!openIslands.isEmpty || lockScreenPlayerVisible)
    }
}

/// Phases of the AutoMix transition animation: an incoming track is
/// announced (item changed), the crossfade runs (active), then winds down (finishing) and the
/// player returns to idle.
public enum AutoMixPhase: String, Sendable, CaseIterable {
    case idle, itemChanged, active, finishing
}

public struct AutoMixTransition: Equatable, Sendable {
    /// How long the finishing phase lasts before returning to idle.
    public static let finishDuration: Double = 0.6

    public private(set) var phase: AutoMixPhase = .idle
    public private(set) var incoming: AutoMixIncoming?
    public private(set) var finishDeadline: Double?

    public init() {}

    /// Feeds the provider's incoming track (nil when no crossfade is announced). Returns true when
    /// the phase changed.
    @discardableResult
    public mutating func update(incoming newIncoming: AutoMixIncoming?, now: Double) -> Bool {
        let before = phase
        switch (phase, newIncoming) {
        case (.idle, let next?), (.finishing, let next?):
            incoming = next
            phase = .itemChanged
            finishDeadline = nil
        case (.itemChanged, let next?):
            incoming = next
            phase = .active
        case (.active, let next?):
            incoming = next
        case (.itemChanged, nil), (.active, nil):
            phase = .finishing
            finishDeadline = now + Self.finishDuration
        case (.idle, nil), (.finishing, nil):
            break
        }
        return before != phase
    }

    @discardableResult
    public mutating func tick(now: Double) -> Bool {
        guard phase == .finishing, let deadline = finishDeadline, now >= deadline else { return false }
        phase = .idle
        incoming = nil
        finishDeadline = nil
        return true
    }
}

/// Which provider supplies Now Playing (settings `automaticMusicApp`,
/// `musicApp`). The MediaRemote adapter ("System") covers every app; Music and Spotify can also be
/// read through AppleScript, which adds favourite, shuffle, repeat-one and share links.
public enum MediaProviderKind: String, Sendable, CaseIterable {
    case system, music, spotify

    public var title: String {
        switch self {
        case .system: return "System"
        case .music: return "Music"
        case .spotify: return "Spotify"
        }
    }

    public var scriptablePlayer: ScriptablePlayer? {
        switch self {
        case .system: return nil
        case .music: return .music
        case .spotify: return .spotify
        }
    }
}

public enum MediaSourceSelection {
    /// The provider to read from.
    /// - automatic: follows the playing app. With the adapter available that is the System source
    ///   (it sees every app); without it, whichever of Music and Spotify is playing (Music first).
    /// - manual: the chosen source; System falls back to the AppleScript sources when the adapter
    ///   is unavailable.
    public static func provider(automatic: Bool, manual: MediaSourceChoice, adapterAvailable: Bool,
                                musicPlaying: Bool, spotifyPlaying: Bool) -> MediaProviderKind {
        if automatic || manual == .system {
            if adapterAvailable { return .system }
            if spotifyPlaying && !musicPlaying { return .spotify }
            return .music
        }
        return manual == .spotify ? .spotify : .music
    }

    /// The AppleScript player that adds extras (favourite, repeat one, links) for an item read
    /// through the System source: only when the item comes from Music or Spotify.
    public static func extrasPlayer(for info: NowPlayingInfo?, provider: MediaProviderKind) -> ScriptablePlayer? {
        if let player = provider.scriptablePlayer { return player }
        guard let source = info?.sourceBundleID else { return nil }
        return ScriptablePlayer.allCases.first { $0.bundleID == source }
    }
}
