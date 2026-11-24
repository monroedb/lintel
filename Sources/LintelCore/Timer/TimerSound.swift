import Foundation

/// Lintel's timer-end cue, synthesised with the bell timbre of `ToneSynth` (no audio files): three
/// quick strikes, G6 · E6 · G6, about 1.3 s.
public enum TimerSound {
    public static let notes: [ToneNote] = [
        ToneNote(frequency: 1567.98, onset: 0, decay: 0.32, gain: 0.85),
        ToneNote(frequency: 1318.51, onset: 0.14, decay: 0.32, gain: 0.8),
        ToneNote(frequency: 1567.98, onset: 0.28, decay: 0.9),
    ]

    public static func wav() -> Data { ToneSynth.wav(ToneSynth.render(notes)) }
}
