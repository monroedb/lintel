import Foundation
import LintelCore

/// Checks for Now Playing model, adapter payloads, filters, presence and peeks,
/// polling, AutoMix phases, source selection, AppleScript sources, links, palette, spectrum and
/// output devices.
func runMediaChecks() {
    m4SettingsChecks()
    m4AdapterChecks()
    m4RulesChecks()
    m4PresenceChecks()
    m4ProgressChecks()
    m4SourceChecks()
    m4ScriptChecks()
    m4LinkChecks()
    m4PaletteChecks()
    m4SpectrumChecks()
    m4OutputChecks()
}

// MARK: - Settings (Now Playing tab defaults)

private func m4SettingsChecks() {
    check(Keys.mediaEnabled.defaultValue == true, "enableNowPlaying defaults on")
    check(Keys.mediaIdleDuration.defaultValue == 3, "idleDuration defaults to 3 s")
    check(Keys.mediaTitleBadge.defaultValue == .explicit, "songTitleBadge defaults to explicit")
    check(Keys.mediaProgressStyle.defaultValue == .mono, "progressStyle defaults to mono")
    check(Keys.mediaLiveWaveform.defaultValue == false, "useLiveWaveform defaults off")
    check(Keys.mediaAudioCaptureRequested.defaultValue == false, "hasPromptedAudioPermission defaults off")
    check(Keys.mediaDisableCompactWaveform.defaultValue == false, "disableWaveform defaults off")
    check(Keys.mediaDisableArtworkFlip.defaultValue == false, "disableAlbumArtFlip defaults off")
    check(Keys.mediaHideWhileSourceActive.defaultValue == false, "hideWhileSourceIsActive defaults off")
    check(Keys.mediaStripTitleExtras.defaultValue == false, "hideSongTitleExtras defaults off")
    check(Keys.mediaExtraControl.defaultValue == .shuffle, "controlChoice defaults to shuffle")
    check(Keys.mediaAutomaticSource.defaultValue == true, "automaticMusicApp defaults on")
    check(Keys.mediaSource.defaultValue == .system, "musicApp defaults to system")
    check(Keys.mediaPeek.defaultValue && Keys.mediaPeekOnChange.defaultValue && Keys.mediaPeekDuration.defaultValue == 2,
          "media Quick Peek on, when media changes, 2 s")
    check(MediaTitleBadge.allCases.map(\.rawValue) == ["none", "explicit", "format"], "badge choices")
    check(MediaProgressStyle.allCases.map(\.rawValue) == ["mono", "color", "gradient"], "progress choices")
    check(MediaExtraControl.allCases.map(\.rawValue) == ["favorite", "shuffle", "repeating", "copyLink"], "extra-control choices")
    check(MediaSourceChoice.allCases.map(\.rawValue) == ["music", "spotify", "system"], "source choices")
    check(MediaSourceChoice.decode("spotify") == .spotify && MediaSourceChoice.decode("tidal") == nil, "source decoding")
    check(Set([Keys.mediaEnabled.name, Keys.mediaIdleDuration.name, Keys.mediaTitleBadge.name, Keys.mediaProgressStyle.name,
               Keys.mediaLiveWaveform.name, Keys.mediaDisableCompactWaveform.name, Keys.mediaDisableArtworkFlip.name,
               Keys.mediaHideWhileSourceActive.name, Keys.mediaStripTitleExtras.name, Keys.mediaExtraControl.name,
               Keys.mediaAutomaticSource.name, Keys.mediaSource.name]).allSatisfy { $0.hasPrefix("media.") },
          "media keys are namespaced under media.")
}

// MARK: - Adapter payloads (JSON lines from `mediaremote-adapter.pl … stream`)

private func line(_ object: [String: Any]) -> Data {
    (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
}

private func m4AdapterChecks() {
    var state = AdapterStreamState()
    let artwork = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])
    let full: [String: Any] = [
        "type": "data", "diff": false,
        "payload": [
            "bundleIdentifier": "com.example.player", "processIdentifier": 4242, "playing": true,
            "title": "Copper Lines", "artist": "Lintel Test Signal", "album": "Test Tones",
            "durationMicros": 24_000_000, "elapsedTimeMicros": 6_500_000, "timestampEpochMicros": 1_800_000_000_000_000,
            "playbackRate": 1, "artworkMimeType": "image/png", "artworkData": artwork.base64EncodedString(),
            "mediaType": "MRMediaRemoteMediaTypeMusic", "shuffleMode": 3, "repeatMode": 2,
            "supportsFastForward15Seconds": false, "contentItemIdentifier": "item-1",
        ] as [String: Any],
    ]
    check(state.apply(line: line(full)), "full payload applied")
    let info = state.info
    check(info?.title == "Copper Lines" && info?.artist == "Lintel Test Signal" && info?.album == "Test Tones",
          "title, artist, album parsed")
    check(info?.duration == 24 && info?.elapsed == 6.5, "micro-second times converted to seconds")
    check(info?.timestamp == Date(timeIntervalSince1970: 1_800_000_000), "epoch timestamp converted")
    check(info?.playing == true && info?.rate == 1, "playing state and rate")
    check(info?.bundleID == "com.example.player" && info?.processID == 4242, "bundle and process identifiers")
    check(info?.artworkData == artwork, "base64 artwork decoded")
    check(info?.kind == .music, "music media type")
    check(info?.shuffle == true && info?.repeatMode == .one, "shuffle (3 = tracks) and repeat (2 = track) modes")
    check(info?.capabilities.isSuperset(of: [.playPause, .nextPrevious, .seek, .shuffle, .repeatMode]) == true,
          "capabilities from the payload")
    check(info?.capabilities.contains(.rate) == false, "no speed control through the adapter (rate arrives as 1.0)")
    check(info?.capabilities.contains(.skipInterval) == false, "no interval skip unless supported")
    check(info?.itemID == "item-1", "content item identifier")

    // Diff: changed keys update, null removes.
    check(state.apply(line: line(["type": "data", "diff": true,
                                  "payload": ["playing": false, "elapsedTimeMicros": 9_000_000, "artworkData": NSNull()]])),
          "diff payload applied")
    check(state.info?.playing == false && state.info?.elapsed == 9 && state.info?.artworkData == nil && state.info?.title == "Copper Lines",
          "diff merges into the previous payload and null removes keys")
    check(state.info?.rate == 1, "paused item keeps the reported rate")
    check(state.apply(line: line(["type": "data", "diff": false, "payload": [String: Any]()])) && state.info == nil,
          "empty full payload means nothing is playing")
    check(!state.apply(line: Data("not json".utf8)) && !state.apply(line: line(["type": "other"])), "non-data lines ignored")
    check(state.messages == 3, "message count")

    // Kinds and identifiers.
    let podcast = NowPlayingInfo(adapterPayload: ["title": .string("Episode 4"), "playing": .bool(true),
                                                  "mediaType": .string("kMRMediaRemoteNowPlayingInfoTypePodcast"),
                                                  "durationMicros": .number(1_800_000_000)])
    check(podcast?.kind == .podcast && podcast?.capabilities.contains(.skipInterval) == true, "podcast kind adds interval skip")
    let live = NowPlayingInfo(adapterPayload: ["title": .string("Radio"), "playing": .bool(true)])
    check(live?.kind == .liveStream && live?.capabilities.contains(.seek) == false, "no duration → live stream, no seek")
    check(NowPlayingInfo(adapterPayload: ["title": .string("  "), "playing": .bool(true)]) == nil, "blank title → nothing")
    var web = NowPlayingInfo(title: "Clip", bundleID: BrowserKind.webKitGPUBundleID)
    check(web.sourceBundleID == "com.apple.Safari", "WebKit's GPU process is attributed to Safari")
    web.parentBundleID = "com.apple.SafariTechnologyPreview"
    check(web.sourceBundleID == "com.apple.SafariTechnologyPreview", "parent application bundle ID wins")

    // Position clock.
    let t0 = Date(timeIntervalSince1970: 1000)
    var clock = NowPlayingInfo(title: "T", duration: 100, elapsed: 10, timestamp: t0, rate: 1, playing: true)
    check(abs(clock.position(at: t0.addingTimeInterval(5)) - 15) < 1e-9, "position advances while playing")
    clock.rate = 2
    check(abs(clock.position(at: t0.addingTimeInterval(5)) - 20) < 1e-9, "position follows the playback rate")
    check(clock.position(at: t0.addingTimeInterval(500)) == 100, "position clamped to the duration")
    clock.playing = false
    check(clock.position(at: t0.addingTimeInterval(5)) == 10, "paused position doesn't advance")
    let a = NowPlayingInfo(title: "Same", artist: "A", elapsed: 1, bundleID: "x")
    var b = a
    b.elapsed = 50
    check(a.identity == b.identity, "identity ignores the position")
    b.title = "Other"
    check(a.identity != b.identity, "identity changes with the title")
}

// MARK: - Filters and title extras

private func m4RulesChecks() {
    func item(_ duration: Double?, _ bundle: String = "com.example.player") -> NowPlayingInfo {
        NowPlayingInfo(title: "X", duration: duration, bundleID: bundle)
    }
    check(MediaSourceRules.verdict(for: item(2.9)) == .tooShort, "media shorter than 3 s ignored")
    check(MediaSourceRules.verdict(for: item(3)) == .accepted, "3 s media accepted")
    check(MediaSourceRules.verdict(for: item(nil)) == .accepted, "unknown length (live) accepted")
    for app in ["net.whatsapp.WhatsApp", "org.whispersystems.signal-desktop", "com.tinyspeck.slackmacgap",
                "com.microsoft.teams2", "com.tencent.xinWeChat"] {
        check(MediaSourceRules.verdict(for: item(40, app)) == .messagingApp, "messaging app excluded: \(app)")
    }
    check(MediaSourceRules.verdict(for: item(40, "com.tinyspeck.slackmacgap.helper")) == .messagingApp, "messaging helper excluded")
    var parented = item(40, "com.apple.WebKit.GPU")
    parented.parentBundleID = "com.microsoft.teams2"
    check(MediaSourceRules.verdict(for: parented) == .messagingApp, "messaging parent app excluded")
    check(MediaSourceRules.verdict(for: item(40, "com.slack.notreally")) == .accepted, "prefix match needs a dot boundary")
    check(MediaSourceRules.verdict(for: item(40, "com.sashagilliard.lintel"), ownBundleID: "com.sashagilliard.lintel") == .ownApp,
          "Lintel's own sounds are never a source")

    let cases: [(String, String)] = [
        ("Good Vibrations (Remastered 2001)", "Good Vibrations"),
        ("Song Name - Remastered 2011", "Song Name"),
        ("Song Name - 2011 Remaster", "Song Name"),
        ("Track (feat. Someone)", "Track"),
        ("Track [ft. Someone & Other]", "Track"),
        ("Track feat. Someone", "Track"),
        ("Album Cut (Deluxe Edition)", "Album Cut"),
        ("Single (Radio Edit)", "Single"),
        ("Artist - Song (Official Music Video)", "Artist - Song"),
        ("Live Forever - Live at Wembley", "Live Forever - Live at Wembley"),
        ("Remix (Someone Remix)", "Remix (Someone Remix)"),
        ("(feat. Only)", "(feat. Only)"),
        ("Plain title", "Plain title"),
    ]
    for (input, expected) in cases {
        let cleaned = MediaTitleCleaner.clean(input)
        check(cleaned == expected, "title extras: '\(input)' → '\(expected)' (got '\(cleaned)')")
    }

    check(BrowserKind(bundleID: "com.apple.Safari") == .safari && BrowserKind(bundleID: "com.google.Chrome") == .chrome,
          "Safari and Chrome recognised")
    check(BrowserKind(bundleID: "company.thebrowser.dia") == .dia
          && BrowserKind(bundleID: "com.apple.SafariTechnologyPreview") == .safariTechnologyPreview, "Dia and STP recognised")
    check(BrowserKind(bundleID: BrowserKind.webKitGPUBundleID) == .safari && BrowserKind(bundleID: "org.mozilla.firefox") == nil,
          "GPU process → Safari; other browsers not scripted")
}

// MARK: - Presence (idle duration), track changes, polling, AutoMix

private func m4PresenceChecks() {
    var p = MediaPresence()
    check(!p.update(hasItem: true, playing: false, idleDuration: 3, otherLiveActivity: false, now: 0) && !p.visible,
          "a paused item never brings the activity up")
    check(p.update(hasItem: true, playing: true, idleDuration: 3, otherLiveActivity: false, now: 1) && p.visible, "playing shows it")
    p.update(hasItem: true, playing: false, idleDuration: 3, otherLiveActivity: false, now: 10)
    check(p.visible && p.hideDeadline == 13, "pause keeps it for the idle duration (3 s)")
    check(!p.tick(now: 12.9) && p.visible, "still shown before the idle duration ends")
    check(p.tick(now: 13) && !p.visible, "hidden once the idle duration ends")
    p.update(hasItem: true, playing: true, idleDuration: 3, otherLiveActivity: false, now: 20)
    p.update(hasItem: true, playing: false, idleDuration: 3, otherLiveActivity: false, now: 21)
    p.update(hasItem: true, playing: true, idleDuration: 3, otherLiveActivity: false, now: 22)
    check(p.visible && p.hideDeadline == nil, "resuming within the idle duration keeps it")
    p.update(hasItem: true, playing: false, idleDuration: 3, otherLiveActivity: true, now: 30)
    check(p.hideDeadline == 31, "with another live activity the media part leaves after ≈ 1 s")
    p.tick(now: 31)
    p.update(hasItem: true, playing: true, idleDuration: 3, otherLiveActivity: false, now: 40)
    p.update(hasItem: false, playing: false, idleDuration: 3, otherLiveActivity: false, now: 41)
    check(p.visible && p.hideDeadline == 44, "an item disappearing also gets the idle duration")
    check(MediaPresence.grace(idleDuration: 0.5, otherLiveActivity: true) == 0.5, "shared-island grace never exceeds the idle duration")
    p.reset()
    check(!p.visible && p.hideDeadline == nil, "reset hides immediately")

    var t = TrackChangeTracker()
    check(t.observe(identity: "a", playing: true, now: 0) == nil, "first item is not a change")
    check(t.observe(identity: "a", playing: true, now: 1) == nil, "same item is not a change")
    check(t.observe(identity: "b", playing: true, now: 2) == .init(from: "a", to: "b", userInitiated: false), "natural change detected")
    t.noteUserSkip(now: 10)
    check(t.observe(identity: "c", playing: true, now: 11)?.userInitiated == true, "a change right after Lintel's skip is user initiated")
    check(t.observe(identity: "d", playing: true, now: 12)?.userInitiated == false, "the skip marker is used once")
    t.noteUserSkip(now: 20)
    check(t.observe(identity: "e", playing: true, now: 25)?.userInitiated == false, "a change long after a skip is natural")
    check(t.observe(identity: "f", playing: false, now: 26) == nil && t.lastIdentity == "f", "paused changes aren't reported but tracked")
    check(t.observe(identity: nil, playing: false, now: 27) == nil && t.lastIdentity == "f", "nothing playing keeps the last item")

    // Quick Peek end to end with the activity engine.
    var engine = ActivityEngine()
    engine.setLive(.media, active: true, identity: "a", now: 0)
    engine.setLive(.media, active: true, identity: "b", now: 1)
    check(!engine.requestPeek(.media, userInitiated: false, now: 1), "no peek while Now Playing is already shown")
    engine.setLive(.calendar, active: true, identity: "event", now: 2)
    engine.setLive(.media, active: true, identity: "c", now: 3)
    check(engine.requestPeek(.media, userInitiated: false, now: 3) && engine.compactPresentation == .peek(.media),
          "natural change while another activity shares the island peeks")
    engine.tick(now: 5)
    check(engine.compactPresentation == .live([.media, .calendar]), "peek ends after the 2 s peek duration")
    check(!engine.requestPeek(.media, userInitiated: true, now: 6), "no peek for a skip from Lintel")
    engine.setExpanded(true)
    check(!engine.requestPeek(.media, userInitiated: false, now: 7), "no peek while the island is open")

    var polling = PositionPollingPolicy()
    check(!polling.isActive, "no polling by default")
    polling.openIslands.insert("display-1")
    check(!polling.isActive, "no polling without an item")
    polling.hasItem = true
    check(polling.isActive && PositionPollingPolicy.interval == 1.0, "polls every 1.0 s while an island is open")
    polling.openIslands.removeAll()
    check(!polling.isActive, "polling stops when the island closes")
    polling.lockScreenPlayerVisible = true
    check(polling.isActive, "polls while the lock-screen player is visible")

    var mix = AutoMixTransition()
    let incoming = AutoMixIncoming(title: "Next", artist: "B")
    check(mix.update(incoming: incoming, now: 0) && mix.phase == .itemChanged && mix.incoming == incoming, "AutoMix: item changed")
    check(mix.update(incoming: incoming, now: 1) && mix.phase == .active, "AutoMix: active while the crossfade runs")
    check(mix.update(incoming: nil, now: 5) && mix.phase == .finishing, "AutoMix: finishing when the incoming info clears")
    check(!mix.tick(now: 5.5) && mix.tick(now: 5 + AutoMixTransition.finishDuration) && mix.phase == .idle && mix.incoming == nil,
          "AutoMix: back to idle")
    check(!mix.update(incoming: nil, now: 9), "AutoMix: idle stays idle")
}

// MARK: - Progress row layout

private func m4ProgressChecks() {
    typealias P = PlayerProgressLayout
    check(P.format(129) == "2:09" && P.format(0) == "0:00" && P.format(59.9) == "0:59", "m:ss times")
    check(P.format(600) == "10:00" && P.format(3725) == "1:02:05" && P.format(-3) == "0:00" && P.format(.nan) == "0:00",
          "long, negative and invalid times")
    let reference = P.bar(width: 345, labelInset: 22, referenceStart: 53, referenceEnd: 286.5, elapsedWidth: 22, remainingWidth: 27)
    check(reference.start == 53 && reference.end == 286.5, "reference labels keep the reference bar (53…286.5)")
    let long = P.bar(width: 345, labelInset: 22, referenceStart: 53, referenceEnd: 286.5, elapsedWidth: 28, remainingWidth: 34)
    check(long.start == 56 && long.end == 283, "wider labels (≥ 10 min) shorten the bar instead of truncating")
    let hours = P.bar(width: 345, labelInset: 22, referenceStart: 53, referenceEnd: 286.5, elapsedWidth: 38, remainingWidth: 43)
    check(hours.start == 66 && hours.end == 274, "hour-long labels fit")
}

// MARK: - Source selection

private func m4SourceChecks() {
    typealias S = MediaSourceSelection
    check(S.provider(automatic: true, manual: .music, adapterAvailable: true, musicPlaying: true, spotifyPlaying: false) == .system,
          "automatic with the adapter → System (sees every app)")
    check(S.provider(automatic: true, manual: .system, adapterAvailable: false, musicPlaying: false, spotifyPlaying: false) == .music,
          "automatic without the adapter → Music by default")
    check(S.provider(automatic: true, manual: .system, adapterAvailable: false, musicPlaying: false, spotifyPlaying: true) == .spotify,
          "automatic without the adapter follows Spotify when it plays")
    check(S.provider(automatic: false, manual: .spotify, adapterAvailable: true, musicPlaying: false, spotifyPlaying: false) == .spotify,
          "manual Spotify")
    check(S.provider(automatic: false, manual: .music, adapterAvailable: true, musicPlaying: false, spotifyPlaying: true) == .music,
          "manual Music")
    check(S.provider(automatic: false, manual: .system, adapterAvailable: false, musicPlaying: false, spotifyPlaying: true) == .spotify,
          "manual System falls back to AppleScript when the adapter fails its test")
    let fromMusic = NowPlayingInfo(title: "X", bundleID: "com.apple.Music")
    check(S.extrasPlayer(for: fromMusic, provider: .system) == .music, "System item from Music gets AppleScript extras")
    check(S.extrasPlayer(for: NowPlayingInfo(title: "X", bundleID: "com.tidal.desktop"), provider: .system) == nil,
          "no extras for other apps (none shown with TIDAL)")
    check(S.extrasPlayer(for: nil, provider: .spotify) == .spotify, "Spotify source uses its own script")
    check(ScriptablePlayer.music.scriptCapabilities.contains(.favorite) && !ScriptablePlayer.spotify.scriptCapabilities.contains(.favorite),
          "favourite only through Music")
    check(MediaRepeatMode.off.next == .all && MediaRepeatMode.all.next == .one && MediaRepeatMode.one.next == .off, "repeat cycle")
    check(MediaCommand.next.changesTrack && MediaCommand.previous.changesTrack && !MediaCommand.togglePlayPause.changesTrack,
          "only skips mark user-initiated track changes")
}

// MARK: - AppleScript sources (Music, Spotify, browsers)

private func m4ScriptChecks() {
    check(MediaScripts.literal(#"He said "hi" \ bye"#) == #""He said \"hi\" \\ bye""#, "AppleScript string literal escaping")
    for player in ScriptablePlayer.allCases {
        let query = MediaScripts.stateQuery(player)
        check(query.hasPrefix("if application \"\(player.scriptName)\" is running then"), "\(player) query never launches the player")
        check(query.contains("return \"notRunning\""), "\(player) query reports a closed player")
    }
    let sep = MediaScripts.separator
    let musicReply = ["playing", "Low Tide", "Lintel Test Signal", "Test Tones", "245,5", "12.25", "true", "false", "one",
                      "ABCDEF0123", "Apple Lossless audio file", "96000", "song"].joined(separator: sep)
    let music = MediaScripts.parseState(musicReply, player: .music, now: Date(timeIntervalSince1970: 100))
    check(music.running && music.info?.title == "Low Tide" && music.info?.playing == true, "Music reply parsed")
    check(music.info?.duration == 245.5 && music.info?.elapsed == 12.25, "Music times parsed (comma decimals too)")
    check(music.info?.favorite == true && music.info?.shuffle == false && music.info?.repeatMode == .one, "Music extras parsed")
    check(music.info?.format == .hiResLossless && music.info?.itemID == "ABCDEF0123", "Music format and persistent ID")
    check(music.info?.bundleID == "com.apple.Music" && music.info?.capabilities.contains(.favorite) == true, "Music source identity")
    let spotifyReply = ["paused", "Night Shift", "Artist", "Album", "201000", "33.5", "false", "true", "true",
                        "spotify:track:6rqhFgbbKwnb9MLmUQDhG6", "https://i.scdn.co/image/abc"].joined(separator: sep)
    let spotify = MediaScripts.parseState(spotifyReply, player: .spotify)
    check(spotify.info?.duration == 201 && spotify.info?.playing == false, "Spotify milliseconds → seconds")
    check(spotify.info?.shuffle == true && spotify.info?.repeatMode == .all, "Spotify shuffle and repeat")
    check(spotify.info?.link == "spotify:track:6rqhFgbbKwnb9MLmUQDhG6" && spotify.artworkURL == "https://i.scdn.co/image/abc",
          "Spotify URI and artwork URL")
    check(spotify.info?.capabilities.contains(.favorite) == false, "Spotify can't favourite through AppleScript")
    let episode = MediaScripts.parseState(spotifyReply.replacingOccurrences(of: "spotify:track:", with: "spotify:episode:"), player: .spotify)
    check(episode.info?.kind == .podcast, "Spotify episodes are podcasts")
    check(!MediaScripts.parseState("notRunning", player: .music).running, "closed player")
    check(MediaScripts.parseState("stopped", player: .music).running && MediaScripts.parseState("stopped", player: .music).info == nil,
          "stopped player has no item")
    check(MediaScripts.audioFormat(kind: "Apple Lossless audio file", sampleRate: 44_100) == .lossless, "lossless at 44.1 kHz")
    check(MediaScripts.audioFormat(kind: "Dolby Atmos", sampleRate: 48_000) == .dolbyAtmos, "Atmos")
    check(MediaScripts.audioFormat(kind: "AAC audio file", sampleRate: 44_100) == nil, "lossy → no format badge")

    check(MediaScripts.command(.togglePlayPause, player: .music)?.contains("playpause") == true, "Music play/pause")
    check(MediaScripts.command(.next, player: .spotify)?.contains("next track") == true, "Spotify next")
    check(MediaScripts.command(.seek(to: 61.5), player: .music)?.contains("set player position to 61.500") == true,
          "seek uses a locale-independent number")
    check(MediaScripts.command(.setRepeat(.one), player: .music)?.contains("set song repeat to one") == true, "Music repeat one")
    check(MediaScripts.command(.setRepeat(.one), player: .spotify)?.contains("set repeating to true") == true, "Spotify repeat")
    check(MediaScripts.command(.setShuffle(true), player: .spotify)?.contains("set shuffling to true") == true, "Spotify shuffle")
    check(MediaScripts.command(.setFavorite(true), player: .music)?.contains("set favorited of current track to true") == true,
          "Music favourite")
    check(MediaScripts.command(.setFavorite(true), player: .spotify) == nil, "no Spotify favourite command")
    check(MediaScripts.command(.setRate(2), player: .music) == nil, "no rate command for Music")
    check(MediaScripts.command(.play, player: .music)?.hasPrefix("if application \"Music\" is running") == true,
          "commands never launch the player")

    let safari = MediaScripts.focusBrowserTab(.safari, titleContains: #"My "clip""#)
    check(safari.contains("set current tab of w to t") && safari.contains(#"(name of t) contains "My \"clip\"""#),
          "Safari tab focus uses current tab and name")
    let chrome = MediaScripts.focusBrowserTab(.chrome, titleContains: "Clip")
    check(chrome.contains("tell application \"Google Chrome\"") && chrome.contains("set active tab index of w to i")
          && chrome.contains("(title of t) contains \"Clip\""), "Chromium tab focus uses the active tab index")
    check(MediaScripts.focusBrowserTab(.dia, titleContains: "Clip").contains("tell application \"Dia\""), "Dia scripted like Chromium")
    check(MediaScripts.browserTabURL(.safari, titleContains: "Clip").contains("return (URL of t)"), "tab URL script")

    let musicNote: [String: Any] = ["Name": "Low Tide", "Artist": "Lintel Test Signal", "Album": "Tones", "Total Time": 245_000,
                                    "Player State": "Playing", "PersistentID": NSNumber(value: Int64(0x1A2B)),
                                    "Store URL": "https://music.apple.com/us/album/x/1?i=2"]
    let fromMusic = PlayerNotification.info(from: musicNote, player: .music)
    check(fromMusic?.title == "Low Tide" && fromMusic?.duration == 245 && fromMusic?.playing == true, "Music notification parsed")
    check(fromMusic?.itemID == "1A2B" && fromMusic?.link == "https://music.apple.com/us/album/x/1?i=2", "Music notification IDs")
    let spotifyNote: [String: Any] = ["Name": "Night Shift", "Artist": "A", "Album": "B", "Duration": 201_000,
                                      "Playback Position": 12.5, "Player State": "Paused", "Track ID": "spotify:track:abc"]
    let fromSpotify = PlayerNotification.info(from: spotifyNote, player: .spotify, now: Date(timeIntervalSince1970: 5))
    check(fromSpotify?.duration == 201 && fromSpotify?.elapsed == 12.5 && fromSpotify?.playing == false, "Spotify notification parsed")
    check(fromSpotify?.link == "spotify:track:abc", "Spotify notification track ID")
    check(PlayerNotification.info(from: ["Player State": "Stopped", "Name": "X"], player: .music) == nil, "stopped → nothing")
}

// MARK: - Links

private func m4LinkChecks() {
    check(MediaLinks.spotifyWebURL(fromURI: "spotify:track:6rqhFgbbKwnb9MLmUQDhG6") == "https://open.spotify.com/track/6rqhFgbbKwnb9MLmUQDhG6",
          "Spotify track URI → web link")
    check(MediaLinks.spotifyWebURL(fromURI: "spotify:episode:abc") == "https://open.spotify.com/episode/abc", "Spotify episode")
    check(MediaLinks.spotifyWebURL(fromURI: "spotify:local:a:b:c:1") == nil && MediaLinks.spotifyWebURL(fromURI: "nope") == nil,
          "local files and garbage have no link")
    check(MediaLinks.cleanedBrowserURL("https://www.youtube.com/watch?v=abc123&list=PL1&index=4&t=42") == "https://www.youtube.com/watch?v=abc123&t=42",
          "YouTube link keeps v and t")
    check(MediaLinks.cleanedBrowserURL("https://music.youtube.com/watch?v=xyz&feature=share") == "https://music.youtube.com/watch?v=xyz",
          "YouTube Music link cleaned")
    check(MediaLinks.cleanedBrowserURL("https://example.com/a?b=c") == "https://example.com/a?b=c", "other URLs unchanged")
    let lookup = MediaLinks.appleMusicLookupURL(title: "Low Tide", artist: "Lintel Test Signal")
    check(lookup?.host == "itunes.apple.com" && lookup?.query?.contains("entity=song") == true
          && lookup?.query?.contains("term=Lintel%20Test%20Signal%20Low%20Tide") == true, "Apple Music lookup URL")
    let response = Data("""
    {"resultCount":2,"results":[
     {"trackName":"Low Tide (Live)","artistName":"Lintel Test Signal","trackViewUrl":"https://music.apple.com/us/album/a/1?i=9&uo=4"},
     {"trackName":"Low Tide","artistName":"Lintel Test Signal","trackViewUrl":"https://music.apple.com/us/album/b/2?i=7&uo=4"}]}
    """.utf8)
    check(MediaLinks.appleMusicLink(fromSearchResponse: response, title: "Low Tide", artist: "Lintel Test Signal")
          == "https://music.apple.com/us/album/b/2?i=7", "exact title match preferred, tracking parameters dropped")
    check(MediaLinks.appleMusicLink(fromSearchResponse: Data("{}".utf8), title: "x", artist: "y") == nil, "empty response")
}

// MARK: - Artwork palette (dominant colours)

private func image(width: Int, height: Int, _ color: (Int, Int) -> (UInt8, UInt8, UInt8)) -> [UInt8] {
    var pixels: [UInt8] = []
    for y in 0..<height {
        for x in 0..<width {
            let c = color(x, y)
            pixels += [c.0, c.1, c.2, 255]
        }
    }
    return pixels
}

private func m4PaletteChecks() {
    let split = image(width: 24, height: 24) { x, _ in x < 14 ? (220, 40, 30) : (30, 60, 210) }
    let p1 = ArtworkPalette.extract(rgba: split, width: 24, height: 24)
    check(p1 != nil && !p1!.isMonochrome, "colourful artwork has a palette")
    if let p1 {
        let hues = [p1.primary.hsb.h, p1.secondary.hsb.h]
        check(hues.contains { $0 < 0.05 || $0 > 0.95 } && hues.contains { abs($0 - 0.64) < 0.06 },
              "primary and secondary are the red and blue areas")
        check(p1.primary.hsb.h < 0.05 || p1.primary.hsb.h > 0.95, "the larger area becomes the primary colour")
    }
    let darkWithAccent = image(width: 24, height: 24) { x, y in (x > 17 && y > 17) ? (230, 120, 40) : (8, 8, 10) }
    let p2 = ArtworkPalette.extract(rgba: darkWithAccent, width: 24, height: 24)
    check(p2.map { $0.accent.hueDistance(to: PaletteColor(r: 0.9, g: 0.47, b: 0.16)) < 12 } == true,
          "a small bright accent beats a large black area")
    let grey = image(width: 16, height: 16) { x, _ in x % 2 == 0 ? (120, 120, 120) : (200, 200, 200) }
    let p3 = ArtworkPalette.extract(rgba: grey, width: 16, height: 16)
    check(p3?.isMonochrome == true && p3?.accent == .lightGrey, "grey artwork → monochrome palette, light grey accent")
    let deep = PaletteColor(r: 0.2, g: 0.05, b: 0.05).readableOnBlack()
    check(deep.hsb.v >= 0.62 - 1e-9 && abs(deep.hsb.h - PaletteColor(r: 0.2, g: 0.05, b: 0.05).hsb.h) < 1e-6,
          "dark colours are lifted for the black island, hue kept")
    let roundTrip = PaletteColor(h: 0.3, s: 0.5, v: 0.8).hsb
    check(abs(roundTrip.h - 0.3) < 1e-9 && abs(roundTrip.s - 0.5) < 1e-9 && abs(roundTrip.v - 0.8) < 1e-9, "HSB round trip")
    check(ArtworkPalette.extract(rgba: [], width: 0, height: 0) == nil, "empty image → no palette")
    let transparent = [UInt8](repeating: 0, count: 8 * 8 * 4)
    check(ArtworkPalette.extract(rgba: transparent, width: 8, height: 8) == nil, "fully transparent → no palette")
    let again = ArtworkPalette.extract(rgba: split, width: 24, height: 24)
    check(again == p1, "palette extraction is deterministic")
}

// MARK: - Spectrum (process taps + vDSP)

private func m4SpectrumChecks() {
    let analyzer = SpectrumAnalyzer(fftSize: 1024, bands: 6, sampleRate: 48_000)
    let ranges = SpectrumAnalyzer.bandRanges(bands: 6, fftSize: 1024, sampleRate: 48_000, minFrequency: 60, maxFrequency: 12_000)
    check(ranges.count == 6 && zip(ranges, ranges.dropFirst()).allSatisfy { $0.upperBound == $1.lowerBound }
          && ranges.allSatisfy { !$0.isEmpty }, "bands are contiguous and non-empty")
    func tone(_ frequency: Double, amplitude: Float) -> [Float] {
        (0..<1024).map { amplitude * Float(sin(2 * Double.pi * frequency * Double($0) / 48_000)) }
    }
    var levels: [Float] = []
    for _ in 0..<8 { levels = tone(440, amplitude: 0.5).withUnsafeBufferPointer { analyzer.process($0) } }
    let binWidth = 48_000.0 / 1024
    let toneBand = ranges.firstIndex { $0.contains(Int((440 / binWidth).rounded())) } ?? -1
    check(toneBand >= 0 && levels.firstIndex(of: levels.max() ?? 0) == toneBand, "a 440 Hz tone peaks in its band (band \(toneBand))")
    check(levels[toneBand] > 0.6, "a loud tone gives a high level (\(levels[toneBand]))")
    for _ in 0..<40 { levels = [Float](repeating: 0, count: 1024).withUnsafeBufferPointer { analyzer.process($0) } }
    check(levels.allSatisfy { $0 < 0.02 }, "silence decays to flat")
    let high = SpectrumAnalyzer(bands: 6)
    for _ in 0..<8 { levels = tone(8_000, amplitude: 0.3).withUnsafeBufferPointer { high.process($0) } }
    check(levels.firstIndex(of: levels.max() ?? 0) == 5, "an 8 kHz tone lands in the top band")

    var gate = LiveWaveformGate()
    check(!gate.update(levels: [0.5, 0.2], playing: true, now: 0) && !gate.showsSimulated, "sound → live bars")
    gate.update(levels: [0, 0.01], playing: true, now: 1)
    check(!gate.showsSimulated, "brief silence keeps live bars")
    check(gate.update(levels: [0, 0], playing: true, now: 2.1) && gate.showsSimulated, "silence > 1 s while playing → simulated")
    check(gate.update(levels: [0.4, 0], playing: true, now: 3) && !gate.showsSimulated, "sound returns → live bars")
    gate.update(levels: [0, 0], playing: false, now: 4)
    gate.update(levels: [0, 0], playing: false, now: 9)
    check(!gate.showsSimulated, "paused silence isn't replaced (paused shows dots)")

    check(resampleLevels([0, 1], to: 3) == [0, 0.5, 1], "levels resampled to more bars")
    check(resampleLevels([0.2, 0.4, 0.6, 0.8, 1, 0.5], to: 6) == [0.2, 0.4, 0.6, 0.8, 1, 0.5], "same count unchanged")
    check(resampleLevels([0.3], to: 4) == [0.3, 0.3, 0.3, 0.3] && resampleLevels([1, 2], to: 0).isEmpty, "edge cases")
}

// MARK: - Output devices (output button)

private func m4OutputChecks() {
    check(AudioTransport(fourCC: AudioTransport.code("bltn")) == .builtIn && AudioTransport(fourCC: AudioTransport.code("airp")) == .airPlay,
          "transport four-char codes")
    check(AudioTransport(fourCC: AudioTransport.code("blue")) == .bluetooth && AudioTransport(fourCC: 0) == .other, "bluetooth, unknown")
    let speakers = AudioOutputDevice(id: 1, uid: "BuiltInSpeakerDevice", name: "MacBook Pro Speakers", transport: .builtIn)
    check(speakers.symbolNames().first == "laptopcomputer", "built-in speakers on a laptop → laptop glyph")
    check(speakers.symbolNames(builtInIsLaptop: false).first == "desktopcomputer", "desktop Macs → desktop glyph")
    let pods = AudioOutputDevice(id: 2, uid: "x", name: "Someone's AirPods Pro", transport: .bluetooth)
    check(pods.symbolNames().contains("airpodspro") && pods.symbolNames().last == "headphones", "AirPods Pro glyph with fallback")
    let airplay = AudioOutputDevice(id: 3, uid: "y", name: "Living Room", transport: .airPlay)
    check(airplay.symbolNames().first == "airplay.audio", "AirPlay glyph")
    let virtual = AudioOutputDevice(id: 4, uid: "z", name: "Recorder", transport: .virtual)
    let hdmi = AudioOutputDevice(id: 5, uid: "h", name: "Display Audio", transport: .hdmi)
    let ordered = orderedOutputs([hdmi, airplay, virtual, pods, speakers])
    check(ordered.map(\.id) == [1, 2, 3, 5], "outputs: built-in, Bluetooth, AirPlay, others; virtual devices hidden")
}
