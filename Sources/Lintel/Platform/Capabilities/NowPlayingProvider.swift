import Foundation
import LintelCore

/// A source of Now Playing: the MediaRemote adapter (system-wide, run through
/// `/usr/bin/perl`) or AppleScript for Music and Spotify. Providers report snapshots on the main
/// actor; nil means nothing is playing.
@MainActor
protocol NowPlayingProvider: AnyObject {
    var kind: MediaProviderKind { get }
    var onUpdate: ((NowPlayingInfo?) -> Void)? { get set }
    var isRunning: Bool { get }
    func start()
    func stop()
    func send(_ command: MediaCommand)
    /// Called every second while a player is visible (1.0 s position polling).
    func refreshPosition()
    /// A one-line status.
    var statusDescription: String { get }
}

/// Runs short helper processes (`osascript`, the adapter's one-shot commands) off the main thread
/// with a timeout, so a hung player can't block Lintel.
enum HelperProcess {
    struct Result: Sendable {
        var status: Int32
        var output: String
        var error: String
        var timedOut: Bool
    }

    private static let queue = DispatchQueue(label: "com.sashagilliard.lintel.helper-process", qos: .userInitiated,
                                             attributes: .concurrent)

    static func run(_ executable: String, _ arguments: [String], input: String? = nil, timeout: Double = 5,
                    completion: (@Sendable (Result) -> Void)? = nil) {
        queue.async {
            let result = runSync(executable, arguments, input: input, timeout: timeout)
            completion?(result)
        }
    }

    /// Blocking; never call on the main thread.
    static func runSync(_ executable: String, _ arguments: [String], input: String? = nil, timeout: Double) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let stdin = Pipe()
        process.standardInput = input == nil ? FileHandle.nullDevice : stdin
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do {
            try process.run()
        } catch {
            return Result(status: -1, output: "", error: "\(error)", timedOut: false)
        }
        if let input {
            stdin.fileHandleForWriting.write(Data(input.utf8))
            try? stdin.fileHandleForWriting.close()
        }
        // Drain the pipes while waiting so a chatty child can't block on a full pipe.
        let collector = PipeCollector(stdout: stdout, stderr: stderr)
        let timedOut = done.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            process.terminate()
            if done.wait(timeout: .now() + 1) == .timedOut { kill(process.processIdentifier, SIGKILL) }
        }
        let (out, err) = collector.finish()
        return Result(status: timedOut ? -2 : process.terminationStatus, output: out, error: err, timedOut: timedOut)
    }

    /// Reads both pipes on background threads until EOF.
    private final class PipeCollector: @unchecked Sendable {
        private let group = DispatchGroup()
        private var out = Data(), err = Data()

        init(stdout: Pipe, stderr: Pipe) {
            group.enter()
            DispatchQueue.global(qos: .utility).async { [self] in
                out = stdout.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }
            group.enter()
            DispatchQueue.global(qos: .utility).async { [self] in
                err = stderr.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }
        }

        func finish() -> (String, String) {
            _ = group.wait(timeout: .now() + 2)
            return (String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
                    String(decoding: err, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}

/// Runs AppleScript through `/usr/bin/osascript` (script on stdin) with a timeout.
enum ScriptRunner {
    static func run(_ script: String, timeout: Double = 4, completion: (@Sendable @MainActor (String?) -> Void)? = nil) {
        HelperProcess.run("/usr/bin/osascript", ["-"], input: script, timeout: timeout) { result in
            let reply: String? = result.status == 0 ? result.output : nil
            if result.status != 0 {
                NSLog("Lintel: AppleScript failed (%d): %@", result.status, String(result.error.prefix(200)))
            }
            guard let completion else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(reply) } }
        }
    }
}
