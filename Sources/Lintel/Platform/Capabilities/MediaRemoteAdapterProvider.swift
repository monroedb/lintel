import Foundation
import LintelCore

/// System-wide Now Playing through ungive/mediaremote-adapter: the bundled
/// `MediaRemoteAdapter.framework` is loaded by `/usr/bin/perl` running `mediaremote-adapter.pl`,
/// which streams JSON lines. Nothing is linked into Lintel and no `com.apple.*` identifier is used.
/// The adapter's `test` command runs first; if it fails, the controller falls back to AppleScript.
@MainActor
final class MediaRemoteAdapterProvider: NowPlayingProvider {
    struct Location: Equatable {
        var script: URL
        var framework: URL
        var testClient: URL
    }

    enum Health: Equatable {
        case unknown, testing, available
        case unavailable(String)

        var title: String {
            switch self {
            case .unknown: return "not tested"
            case .testing: return "testing"
            case .available: return "available"
            case .unavailable(let reason): return "unavailable (\(reason))"
            }
        }

        /// Settings' wording for the System source (the reason stays in `title`).
        var settingsLabel: String {
            switch self {
            case .unknown: return "Not checked yet"
            case .testing: return "Checking…"
            case .available: return "Available"
            case .unavailable: return "Not available on this Mac"
            }
        }
    }

    nonisolated static let perl = "/usr/bin/perl"

    /// Locations inside Lintel.app (see scripts/build-app.sh).
    static func bundled(in bundle: Bundle = .main) -> Location? {
        let contents = bundle.bundleURL.appendingPathComponent("Contents")
        let location = Location(
            script: contents.appendingPathComponent("Resources/MediaRemoteAdapter/mediaremote-adapter.pl"),
            framework: contents.appendingPathComponent("Frameworks/MediaRemoteAdapter.framework"),
            testClient: contents.appendingPathComponent("Helpers/MediaRemoteAdapterTestClient"))
        let fm = FileManager.default
        guard fm.fileExists(atPath: location.script.path), fm.fileExists(atPath: location.framework.path) else { return nil }
        return location
    }

    let kind = MediaProviderKind.system
    var onUpdate: ((NowPlayingInfo?) -> Void)?
    var onHealthChange: ((Health) -> Void)?
    private(set) var health: Health = .unknown {
        didSet { if health != oldValue { onHealthChange?(health) } }
    }
    private let location: Location?
    private var stream: AdapterStream?
    private var restartTimes: [Double] = []
    private var wantsStream = false
    private(set) var lines = 0
    private(set) var lastCommand = ""

    init(location: Location? = MediaRemoteAdapterProvider.bundled()) {
        self.location = location
    }

    var isRunning: Bool { stream != nil }

    var statusDescription: String {
        "adapter \(health.title), stream \(stream == nil ? "stopped" : "running"), lines \(lines)"
    }

    /// Runs `mediaremote-adapter.pl … test` (exit 0 = MediaRemote is usable).
    func runSelfTest(completion: @escaping @MainActor (Bool) -> Void) {
        guard let location else {
            health = .unavailable("not bundled")
            completion(false)
            return
        }
        health = .testing
        let arguments = [location.script.path, location.framework.path, location.testClient.path, "test"]
        HelperProcess.run(Self.perl, arguments, timeout: 12) { result in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if result.status == 0 {
                        self.health = .available
                        completion(true)
                    } else {
                        let reason = result.timedOut ? "test timed out" : "test exit \(result.status)"
                        NSLog("Lintel: MediaRemote adapter unavailable: %@ %@", reason, String(result.error.prefix(200)))
                        self.health = .unavailable(reason)
                        completion(false)
                    }
                }
            }
        }
    }

    func start() {
        wantsStream = true
        guard health == .available, stream == nil, let location else { return }
        let stream = AdapterStream(location: location)
        stream.onInfo = { [weak self] info in
            guard let self else { return }
            self.lines += 1
            self.onUpdate?(info)
        }
        stream.onExit = { [weak self] status, reason in self?.streamExited(status: status, reason: reason) }
        self.stream = stream
        stream.launch()
    }

    func stop() {
        wantsStream = false
        stream?.terminate()
        stream = nil
    }

    func restart() {
        stop()
        restartTimes.removeAll()
        start()
    }

    private func streamExited(status: Int32, reason: Process.TerminationReason) {
        stream = nil
        guard wantsStream else { return }
        // A non-zero exit is fatal: don't re-invoke (adapter README). Signals and clean exits restart.
        if reason == .exit && status != 0 {
            health = .unavailable("stream exit \(status)")
            onUpdate?(nil)
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        restartTimes = restartTimes.filter { now - $0 < 60 } + [now]
        guard restartTimes.count <= 3 else {
            health = .unavailable("stream keeps stopping")
            onUpdate?(nil)
            return
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            self?.start()
        }
    }

    // MARK: Commands

    func send(_ command: MediaCommand) {
        guard let location, health == .available else { return }
        var arguments = [location.script.path, location.framework.path]
        switch command {
        case .play: arguments += ["send", "0"]
        case .pause: arguments += ["send", "1"]
        case .togglePlayPause: arguments += ["send", "2"]
        case .next: arguments += ["send", "4"]
        case .previous: arguments += ["send", "5"]
        case .skip(let delta) where delta == 15: arguments += ["send", "13"]
        case .skip(let delta) where delta == -15: arguments += ["send", "12"]
        case .skip:
            return // other intervals are sent as seeks by the controller
        case .seek(let position):
            arguments += ["seek", String(Int64(max(0, position) * 1_000_000))]
        case .setRate(let rate):
            // The adapter's speed command takes whole numbers only.
            arguments += ["speed", String(max(1, Int(rate.rounded())))]
        case .setShuffle(let on):
            arguments += ["shuffle", on ? "3" : "1"]
        case .setRepeat(let mode):
            arguments += ["repeat", mode == .one ? "2" : (mode == .all ? "3" : "1")]
        case .setFavorite:
            return // not exposed by MediaRemote through the adapter
        }
        lastCommand = arguments.dropFirst(2).joined(separator: " ")
        HelperProcess.run(Self.perl, arguments, timeout: 5) { result in
            if result.status != 0 {
                NSLog("Lintel: adapter command failed (%d): %@", result.status, String(result.error.prefix(200)))
            }
        }
    }

    /// Positions are extrapolated from the stream's timestamped elapsed time (no extra process).
    func refreshPosition() {}
}

/// The long-running `stream` process: reads JSON lines on a background queue, keeps the merged
/// payload and delivers parsed snapshots to the main actor.
private final class AdapterStream: @unchecked Sendable {
    var onInfo: (@MainActor (NowPlayingInfo?) -> Void)?
    var onExit: (@MainActor (Int32, Process.TerminationReason) -> Void)?

    private let location: MediaRemoteAdapterProvider.Location
    private let process = Process()
    private let queue = DispatchQueue(label: "com.sashagilliard.lintel.adapter-stream")
    private var buffer = Data()
    private var state = AdapterStreamState()
    private var lastInfo: NowPlayingInfo?
    private var terminated = false

    init(location: MediaRemoteAdapterProvider.Location) {
        self.location = location
    }

    func launch() {
        process.executableURL = URL(fileURLWithPath: MediaRemoteAdapterProvider.perl)
        process.arguments = [location.script.path, location.framework.path, "stream", "--micros", "--debounce=40",
                             "--experimental-peculiar-debounce:com.tidal.desktop=1000"]
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            self.queue.async { self.consume(data) }
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { NSLog("Lintel: adapter stderr: %@", String(text.prefix(300))) }
        }
        process.terminationHandler = { [weak self] process in
            let status = process.terminationStatus, reason = process.terminationReason
            guard let self else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.onExit?(status, reason) }
            }
        }
        do {
            try process.run()
        } catch {
            NSLog("Lintel: adapter stream failed to start: %@", "\(error)")
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.onExit?(-1, .exit) }
            }
        }
    }

    func terminate() {
        queue.sync { terminated = true }
        if process.isRunning { process.terminate() }
    }

    private func consume(_ data: Data) {
        guard !terminated else { return }
        buffer.append(data)
        var latest: NowPlayingInfo??
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard !line.isEmpty, state.apply(line: Data(line)) else { continue }
            latest = .some(state.info)
        }
        // Guard against a runaway line without a newline.
        if buffer.count > 16 * 1024 * 1024 { buffer.removeAll() }
        guard let info = latest, info != lastInfo else { return }
        lastInfo = info
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.onInfo?(info) }
        }
    }
}
