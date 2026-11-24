import Accelerate
import Foundation

/// Turns blocks of mono samples into a few log-spaced band levels (0…1) for the live waveform
/// (Core Audio process tap + vDSP). Not thread-safe: use it from one queue.
public final class SpectrumAnalyzer {
    public let fftSize: Int
    public let bandCount: Int
    public let sampleRate: Double
    /// Level range mapped to 0…1 (dBFS of a band's strongest bin).
    public var floorDB: Float = -62
    public var ceilingDB: Float = -12
    /// Smoothing: rising levels follow quickly, falling ones decay.
    public var attack: Float = 0.7
    public var release: Float = 0.22

    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private var window: [Float]
    private var buffer: [Float]
    private var real: [Float]
    private var imag: [Float]
    private var magnitudes: [Float]
    private let bandBins: [Range<Int>]
    public private(set) var levels: [Float]

    public init(fftSize: Int = 1024, bands: Int = 6, sampleRate: Double = 48_000,
                minFrequency: Double = 60, maxFrequency: Double = 12_000) {
        let log2n = vDSP_Length(max(6, Int(log2(Double(fftSize)).rounded())))
        let size = 1 << Int(log2n)
        self.fftSize = size
        self.log2n = log2n
        self.bandCount = max(1, bands)
        self.sampleRate = sampleRate
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        window = [Float](repeating: 0, count: size)
        vDSP_hann_window(&window, vDSP_Length(size), Int32(vDSP_HANN_NORM))
        buffer = [Float](repeating: 0, count: size)
        real = [Float](repeating: 0, count: size / 2)
        imag = [Float](repeating: 0, count: size / 2)
        magnitudes = [Float](repeating: 0, count: size / 2)
        levels = [Float](repeating: 0, count: max(1, bands))
        bandBins = Self.bandRanges(bands: max(1, bands), fftSize: size, sampleRate: sampleRate,
                                   minFrequency: minFrequency, maxFrequency: min(maxFrequency, sampleRate / 2))
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    /// FFT bin ranges for log-spaced bands between the two frequencies (each at least one bin).
    public static func bandRanges(bands: Int, fftSize: Int, sampleRate: Double, minFrequency: Double,
                                  maxFrequency: Double) -> [Range<Int>] {
        let binWidth = sampleRate / Double(fftSize)
        let half = fftSize / 2
        var ranges: [Range<Int>] = []
        var lowerBin = max(1, Int((minFrequency / binWidth).rounded(.down)))
        for band in 0..<bands {
            let upperFrequency = minFrequency * pow(maxFrequency / minFrequency, Double(band + 1) / Double(bands))
            var upperBin = min(half, Int((upperFrequency / binWidth).rounded(.up)))
            if upperBin <= lowerBin { upperBin = min(half, lowerBin + 1) }
            ranges.append(lowerBin..<upperBin)
            lowerBin = upperBin
        }
        return ranges
    }

    /// Analyses the most recent `fftSize` samples (fewer are zero-padded) and returns the smoothed levels.
    @discardableResult
    public func process(_ samples: UnsafeBufferPointer<Float>) -> [Float] {
        let count = min(samples.count, fftSize)
        buffer.withUnsafeMutableBufferPointer { dst in
            for i in 0..<fftSize { dst[i] = 0 }
            if count > 0, let base = samples.baseAddress {
                dst.baseAddress!.update(from: base + (samples.count - count), count: count)
            }
        }
        let size = fftSize
        buffer.withUnsafeMutableBufferPointer { data in
            window.withUnsafeBufferPointer { hann in
                vDSP_vmul(data.baseAddress!, 1, hann.baseAddress!, 1, data.baseAddress!, 1, vDSP_Length(size))
            }
        }
        real.withUnsafeMutableBufferPointer { realPtr in
            imag.withUnsafeMutableBufferPointer { imagPtr in
                var split = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                buffer.withUnsafeBufferPointer { src in
                    src.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftSize / 2) { complex in
                        vDSP_ctoz(complex, 2, &split, 1, vDSP_Length(fftSize / 2))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                // Bin 0 packs DC and Nyquist; drop both.
                split.realp[0] = 0
                split.imagp[0] = 0
                vDSP_zvmags(&split, 1, &magnitudes, 1, vDSP_Length(fftSize / 2))
            }
        }
        // zrip returns 2×DFT; with the Hann window's 0.5 gain a full-scale sine peaks at N/2.
        let scale = Float(fftSize / 2)
        for (band, bins) in bandBins.enumerated() {
            var peak: Float = 0
            for bin in bins where bin < magnitudes.count { peak = max(peak, magnitudes[bin]) }
            let amplitude = sqrt(peak) / scale
            let db = 20 * log10(max(amplitude, 1e-7))
            let target = min(1, max(0, (db - floorDB) / (ceilingDB - floorDB)))
            let previous = levels[band]
            levels[band] = previous + (target - previous) * (target > previous ? attack : release)
        }
        return levels
    }

    public func reset() {
        for i in levels.indices { levels[i] = 0 }
    }
}

/// When the tap only reports silence for more than 1 s while the media plays (for
/// example with the output muted), the simulated waveform is shown instead of flat bars.
public struct LiveWaveformGate: Equatable, Sendable {
    public static let silenceLevel: Float = 0.03
    public static let silenceHold: Double = 1.0

    public private(set) var showsSimulated = false
    public private(set) var silentSince: Double?

    public init() {}

    /// Returns true when `showsSimulated` changed.
    @discardableResult
    public mutating func update(levels: [Float], playing: Bool, now: Double) -> Bool {
        let before = showsSimulated
        let silent = (levels.max() ?? 0) < Self.silenceLevel
        if playing && silent {
            if silentSince == nil { silentSince = now }
            if let since = silentSince, now - since > Self.silenceHold { showsSimulated = true }
        } else {
            silentSince = nil
            showsSimulated = false
        }
        return before != showsSimulated
    }
}

/// Resamples band levels to a different number of bars (linear interpolation).
public func resampleLevels(_ levels: [Float], to count: Int) -> [Float] {
    guard count > 0 else { return [] }
    guard levels.count > 1 else { return [Float](repeating: levels.first ?? 0, count: count) }
    if levels.count == count { return levels }
    return (0..<count).map { index in
        let position = count == 1 ? 0 : Double(index) * Double(levels.count - 1) / Double(count - 1)
        let lower = Int(position.rounded(.down)), upper = min(levels.count - 1, lower + 1)
        let t = Float(position - Double(lower))
        return levels[lower] * (1 - t) + levels[upper] * t
    }
}
