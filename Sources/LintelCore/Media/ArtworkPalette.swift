import Foundation

/// An sRGB colour with components in 0…1.
public struct PaletteColor: Equatable, Sendable {
    public var r: Double
    public var g: Double
    public var b: Double

    public init(r: Double, g: Double, b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }

    public static let copper = PaletteColor(r: 0xD9 / 255, g: 0x77 / 255, b: 0x3A / 255)
    public static let lightGrey = PaletteColor(r: 0.72, g: 0.72, b: 0.74)

    /// Hue (0…1), saturation and brightness (HSB).
    public var hsb: (h: Double, s: Double, v: Double) {
        let maxC = max(r, g, b), minC = min(r, g, b), delta = maxC - minC
        var h = 0.0
        if delta > 0 {
            if maxC == r { h = (g - b) / delta } else if maxC == g { h = 2 + (b - r) / delta } else { h = 4 + (r - g) / delta }
            h /= 6
            if h < 0 { h += 1 }
        }
        return (h, maxC == 0 ? 0 : delta / maxC, maxC)
    }

    public init(h: Double, s: Double, v: Double) {
        let h6 = (h - floor(h)) * 6, i = Int(h6) % 6, f = h6 - floor(h6)
        let p = v * (1 - s), q = v * (1 - s * f), t = v * (1 - s * (1 - f))
        switch i {
        case 0: self.init(r: v, g: t, b: p)
        case 1: self.init(r: q, g: v, b: p)
        case 2: self.init(r: p, g: v, b: t)
        case 3: self.init(r: p, g: q, b: v)
        case 4: self.init(r: t, g: p, b: v)
        default: self.init(r: v, g: p, b: q)
        }
    }

    /// Relative luminance (sRGB, linearised).
    public var luminance: Double {
        func lin(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }

    /// The colour lifted so it reads on the island's black: greys become light grey, colours keep
    /// their hue with at least 62 % brightness.
    public func readableOnBlack() -> PaletteColor {
        let (h, s, v) = hsb
        if s < 0.12 { return PaletteColor(h: h, s: s, v: max(v, 0.72)) }
        return PaletteColor(h: h, s: min(s, 0.85), v: max(v, 0.62))
    }

    /// Circular hue distance in degrees.
    public func hueDistance(to other: PaletteColor) -> Double {
        let d = abs(hsb.h - other.hsb.h)
        return min(d, 1 - d) * 360
    }

    func distanceSquared(to other: PaletteColor) -> Double {
        let dr = r - other.r, dg = g - other.g, db = b - other.b
        return dr * dr + dg * dg + db * db
    }
}

/// Dominant colours of an artwork:
/// k-means over a small thumbnail, clusters scored by population and
/// saturation, with near-black and near-white penalised so they don't become the accent.
public struct ArtworkPalette: Equatable, Sendable {
    /// Most characteristic colour.
    public var primary: PaletteColor
    /// A second colour for gradients (different hue or brightness when the artwork has one).
    public var secondary: PaletteColor
    /// Average colour of the artwork.
    public var average: PaletteColor
    /// True when the artwork has (almost) no colour.
    public var isMonochrome: Bool

    public init(primary: PaletteColor, secondary: PaletteColor, average: PaletteColor, isMonochrome: Bool) {
        self.primary = primary
        self.secondary = secondary
        self.average = average
        self.isMonochrome = isMonochrome
    }

    /// Colour for the "Colored" progress style and waveform tint.
    public var accent: PaletteColor { isMonochrome ? .lightGrey : primary.readableOnBlack() }

    /// Two stops for the "Gradient" progress style and the waveform's left-to-right tint.
    public var gradient: [PaletteColor] {
        isMonochrome ? [PaletteColor(r: 0.5, g: 0.5, b: 0.52), .lightGrey] : [secondary.readableOnBlack(), primary.readableOnBlack()]
    }

    struct Cluster {
        var center: PaletteColor
        var count: Int
    }

    /// Extracts the palette from RGBA8 pixels (premultiplied or straight alpha; rows contiguous).
    public static func extract(rgba: [UInt8], width: Int, height: Int, clusters k: Int = 5) -> ArtworkPalette? {
        guard width > 0, height > 0, rgba.count >= width * height * 4 else { return nil }
        var pixels: [PaletteColor] = []
        pixels.reserveCapacity(width * height)
        for i in 0..<(width * height) {
            let a = Double(rgba[i * 4 + 3]) / 255
            guard a > 0.5 else { continue }
            // Un-premultiply (straight alpha with a = 1 is unchanged).
            pixels.append(PaletteColor(r: min(1, Double(rgba[i * 4]) / 255 / a),
                                   g: min(1, Double(rgba[i * 4 + 1]) / 255 / a),
                                   b: min(1, Double(rgba[i * 4 + 2]) / 255 / a)))
        }
        guard !pixels.isEmpty else { return nil }
        let n = Double(pixels.count)
        let average = PaletteColor(r: pixels.reduce(0) { $0 + $1.r } / n,
                               g: pixels.reduce(0) { $0 + $1.g } / n,
                               b: pixels.reduce(0) { $0 + $1.b } / n)
        var clusters = initialCenters(pixels, k: k).map { Cluster(center: $0, count: 0) }
        for _ in 0..<10 {
            var sums = [(Double, Double, Double, Int)](repeating: (0, 0, 0, 0), count: clusters.count)
            for p in pixels {
                var best = 0, bestD = Double.infinity
                for (index, c) in clusters.enumerated() {
                    let d = p.distanceSquared(to: c.center)
                    if d < bestD { bestD = d; best = index }
                }
                sums[best].0 += p.r; sums[best].1 += p.g; sums[best].2 += p.b; sums[best].3 += 1
            }
            var moved = false
            for index in clusters.indices {
                let s = sums[index]
                clusters[index].count = s.3
                guard s.3 > 0 else { continue }
                let center = PaletteColor(r: s.0 / Double(s.3), g: s.1 / Double(s.3), b: s.2 / Double(s.3))
                if center.distanceSquared(to: clusters[index].center) > 1e-6 { moved = true }
                clusters[index].center = center
            }
            if !moved { break }
        }
        clusters.removeAll { $0.count == 0 }
        let total = Double(clusters.reduce(0) { $0 + $1.count })
        func score(_ c: Cluster) -> Double {
            let (_, s, v) = c.center.hsb
            var factor = 1.0
            if v < 0.14 { factor = 0.15 }                  // near black
            else if v > 0.92 && s < 0.1 { factor = 0.4 }   // near white
            return Double(c.count) / total * (0.12 + s) * factor * (0.4 + v)
        }
        let ranked = clusters.sorted { score($0) > score($1) }
        guard let primary = ranked.first?.center else { return nil }
        let weightedSaturation = clusters.reduce(0.0) { $0 + $1.center.hsb.s * Double($1.count) } / total
        let isMonochrome = clusters.allSatisfy { $0.center.hsb.s < 0.12 || Double($0.count) / total < 0.03 } || weightedSaturation < 0.06
        let secondary = ranked.dropFirst().first { candidate in
            Double(candidate.count) / total >= 0.04 && candidate.center.hsb.v >= 0.14 &&
                (candidate.center.hueDistance(to: primary) > 25 || abs(candidate.center.hsb.v - primary.hsb.v) > 0.25)
        }?.center ?? {
            let (h, s, v) = primary.hsb
            return PaletteColor(h: h + 0.08, s: s * 0.8, v: min(1, v + 0.2))
        }()
        return ArtworkPalette(primary: primary, secondary: secondary, average: average, isMonochrome: isMonochrome)
    }

    /// Deterministic seeds: the most populated distinct colours of a 3-bit-per-channel histogram.
    static func initialCenters(_ pixels: [PaletteColor], k: Int) -> [PaletteColor] {
        var bins: [Int: (count: Int, r: Double, g: Double, b: Double)] = [:]
        for p in pixels {
            let key = (min(7, Int(p.r * 8)) << 6) | (min(7, Int(p.g * 8)) << 3) | min(7, Int(p.b * 8))
            var bin = bins[key] ?? (0, 0, 0, 0)
            bin.count += 1; bin.r += p.r; bin.g += p.g; bin.b += p.b
            bins[key] = bin
        }
        let sorted = bins.sorted { $0.value.count != $1.value.count ? $0.value.count > $1.value.count : $0.key < $1.key }
        var centers: [PaletteColor] = []
        for (_, bin) in sorted {
            let c = PaletteColor(r: bin.r / Double(bin.count), g: bin.g / Double(bin.count), b: bin.b / Double(bin.count))
            if centers.allSatisfy({ $0.distanceSquared(to: c) > 0.02 }) { centers.append(c) }
            if centers.count == k { break }
        }
        return centers.isEmpty ? [pixels[0]] : centers
    }
}
