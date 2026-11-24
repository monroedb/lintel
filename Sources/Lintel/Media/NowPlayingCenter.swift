import AppKit
import LintelCore
import Observation

/// What the island's media views draw and the actions they trigger. Lives on the hub so
/// every island reads the same state; `NowPlayingController` fills it.
@MainActor
@Observable
final class NowPlayingCenter {
    /// The item shown by the player. It stays after the live activity ends, so the open island
    /// can still show (and resume) the last item.
    struct Track: Equatable {
        var info: NowPlayingInfo
        /// Shown title ("Hide media title extras" applied).
        var title: String
        var artwork: NSImage?
        /// Changes whenever the artwork image changes (drives the cross-fade and the flip).
        var artworkKey: String
        var palette: ArtworkPalette?
        var appName: String?
        /// Controls available for this item (provider capabilities plus AppleScript extras).
        var capabilities: MediaCapabilities
        /// Whether Copy Link can resolve a link for this item.
        var canCopyLink: Bool
    }

    struct Appearance: Equatable {
        var titleBadge: MediaTitleBadge = .explicit
        var progressStyle: MediaProgressStyle = .mono
        var extraControl: MediaExtraControl = .shuffle
        var compactWaveform = true
        var artworkFlip = true
    }

    enum WaveformMode: String {
        /// Dots: paused, or briefly after a track change.
        case flat
        /// Animated bars (no live audio).
        case simulated
        /// Bars from the process tap.
        case live
    }

    var track: Track?
    var appearance = Appearance()
    /// Bumped once a second while the position is polled; views re-read the position on change.
    var positionTick = 0
    var waveformMode: WaveformMode = .flat
    var outputs: [AudioOutputDevice] = []
    var currentOutputID: UInt32?
    var builtInIsLaptop = true
    var autoMix = AutoMixTransition()
    /// Resolved source, e.g. "System" (shown as "Automatic · System" in Settings).
    var sourceTitle = "System"
    /// Number of islands showing the open player (the waveform there animates only while open).
    var openPlayers = 0
    /// Short confirmation shown in the player (e.g. "Link copied").
    var notice: String?

    @ObservationIgnored weak var controller: NowPlayingController?
    /// Live waveform levels, delivered straight to the waveform layers (no SwiftUI updates).
    @ObservationIgnored let levelFeed = WaveformLevelFeed()

    var currentOutput: AudioOutputDevice? { outputs.first { $0.id == currentOutputID } }

    /// Position now, honouring a drag in progress.
    func position(at date: Date = Date()) -> Double {
        _ = positionTick
        return track?.info.position(at: date) ?? 0
    }

    // MARK: Actions (forwarded to the controller)

    func perform(_ command: MediaCommand) { controller?.perform(command) }
    func togglePlayPause() { controller?.perform(.togglePlayPause) }
    func focusSource() { controller?.focusSource() }
    func copyLink() { controller?.copyLink() }
    func showSourceApp() { controller?.focusSource(preferTab: false) }
    func performExtraControl() { controller?.performExtraControl() }
    func showOutputMenu() { controller?.showOutputMenu() }

    /// Called by an island when its open card appears or goes away (position polling).
    func setPlayerOpen(_ open: Bool, island: String) { controller?.setPlayerOpen(open, island: island) }

    /// Islands showing a media waveform (compact or the open player's), as they report it. Kept here,
    /// not in the controller, so a report made before the controller exists (islands are built
    /// first) isn't lost.
    @ObservationIgnored private(set) var waveformIslands: Set<String> = []

    /// Called by an island when it starts or stops showing a media waveform: the live waveform's
    /// audio tap runs only while one is seen.
    func setWaveformShown(_ shown: Bool, island: String) {
        let changed = shown ? waveformIslands.insert(island).inserted : waveformIslands.remove(island) != nil
        if changed { controller?.waveformDemandChanged() }
    }
}

/// Fans live waveform levels out to the visible waveform layers.
@MainActor
final class WaveformLevelFeed {
    private var subscribers: [ObjectIdentifier: (weak: WeakBox, handler: ([Float]) -> Void)] = [:]
    private(set) var latest: [Float] = []
    /// Level sets delivered to a waveform.
    private(set) var deliveries = 0

    final class WeakBox {
        weak var object: AnyObject?
        init(_ object: AnyObject) { self.object = object }
    }

    func subscribe(_ owner: AnyObject, handler: @escaping ([Float]) -> Void) {
        subscribers[ObjectIdentifier(owner)] = (WeakBox(owner), handler)
    }

    func unsubscribe(_ owner: AnyObject) {
        subscribers[ObjectIdentifier(owner)] = nil
    }

    func publish(_ levels: [Float]) {
        latest = levels
        for (key, entry) in subscribers {
            if entry.weak.object == nil {
                subscribers[key] = nil
            } else {
                deliveries += 1
                entry.handler(levels)
            }
        }
    }
}
