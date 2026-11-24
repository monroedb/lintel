import Foundation

/// One struck note: a bell-like tone that decays over `decay` seconds.
public struct ToneNote: Equatable, Sendable {
    public var frequency: Double
    public var onset: Double
    public var decay: Double
    public var gain: Double

    public init(frequency: Double, onset: Double, decay: Double, gain: Double = 1) {
        self.frequency = frequency
        self.onset = onset
        self.decay = decay
        self.gain = gain
    }
}

/// Lintel's own sounds, synthesised at run time.
/// The cues: an event starting, the hourly chime and the
/// time-to-leave alert.
public enum ToneCue: String, Sendable, CaseIterable {
    case eventStart, hourlyChime, leaveNow

    public var notes: [ToneNote] {
        switch self {
        case .eventStart:
            // Two rising notes (→ E6).
            return [ToneNote(frequency: 880, onset: 0, decay: 0.9, gain: 0.8),
                    ToneNote(frequency: 1318.5, onset: 0.13, decay: 1.1)]
        case .hourlyChime:
            // One soft, long bell (C6) with a quiet octave below.
            return [ToneNote(frequency: 1046.5, onset: 0, decay: 1.8),
                    ToneNote(frequency: 523.25, onset: 0, decay: 1.4, gain: 0.35)]
        case .leaveNow:
            // A quick rising arpeggio (G5, B5, D6).
            return [ToneNote(frequency: 784, onset: 0, decay: 0.55, gain: 0.8),
                    ToneNote(frequency: 987.77, onset: 0.09, decay: 0.55, gain: 0.85),
                    ToneNote(frequency: 1174.66, onset: 0.18, decay: 0.9)]
        }
    }
}

/// Additive bell synthesis and 16-bit PCM WAV encoding.
public enum ToneSynth {
    public static let sampleRate = 44_100
    /// Partials of the bell timbre: frequency ratio, relative gain, decay speed-up.
    static let partials: [(ratio: Double, gain: Double, decaySpeed: Double)] = [
        (1.0, 1.0, 1.0), (2.0, 0.32, 1.7), (3.01, 0.12, 2.6), (4.2, 0.05, 3.4),
    ]
    static let attack = 0.006

    /// Mono samples, peak-normalised to `peak` (−7 dBFS by default), with a short fade at the end.
    public static func render(_ notes: [ToneNote], sampleRate: Int = sampleRate, peak: Double = 0.45) -> [Float] {
        guard !notes.isEmpty, sampleRate > 0 else { return [] }
        let length = notes.map { $0.onset + $0.decay * 1.1 }.max() ?? 0
        let count = max(1, Int(length * Double(sampleRate)))
        var samples = [Double](repeating: 0, count: count)
        let rate = Double(sampleRate)
        for note in notes {
            let first = max(0, Int(note.onset * rate))
            // exp(−k·t) reaches about −60 dB at t = decay.
            let k = 6.9 / max(0.05, note.decay)
            for index in first..<count {
                let t = Double(index) / rate - note.onset
                let envelope = min(1, t / attack) * note.gain
                var value = 0.0
                for partial in partials {
                    value += partial.gain * exp(-k * partial.decaySpeed * t) * sin(2 * .pi * note.frequency * partial.ratio * t)
                }
                samples[index] += envelope * value
            }
        }
        let maximum = samples.map(abs).max() ?? 0
        let scale = maximum > 0 ? peak / maximum : 0
        let fade = min(count, Int(0.01 * rate))
        return samples.enumerated().map { index, value in
            let tail = index >= count - fade ? Double(count - index) / Double(max(1, fade)) : 1
            return Float(value * scale * tail)
        }
    }

    /// 16-bit little-endian PCM WAV data.
    public static func wav(_ samples: [Float], sampleRate: Int = sampleRate) -> Data {
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        let dataSize = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36) + dataSize)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(sampleRate)); append(UInt32(sampleRate * 2)); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(dataSize)
        for sample in samples {
            append(Int16(max(-1, min(1, sample)) * Float(Int16.max)))
        }
        return data
    }

    public static func wav(for cue: ToneCue) -> Data { wav(render(cue.notes)) }
}
