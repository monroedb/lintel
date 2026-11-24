import AVFoundation
import Foundation
import LintelCore

/// Plays Lintel's synthesised sounds with `AVAudioPlayer`; several can sound at once.
/// The cues are rendered once and the players are created and
/// started on a background queue, so a sound never delays the island's animations.
@MainActor
final class TonePlayer {
    private let rendering: Task<[ToneCue: Data], Never>
    private let output = ToneOutput()
    /// Cues played, with uptime.
    private(set) var log: [String] = []

    init() {
        rendering = Task.detached(priority: .utility) {
            var rendered: [ToneCue: Data] = [:]
            for cue in ToneCue.allCases { rendered[cue] = ToneSynth.wav(for: cue) }
            return rendered
        }
    }

    func play(_ cue: ToneCue) {
        log.append(String(format: "%.3f %@", ProcessInfo.processInfo.systemUptime, cue.rawValue))
        if log.count > 30 { log.removeFirst(log.count - 30) }
        let rendering = self.rendering
        let output = self.output
        Task.detached(priority: .userInitiated) {
            guard let data = await rendering.value[cue] else { return }
            output.play(data)
        }
    }
}

/// Owns the active players on its own serial queue; finished players are dropped when the next sound
/// starts. No delegate: `AVAudioPlayerDelegate` is main-actor isolated in the macOS 27 SDK, and
/// conforming to it moved this class onto the main actor (Swift 6.4 then rejected `play` from the
/// background task).
private final class ToneOutput: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.sashagilliard.lintel.tones")
    private var active: [AVAudioPlayer] = []

    func play(_ data: Data) {
        queue.async {
            self.active.removeAll { !$0.isPlaying }
            guard let player = try? AVAudioPlayer(data: data, fileTypeHint: AVFileType.wav.rawValue) else { return }
            player.volume = 0.8
            self.active.append(player)
            player.play()
        }
    }
}
