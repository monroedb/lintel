import AVFoundation
import Foundation

/// Sounds of the battery, audio-device and Focus alerts (low battery,
/// Low Power Mode, Sleep Focus). Lintel's own tones, synthesised at runtime, so no audio files are
/// bundled; more sounds may come later.
enum AlertSound: String, CaseIterable {
    case lowBattery, lowPower, sleep, deviceLowBattery

    /// Notes as (frequency Hz, start s, duration s, level 0…1).
    fileprivate var notes: [AlertTone.Note] {
        switch self {
        case .lowBattery: // two falling notes, E5 → A4
            return [.init(659.26, 0, 0.20, 0.55), .init(440.0, 0.17, 0.32, 0.55)]
        case .deviceLowBattery: // a softer, higher pair, A5 → E5
            return [.init(880.0, 0, 0.16, 0.42), .init(659.26, 0.13, 0.26, 0.42)]
        case .lowPower: // rising fifth, C5 → G5
            return [.init(523.25, 0, 0.22, 0.45), .init(783.99, 0.15, 0.36, 0.45)]
        case .sleep: // a slow A-minor swell
            return [.init(220.0, 0, 1.5, 0.32), .init(261.63, 0.06, 1.44, 0.24), .init(329.63, 0.12, 1.38, 0.22)]
        }
    }

    fileprivate var attack: Double { self == .sleep ? 0.35 : 0.008 }
}

/// Plays alert sounds; several can overlap.
@MainActor
final class AlertSoundPlayer {
    private var players: [AVAudioPlayer] = []
    private var cache: [AlertSound: Data] = [:]
    /// Sounds played (name and uptime).
    private(set) var played: [(sound: AlertSound, at: Double)] = []

    func play(_ sound: AlertSound) {
        let data = cache[sound] ?? AlertTone.wav(notes: sound.notes, attack: sound.attack)
        cache[sound] = data
        players.removeAll { !$0.isPlaying }
        guard let player = try? AVAudioPlayer(data: data) else { return }
        player.volume = 0.7
        player.prepareToPlay()
        player.play()
        players.append(player)
        played.append((sound, ProcessInfo.processInfo.systemUptime))
        if played.count > 20 { played.removeFirst(played.count - 20) }
    }
}

/// Additive synthesis into 16-bit mono WAV data.
enum AlertTone {
    struct Note {
        var frequency: Double
        var start: Double
        var duration: Double
        var level: Double

        init(_ frequency: Double, _ start: Double, _ duration: Double, _ level: Double) {
            self.frequency = frequency
            self.start = start
            self.duration = duration
            self.level = level
        }
    }

    static let sampleRate = 44_100

    static func wav(notes: [Note], attack: Double) -> Data {
        let length = (notes.map { $0.start + $0.duration }.max() ?? 0) + 0.05
        let count = Int(length * Double(sampleRate))
        var samples = [Double](repeating: 0, count: count)
        for note in notes {
            let first = Int(note.start * Double(sampleRate))
            let total = Int(note.duration * Double(sampleRate))
            for i in 0..<total where first + i < count {
                let t = Double(i) / Double(sampleRate)
                // Soft attack, exponential decay; a little second and third harmonic for warmth.
                let envelope = min(1, t / attack) * exp(-3.2 * t / note.duration) * min(1, (note.duration - t) / 0.03)
                let phase = 2 * Double.pi * note.frequency * t
                let wave = sin(phase) + 0.18 * sin(2 * phase) + 0.06 * sin(3 * phase)
                samples[first + i] += note.level * envelope * wave / 1.24
            }
        }
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let bytes = UInt32(count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36) + bytes)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(sampleRate)); append(UInt32(sampleRate * 2)); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(bytes)
        for sample in samples {
            append(Int16(max(-1, min(1, sample)) * Double(Int16.max)))
        }
        return data
    }
}
