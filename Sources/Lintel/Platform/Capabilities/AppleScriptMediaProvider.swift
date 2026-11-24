import AppKit
import Foundation
import LintelCore

/// Music or Spotify through AppleScript (fallback). State changes
/// arrive as the player's distributed notification, which needs no permission; position, artwork,
/// favourite, shuffle and repeat need Automation permission and are read with `osascript` only
/// while the player is running (scripts never launch it).
@MainActor
final class AppleScriptMediaProvider: NowPlayingProvider {
    let player: ScriptablePlayer
    var kind: MediaProviderKind { player == .music ? .music : .spotify }
    var onUpdate: ((NowPlayingInfo?) -> Void)?
    private(set) var isRunning = false
    private var observer: NSObjectProtocol?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var current: NowPlayingInfo?
    private var refreshTask: Task<Void, Never>?
    private var artworkKey: String?
    private var artworkData: Data?
    private(set) var scriptsSent = 0
    private(set) var notificationsSeen = 0

    init(player: ScriptablePlayer) {
        self.player = player
    }

    var statusDescription: String {
        "\(player.scriptName) via AppleScript, \(isRunning ? "watching" : "stopped"), notifications \(notificationsSeen), scripts \(scriptsSent)"
    }

    var playerIsRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: player.bundleID).isEmpty
    }

    /// Whether the last known state is playing (used by automatic source selection).
    var isPlaying: Bool { current?.playing ?? false }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(player.stateNotification), object: nil, queue: .main
        ) { [weak self] note in
            nonisolated(unsafe) let userInfo = note.userInfo as? [String: Any] ?? [:]
            MainActor.assumeIsolated { self?.received(userInfo) }
        }
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                                                     object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                guard let self, app?.bundleIdentifier == self.player.bundleID else { return }
                self.publish(nil)
            }
        })
        if playerIsRunning { scheduleRefresh(after: 0) }
    }

    func stop() {
        isRunning = false
        if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
        observer = nil
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        workspaceObservers.removeAll()
        refreshTask?.cancel()
        current = nil
    }

    private func received(_ userInfo: [String: Any]) {
        notificationsSeen += 1
        var info = PlayerNotification.info(from: userInfo, player: player)
        // Keep script-only fields while the item is unchanged.
        if var updated = info, let current, current.identity == updated.identity {
            updated.artworkData = current.artworkData
            updated.favorite = updated.favorite ?? current.favorite
            updated.shuffle = current.shuffle
            updated.repeatMode = current.repeatMode
            updated.format = current.format
            if updated.elapsed == nil { updated.elapsed = current.position(at: Date()); updated.timestamp = Date() }
            info = updated
        }
        publish(info)
        if info != nil { scheduleRefresh(after: 0.3) }
    }

    private func publish(_ info: NowPlayingInfo?) {
        current = info
        onUpdate?(info)
    }

    /// Reads the full state through AppleScript (debounced).
    private func scheduleRefresh(after delay: Double) {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled else { return }
            self?.refreshState()
        }
    }

    private func refreshState() {
        guard isRunning, playerIsRunning else { return }
        scriptsSent += 1
        let player = self.player
        ScriptRunner.run(MediaScripts.stateQuery(player)) { [weak self] reply in
            guard let self, let reply else { return }
            let state = MediaScripts.parseState(reply, player: player)
            guard var info = state.info else {
                self.publish(nil)
                return
            }
            if let previous = self.current, previous.identity == info.identity { info.artworkData = previous.artworkData }
            self.publish(info)
            self.loadArtwork(for: info, url: state.artworkURL)
        }
    }

    private func loadArtwork(for info: NowPlayingInfo, url: String?) {
        let key = info.identity
        guard artworkKey != key else { return }
        artworkKey = key
        switch player {
        case .spotify:
            guard let url = url.flatMap(URL.init(string:)), url.scheme == "https" else { return }
            Task { [weak self] in
                guard let (data, _) = try? await URLSession.shared.data(from: url) else { return }
                self?.attachArtwork(data, key: key)
            }
        case .music:
            let path = FileManager.default.temporaryDirectory.appendingPathComponent("lintel-music-artwork").path
            scriptsSent += 1
            ScriptRunner.run(MediaScripts.exportMusicArtwork(to: path)) { [weak self] reply in
                guard reply == "ok", let data = FileManager.default.contents(atPath: path) else { return }
                try? FileManager.default.removeItem(atPath: path)
                self?.attachArtwork(data, key: key)
            }
        }
    }

    private func attachArtwork(_ data: Data, key: String) {
        guard var info = current, info.identity == key else { return }
        info.artworkData = data
        publish(info)
    }

    func send(_ command: MediaCommand) {
        guard playerIsRunning, let script = MediaScripts.command(command, player: player, current: current) else { return }
        scriptsSent += 1
        ScriptRunner.run(script) { [weak self] _ in self?.scheduleRefresh(after: 0.25) }
    }

    func refreshPosition() {
        guard isRunning, playerIsRunning, current != nil else { return }
        scriptsSent += 1
        ScriptRunner.run(MediaScripts.positionQuery(player), timeout: 2) { [weak self] reply in
            guard let self, var info = self.current, let reply,
                  let position = Double(reply.replacingOccurrences(of: ",", with: ".")) else { return }
            info.elapsed = position
            info.timestamp = Date()
            self.publish(info)
        }
    }
}
