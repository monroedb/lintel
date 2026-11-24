import AppKit
import ImageIO
import LintelCore
import Observation

/// Runs Now Playing: picks the provider (MediaRemote
/// adapter, AppleScript fallback), filters items, keeps the live activity up while playing and for
/// the idle duration after a pause, asks for media Quick Peeks, polls the position while a
/// player is visible, drives the waveform and sends commands.
@MainActor
final class NowPlayingController {
    private let hub: ActivityHub
    private let settings: SettingsStore
    private var center: NowPlayingCenter { hub.nowPlaying }
    let adapter: MediaRemoteAdapterProvider
    private let music = AppleScriptMediaProvider(player: .music)
    private let spotify = AppleScriptMediaProvider(player: .spotify)
    private let outputs = CoreAudioOutputController()
    private let spectrum = ProcessTapSpectrumSource()
    private var observers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var started = false

    private var selected: MediaProviderKind?
    private var providerInfo: [MediaProviderKind: NowPlayingInfo] = [:]
    /// AppleScript extras (favourite, shuffle, repeat, link, format) for a System item from Music or Spotify.
    private var extras: (identity: String, info: NowPlayingInfo)?
    private var presence = MediaPresence()
    private var tracker = TrackChangeTracker()
    private var polling = PositionPollingPolicy()
    private var gate = LiveWaveformGate()
    private var tappedProcess: pid_t?
    /// A tap that went out of sight stops after `spectrumGrace` (a swap or a glance at another card
    /// page doesn't set it up again).
    private var spectrumStopTask: Task<Void, Never>?
    private(set) var spectrumStops = 0
    private var dipActive = false
    private var presenceTask: Task<Void, Never>?
    private var dipTask: Task<Void, Never>?
    private var autoMixTask: Task<Void, Never>?
    private var noticeTask: Task<Void, Never>?
    private var pollTimer: Timer?
    private var frontmostBundleID: String?
    private var artworkCache: [(key: String, image: NSImage, palette: ArtworkPalette?)] = []
    private var decodingKey: String?

    // Counters and recent events, newest last.
    private(set) var pollCount = 0
    private(set) var peekLog: [String] = []
    private(set) var commandLog: [String] = []
    private(set) var lastVerdict = MediaSourceRules.Verdict.accepted
    private(set) var spectrumStatus = "off"

    /// How long the waveform drops to dots on a track change.
    static let trackChangeDip: Double = 0.6
    /// How long a live waveform's tap keeps running after the last waveform went out of sight:
    /// longer than a visit to Mission Control or a glance at another card page, so those don't set
    /// the tap up again (with 2 s it restarted on every Mission Control visit).
    static let spectrumGrace: Double = 5

    init(hub: ActivityHub, settings: SettingsStore) {
        self.hub = hub
        self.settings = settings
        adapter = MediaRemoteAdapterProvider()
        hub.nowPlaying.controller = self
    }

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true
        observers.append(NotificationCenter.default.addObserver(forName: .lintelSettingDidChange, object: nil,
                                                                queue: .main) { [weak self] note in
            let key = note.userInfo?["key"] as? String
            MainActor.assumeIsolated { self?.settingDidChange(key) }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.shutdown() }
        })
        let workspace = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                        object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                self?.frontmostBundleID = app?.bundleIdentifier
                self?.syncHub()
            }
        })
        frontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier

        adapter.onUpdate = { [weak self] info in self?.providerUpdated(.system, info) }
        adapter.onHealthChange = { [weak self] _ in self?.selectProvider() }
        music.onUpdate = { [weak self] info in self?.providerUpdated(.music, info) }
        spotify.onUpdate = { [weak self] info in self?.providerUpdated(.spotify, info) }
        spectrum.onLevels = { [weak self] levels in self?.receivedLevels(levels) }
        spectrum.onStarted = { [weak self] in
            guard let self else { return }
            self.spectrumStatus = "tapping pid \(self.tappedProcess.map(String.init) ?? "?")"
            self.updateWaveformMode()
        }
        spectrum.onFailure = { [weak self] reason in
            self?.spectrumStatus = "failed: \(reason)"
            self?.tappedProcess = nil
            self?.updateWaveformMode()
        }
        outputs.onChange = { [weak self] in self?.syncOutputs() }
        center.builtInIsLaptop = outputs.builtInIsLaptop
        syncOutputs()
        applyAppearance()
        startSources()
    }

    private func startSources() {
        guard settings[Keys.mediaEnabled] else { return }
        if settings[Keys.mediaSystemAdapter], adapter.health == .unknown {
            adapter.runSelfTest { [weak self] _ in self?.selectProvider() }
        }
        selectProvider()
    }

    private func shutdown() {
        adapter.stop()
        music.stop()
        spotify.stop()
        spectrum.stop()
        outputs.invalidate()
        pollTimer?.invalidate()
    }

    // MARK: Provider selection (settings `automaticMusicApp`, `musicApp`)

    private func provider(_ kind: MediaProviderKind) -> NowPlayingProvider {
        switch kind {
        case .system: return adapter
        case .music: return music
        case .spotify: return spotify
        }
    }

    private func selectProvider() {
        guard settings[Keys.mediaEnabled] else {
            stopSources()
            return
        }
        let adapterWanted = settings[Keys.mediaSystemAdapter]
        // Wait for the self-test before falling back, so AppleScript isn't used needlessly.
        if adapterWanted && (adapter.health == .unknown || adapter.health == .testing) {
            MediaSourceStatus.shared.update(source: nil, adapter: adapter.health.settingsLabel)
            return
        }
        let adapterAvailable = adapterWanted && adapter.health == .available
        let automatic = settings[Keys.mediaAutomaticSource], manual = settings[Keys.mediaSource]
        var running: Set<MediaProviderKind>
        if adapterAvailable && (automatic || manual == .system) {
            running = [.system]
        } else if automatic || manual == .system {
            running = [.music, .spotify]
        } else {
            running = [manual == .spotify ? .spotify : .music]
        }
        for kind in MediaProviderKind.allCases {
            let p = provider(kind)
            if running.contains(kind) {
                if !p.isRunning { p.start() }
            } else if p.isRunning || kind == .system {
                p.stop()
                providerInfo[kind] = nil
            }
        }
        let kind = MediaSourceSelection.provider(automatic: automatic, manual: manual, adapterAvailable: adapterAvailable,
                                                 musicPlaying: music.isPlaying, spotifyPlaying: spotify.isPlaying)
        selected = kind
        center.sourceTitle = kind.title
        MediaSourceStatus.shared.update(source: kind.title, adapter: adapterWanted ? adapter.health.settingsLabel : "Off")
        recompute()
    }

    private func stopSources() {
        for kind in MediaProviderKind.allCases { provider(kind).stop() }
        providerInfo.removeAll()
        selected = nil
        presence.reset()
        spectrum.stop()
        center.track = nil
        syncHub()
        updatePolling()
        MediaSourceStatus.shared.update(source: nil, adapter: adapter.health.settingsLabel)
    }

    private func providerUpdated(_ kind: MediaProviderKind, _ info: NowPlayingInfo?) {
        providerInfo[kind] = info
        // In the AppleScript fallback, follow whichever player plays (automatic source).
        if kind != .system, selected != kind, settings[Keys.mediaAutomaticSource] || settings[Keys.mediaSource] == .system,
           info?.playing == true {
            selectProvider()
            return
        }
        guard kind == selected else { return }
        recompute()
    }

    private func recompute() {
        process(selected.flatMap { providerInfo[$0] })
    }

    // MARK: Pipeline

    private func process(_ raw: NowPlayingInfo?) {
        let now = ProcessInfo.processInfo.systemUptime
        var item: NowPlayingInfo?
        if settings[Keys.mediaEnabled], let raw {
            lastVerdict = MediaSourceRules.verdict(for: raw, ownBundleID: Bundle.main.bundleIdentifier)
            if lastVerdict == .accepted { item = raw }
        }
        if var merged = item, let extras, extras.identity == merged.identity {
            merged.favorite = extras.info.favorite ?? merged.favorite
            merged.shuffle = extras.info.shuffle ?? merged.shuffle
            merged.repeatMode = extras.info.repeatMode ?? merged.repeatMode
            merged.format = extras.info.format ?? merged.format
            merged.link = merged.link ?? extras.info.link
            item = merged
        }
        let change = tracker.observe(identity: item?.identity, playing: item?.playing ?? false, now: now)
        if change != nil { startDip() }
        if let item {
            updateTrack(item)
            fetchExtrasIfNeeded(for: item)
        } else if var track = center.track, track.info.playing {
            // The item went away (player quit, nothing playing): keep it, paused, for the open player.
            track.info.elapsed = track.info.position(at: Date())
            track.info.timestamp = Date()
            track.info.playing = false
            center.track = track
        }
        if center.autoMix.update(incoming: item?.incoming, now: now) { scheduleAutoMixTick() }
        presence.update(hasItem: item != nil, playing: item?.playing ?? false,
                        idleDuration: settings[Keys.mediaIdleDuration], otherLiveActivity: hub.calendar != nil, now: now)
        schedulePresenceTick()
        syncHub()
        if let change {
            // No peek for skips sent by Lintel; the engine decides the rest.
            peekLog.append(String(format: "%.3f %@", now, change.userInitiated ? "skip (no peek)" : "peek"))
            if peekLog.count > 20 { peekLog.removeFirst() }
            hub.peek(.media, userInitiated: change.userInitiated)
        }
        updatePolling()
        updateSpectrum()
        updateWaveformMode()
    }

    private func updateTrack(_ item: NowPlayingInfo) {
        let previous = center.track
        let sameItem = previous?.info.identity == item.identity
        let title = settings[Keys.mediaStripTitleExtras] ? MediaTitleCleaner.clean(item.title) : item.title
        var artwork: NSImage? = sameItem ? previous?.artwork : nil
        var palette: ArtworkPalette? = sameItem ? previous?.palette : nil
        var artworkKey = sameItem ? (previous?.artworkKey ?? "none") : "none:\(item.identity)"
        if let data = item.artworkData {
            let key = Self.hash(data)
            if let cached = artworkCache.first(where: { $0.key == key }) {
                artwork = cached.image
                palette = cached.palette
                artworkKey = key
            } else if decodingKey != key {
                decode(data, key: key)
            }
        }
        var capabilities = item.capabilities
        let scriptPlayer = MediaSourceSelection.extrasPlayer(for: item, provider: selected ?? .system)
        if let scriptPlayer, selected == .system { capabilities.formUnion(scriptPlayer.scriptCapabilities.intersection([.favorite, .link, .shuffle, .repeatMode])) }
        if scriptPlayer == .spotify { capabilities.remove(.favorite) }
        let browser = BrowserKind(bundleID: item.bundleID) ?? BrowserKind(bundleID: item.parentBundleID)
        let canCopyLink = item.link != nil || scriptPlayer != nil || browser != nil
        if canCopyLink { capabilities.insert(.link) }
        let track = NowPlayingCenter.Track(info: item, title: title, artwork: artwork, artworkKey: artworkKey, palette: palette,
                                           appName: appName(for: item.sourceBundleID), capabilities: capabilities,
                                           canCopyLink: canCopyLink)
        if track != previous { center.track = track }
    }

    /// Shows the live activity while playing / within the idle duration, unless hidden because the
    /// source app is in front.
    private func syncHub() {
        guard let track = center.track, presence.visible, !hiddenBySourceApp(track.info) else {
            if hub.media != nil { hub.setMedia(nil) }
            return
        }
        let info = track.info
        let snapshot = MediaSnapshot(identity: info.identity, title: track.title, artist: info.artist, playing: info.playing,
                                     artworkSeed: Self.seed(info.identity), duration: info.knownDuration ?? 0,
                                     elapsed: info.position(at: Date()))
        if let current = hub.media, current.identity == snapshot.identity, current.title == snapshot.title,
           current.artist == snapshot.artist, current.playing == snapshot.playing { return }
        hub.setMedia(snapshot)
    }

    private func hiddenBySourceApp(_ info: NowPlayingInfo) -> Bool {
        guard settings[Keys.mediaHideWhileSourceActive], let front = frontmostBundleID else { return false }
        return [info.sourceBundleID, info.bundleID, info.parentBundleID].contains(front)
    }

    private func schedulePresenceTick() {
        presenceTask?.cancel()
        guard let deadline = presence.hideDeadline else { return }
        let delay = max(0, deadline - ProcessInfo.processInfo.systemUptime)
        presenceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            if self.presence.tick(now: ProcessInfo.processInfo.systemUptime) {
                self.syncHub()
                self.updateSpectrum()
                self.updateWaveformMode()
            }
        }
    }

    private func scheduleAutoMixTick() {
        autoMixTask?.cancel()
        guard center.autoMix.phase == .finishing else { return }
        autoMixTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(AutoMixTransition.finishDuration))
            guard !Task.isCancelled, let self else { return }
            self.center.autoMix.tick(now: ProcessInfo.processInfo.systemUptime)
        }
    }

    // MARK: Artwork

    private func decode(_ data: Data, key: String) {
        decodingKey = key
        let payload = ArtworkPayload(data: data)
        Task.detached(priority: .userInitiated) {
            let decoded = Self.decodeArtwork(payload)
            await MainActor.run { [weak self] in
                guard let self else { return }
                if self.decodingKey == key { self.decodingKey = nil }
                guard let decoded else { return }
                let image = NSImage(cgImage: decoded.image, size: NSSize(width: decoded.image.width, height: decoded.image.height))
                self.artworkCache.append((key, image, decoded.palette))
                if self.artworkCache.count > 6 { self.artworkCache.removeFirst() }
                guard var track = self.center.track, let data = track.info.artworkData, Self.hash(data) == key else { return }
                track.artwork = image
                track.palette = decoded.palette
                track.artworkKey = key
                self.center.track = track
            }
        }
    }

    private struct ArtworkPayload: @unchecked Sendable { let data: Data }
    private struct DecodedArtwork: @unchecked Sendable {
        let image: CGImage
        let palette: ArtworkPalette?
    }

    /// Largest artwork Lintel draws is the open player's, 56 pt (112 px on a 2× display): decoded to
    /// at most this size, not the source's (often 600–1400 px), so each cached image is 64 KB.
    nonisolated static let artworkPixels = 128

    private nonisolated static func decodeArtwork(_ payload: ArtworkPayload) -> DecodedArtwork? {
        guard let source = CGImageSourceCreateWithData(payload.data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceThumbnailMaxPixelSize: artworkPixels,
                                        kCGImageSourceCreateThumbnailWithTransform: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let side = 24
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                          bytesPerRow: side * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        return DecodedArtwork(image: image, palette: drawn ? ArtworkPalette.extract(rgba: pixels, width: side, height: side) : nil)
    }

    /// FNV-1a over the bytes (artwork identity for caching and transitions).
    static func hash(_ data: Data) -> String {
        var value: UInt64 = 0xcbf29ce484222325
        data.withUnsafeBytes { bytes in
            for byte in bytes {
                value ^= UInt64(byte)
                value = value &* 0x100000001b3
            }
        }
        return String(value, radix: 16) + "-\(data.count)"
    }

    static func seed(_ identity: String) -> Int {
        identity.unicodeScalars.reduce(7) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
    }

    private var appNames: [String: String] = [:]

    /// Display name of the source app (cached; looked up once per app).
    private func appName(for bundleID: String?) -> String? {
        guard let bundleID else { return nil }
        if let cached = appNames[bundleID] { return cached }
        let name = Self.lookUpAppName(bundleID)
        if let name { appNames[bundleID] = name }
        return name
    }

    static func lookUpAppName(_ bundleID: String) -> String? {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first, let name = app.localizedName {
            return name
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return bundleID == "com.sashagilliard.lintel.demo" ? "Lintel Demo" : nil
    }

    // MARK: AppleScript extras for System items from Music / Spotify

    private func fetchExtrasIfNeeded(for item: NowPlayingInfo) {
        guard selected == .system,
              let player = MediaSourceSelection.extrasPlayer(for: item, provider: .system),
              extras?.identity != item.identity,
              !NSRunningApplication.runningApplications(withBundleIdentifier: player.bundleID).isEmpty else { return }
        let identity = item.identity
        extras = (identity, item) // mark as requested
        ScriptRunner.run(MediaScripts.stateQuery(player)) { [weak self] reply in
            guard let self, let reply, let info = MediaScripts.parseState(reply, player: player).info,
                  self.extras?.identity == identity else { return }
            self.extras = (identity, info)
            self.recompute()
        }
    }

    // MARK: Waveform (process taps)

    private func startDip() {
        dipActive = true
        dipTask?.cancel()
        dipTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.trackChangeDip))
            guard !Task.isCancelled, let self else { return }
            self.dipActive = false
            self.updateWaveformMode()
        }
    }

    private func updateWaveformMode() {
        let playing = center.track?.info.playing ?? false
        let mode: NowPlayingCenter.WaveformMode
        if !playing || dipActive {
            mode = .flat
        } else if spectrum.isRunning && !gate.showsSimulated {
            mode = .live
        } else {
            mode = .simulated
        }
        if center.waveformMode != mode { center.waveformMode = mode }
    }

    /// Runs the live waveform's process tap while media plays and a waveform is seen: some island
    /// shows one (compact or the open player's) and the displays are awake and unlocked. Out of
    /// sight — a full-screen app, Mission Control, another activity in the slot, a sleeping display,
    /// the lock screen — the tap, its analysis and the 30 Hz bar updates stop (suspended
    /// when hidden); they cost ≈ 0.75 % of a core in the compact island.
    private func updateSpectrum() {
        let info = center.track?.info
        let seen = !center.waveformIslands.isEmpty && !hub.screensQuiet
        let playable = settings[Keys.mediaLiveWaveform] && (info?.playing ?? false) && info?.processID != nil
        if playable, seen, let info, let pid = info.processID {
            spectrumStopTask?.cancel()
            spectrumStopTask = nil
            // The tap starts asynchronously (its setup can wait for the audio-capture prompt).
            if !(spectrum.isRunning || spectrum.isStarting) || tappedProcess != pid {
                settings[Keys.mediaAudioCaptureRequested] = true
                gate = LiveWaveformGate()
                tappedProcess = pid
                spectrumStatus = "starting tap for pid \(pid)"
                spectrum.start(processIDs: [pid], bundlePrefix: info.sourceBundleID)
            }
        } else if spectrum.isRunning || spectrum.isStarting {
            if playable, !hub.screensQuiet, info?.processID == tappedProcess {
                // Only out of sight: give it a moment before tearing the tap down.
                guard spectrumStopTask == nil else { return }
                spectrumStopTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(Self.spectrumGrace))
                    guard !Task.isCancelled, let self else { return }
                    self.spectrumStopTask = nil
                    self.stopSpectrum()
                }
            } else {
                stopSpectrum()
            }
        }
    }

    private func stopSpectrum() {
        spectrumStopTask?.cancel()
        spectrumStopTask = nil
        guard spectrum.isRunning || spectrum.isStarting else { return }
        spectrum.stop()
        spectrumStops += 1
        tappedProcess = nil
        spectrumStatus = "off"
        updateWaveformMode()
    }

    /// An island started or stopped showing a media waveform.
    func waveformDemandChanged() {
        updateSpectrum()
    }

    /// The displays went to sleep or woke, or the session locked or unlocked.
    func screensQuietChanged() {
        updateSpectrum()
    }

    private func receivedLevels(_ levels: [Float]) {
        if gate.update(levels: levels, playing: center.track?.info.playing ?? false, now: ProcessInfo.processInfo.systemUptime) {
            updateWaveformMode()
        }
        center.levelFeed.publish(levels)
    }

    // MARK: Position polling (every 1.0 s, only while a player is visible)

    func setPlayerOpen(_ open: Bool, island: String) {
        if open { polling.openIslands.insert(island) } else { polling.openIslands.remove(island) }
        center.openPlayers = polling.openIslands.count
        updatePolling()
        updateSpectrum()
    }

    private func updatePolling() {
        polling.hasItem = center.track != nil
        if polling.isActive {
            guard pollTimer == nil else { return }
            center.positionTick &+= 1
            let timer = Timer(timeInterval: PositionPollingPolicy.interval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.pollTick() }
            }
            timer.tolerance = 0.05
            RunLoop.main.add(timer, forMode: .common)
            pollTimer = timer
        } else if let timer = pollTimer {
            timer.invalidate()
            pollTimer = nil
        }
    }

    private func pollTick() {
        pollCount += 1
        if let selected { provider(selected).refreshPosition() }
        center.positionTick &+= 1
    }

    // MARK: Commands

    func perform(_ command: MediaCommand) {
        let now = ProcessInfo.processInfo.systemUptime
        commandLog.append(String(format: "%.3f %@", now, String(describing: command)))
        if commandLog.count > 30 { commandLog.removeFirst() }
        if command.changesTrack { tracker.noteUserSkip(now: now) }
        guard let kind = selected, let item = center.track?.info else { return }
        var command = command
        if case .skip(let delta) = command {
            // Sent as a seek: players often don't handle MediaRemote's 15-second commands.
            let target = item.position(at: Date()) + delta
            command = .seek(to: min(item.knownDuration ?? .greatestFiniteMagnitude, max(0, target)))
        }
        let scriptPlayer = MediaSourceSelection.extrasPlayer(for: item, provider: kind)
        switch command {
        case .setFavorite, .setShuffle, .setRepeat:
            if kind == .system, let scriptPlayer {
                // Extras through AppleScript (Automation permission) for Music / Spotify items.
                provider(scriptPlayer == .music ? .music : .spotify).send(command)
                extras = nil
            } else {
                provider(kind).send(command)
            }
        default:
            provider(kind).send(command)
        }
        applyOptimistically(command, to: kind)
    }

    /// Updates the shown state right away; the provider's next report confirms it.
    private func applyOptimistically(_ command: MediaCommand, to kind: MediaProviderKind) {
        guard var info = providerInfo[kind] else { return }
        let now = Date()
        let position = info.position(at: now)
        switch command {
        case .play: info.playing = true
        case .pause: info.playing = false
        case .togglePlayPause: info.playing.toggle()
        case .seek(let target): info.elapsed = max(0, target)
        default: return
        }
        if case .seek = command {} else { info.elapsed = position }
        info.timestamp = now
        if info.playing && info.rate <= 0 { info.rate = 1 }
        providerInfo[kind] = info
        recompute()
    }

    func performExtraControl() {
        guard let info = center.track?.info else { return }
        switch center.appearance.extraControl {
        case .favorite: perform(.setFavorite(!(info.favorite ?? false)))
        case .shuffle: perform(.setShuffle(!(info.shuffle ?? false)))
        case .repeating: perform(.setRepeat((info.repeatMode ?? .off).next))
        case .copyLink: copyLink()
        }
    }

    /// Focuses the source app, or the browser tab playing the media.
    func focusSource(preferTab: Bool = true) {
        guard let info = center.track?.info, let bundleID = info.sourceBundleID else { return }
        commandLog.append(String(format: "%.3f focus %@", ProcessInfo.processInfo.systemUptime, bundleID))
        if preferTab, let browser = BrowserKind(bundleID: info.bundleID) ?? BrowserKind(bundleID: info.parentBundleID) {
            ScriptRunner.run(MediaScripts.focusBrowserTab(browser, titleContains: info.title)) { [weak self] reply in
                if reply != "found" { self?.activate(bundleID: browser.bundleID) }
            }
            return
        }
        activate(bundleID: bundleID)
    }

    private func activate(bundleID: String) {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { return }
        if let url = app.bundleURL {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in }
        } else {
            app.activate()
        }
    }

    /// Copy Link: Spotify URIs, Apple Music share links and browser tab URLs.
    func copyLink() {
        guard let info = center.track?.info else { return }
        resolveLink(for: info) { [weak self] link in
            guard let self else { return }
            guard let link else {
                self.show(notice: "No link for this item")
                return
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(link, forType: .string)
            self.commandLog.append("copied link")
            self.show(notice: "Link copied")
        }
    }

    private func resolveLink(for info: NowPlayingInfo, completion: @escaping @MainActor (String?) -> Void) {
        if let link = info.link {
            if link.hasPrefix("spotify:") { completion(MediaLinks.spotifyWebURL(fromURI: link) ?? link); return }
            if link.hasPrefix("http") { completion(MediaLinks.cleanAppleMusicURL(link)); return }
        }
        let player = MediaSourceSelection.extrasPlayer(for: info, provider: selected ?? .system)
        if player == .spotify {
            ScriptRunner.run(#"if application "Spotify" is running then tell application "Spotify" to return spotify url of current track"#) { reply in
                completion(reply.flatMap { MediaLinks.spotifyWebURL(fromURI: $0) })
            }
            return
        }
        if player == .music {
            guard let url = MediaLinks.appleMusicLookupURL(title: info.title, artist: info.artist,
                                                           country: Locale.current.region?.identifier ?? "US") else {
                completion(nil)
                return
            }
            let title = info.title, artist = info.artist
            Task {
                let data = try? await URLSession.shared.data(from: url).0
                completion(data.flatMap { MediaLinks.appleMusicLink(fromSearchResponse: $0, title: title, artist: artist) })
            }
            return
        }
        if let browser = BrowserKind(bundleID: info.bundleID) ?? BrowserKind(bundleID: info.parentBundleID) {
            ScriptRunner.run(MediaScripts.browserTabURL(browser, titleContains: info.title)) { reply in
                completion(reply.flatMap { $0.isEmpty ? nil : MediaLinks.cleanedBrowserURL($0) })
            }
            return
        }
        completion(nil)
    }

    private func show(notice: String) {
        center.notice = notice
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            self?.center.notice = nil
        }
    }

    // MARK: Output devices

    private func syncOutputs() {
        let devices = orderedOutputs(outputs.devices)
        if center.outputs != devices { center.outputs = devices }
        if center.currentOutputID != outputs.defaultDeviceID { center.currentOutputID = outputs.defaultDeviceID }
    }

    func showOutputMenu() {
        let menu = NSMenu()
        let header = NSMenuItem(title: "Play on", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for device in center.outputs {
            let item = ClosureMenuItem(title: device.name, key: "") { [weak self] in
                guard let self else { return }
                self.commandLog.append("output → \(device.name)")
                self.outputs.select(device)
            }
            item.state = device.id == center.currentOutputID ? .on : .off
            if let symbol = device.symbolNames(builtInIsLaptop: center.builtInIsLaptop).lazy
                .compactMap({ NSImage(systemSymbolName: $0, accessibilityDescription: nil) }).first {
                item.image = symbol
            }
            menu.addItem(item)
        }
        commandLog.append("output menu")
        // Pop up in the island's own window (like the context menu); a free-standing menu would
        // open below the island's shielding-level panel.
        if let event = NSApp.currentEvent, let view = event.window?.contentView {
            NSMenu.popUpContextMenu(menu, with: event, for: view)
        } else {
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
    }

    // MARK: Settings

    private func settingDidChange(_ key: String?) {
        guard let key else { return }
        let all = key == "*"
        if all || key == Keys.mediaEnabled.name {
            if settings[Keys.mediaEnabled] { startSources() } else { stopSources() }
        }
        if all || key == Keys.mediaSystemAdapter.name {
            if settings[Keys.mediaSystemAdapter], adapter.health == .unknown {
                adapter.runSelfTest { [weak self] _ in self?.selectProvider() }
            }
        }
        if all || [Keys.mediaAutomaticSource.name, Keys.mediaSource.name, Keys.mediaSystemAdapter.name].contains(key) {
            selectProvider()
        }
        if all || key == Keys.mediaStripTitleExtras.name || key == Keys.mediaIdleDuration.name { recompute() }
        if all || key == Keys.mediaHideWhileSourceActive.name { syncHub() }
        if all || key == Keys.mediaLiveWaveform.name {
            updateSpectrum()
            updateWaveformMode()
        }
        if all || key.hasPrefix("media.") { applyAppearance() }
    }

    private func applyAppearance() {
        let appearance = NowPlayingCenter.Appearance(titleBadge: settings[Keys.mediaTitleBadge],
                                                     progressStyle: settings[Keys.mediaProgressStyle],
                                                     extraControl: settings[Keys.mediaExtraControl],
                                                     compactWaveform: !settings[Keys.mediaDisableCompactWaveform],
                                                     artworkFlip: !settings[Keys.mediaDisableArtworkFlip])
        if center.appearance != appearance { center.appearance = appearance }
    }

    // MARK: Source menu (context menu "Source")

    var resolvedSource: MediaProviderKind? { selected }

    func chooseSource(automatic: Bool, manual: MediaSourceChoice?) {
        settings[Keys.mediaAutomaticSource] = automatic
        if let manual { settings[Keys.mediaSource] = manual }
    }
}

/// Resolved source and adapter state for the Settings window ("Automatic · System").
@MainActor
@Observable
final class MediaSourceStatus {
    static let shared = MediaSourceStatus()
    private(set) var source: String?
    /// The System source's state, worded for Settings.
    private(set) var adapter = "Not checked yet"

    func update(source: String?, adapter: String) {
        if self.source != source { self.source = source }
        if self.adapter != adapter { self.adapter = adapter }
    }
}
