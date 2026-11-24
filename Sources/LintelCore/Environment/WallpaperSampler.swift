import CoreGraphics
import Foundation
import ImageIO

/// Samples the desktop picture under the top-centre strip of a screen (aspect-fill mapping, the
/// default scaling) and returns its mean relative luminance.
public enum WallpaperSampler {
    /// Width × height (pt) of the strip sampled under the island.
    public static let sampleStrip = CGSize(width: 420, height: 44)

    public static func sample(url: URL, screenSize: CGSize, strip: CGSize = sampleStrip) -> Double? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 1024,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return sample(image: image, screenSize: screenSize, strip: strip)
    }

    public static func sample(image: CGImage, screenSize: CGSize, strip: CGSize = sampleStrip) -> Double? {
        let width = CGFloat(image.width), height = CGFloat(image.height)
        guard width > 0, height > 0, screenSize.width > 0, screenSize.height > 0 else { return nil }
        // Aspect fill: the picture covers the screen, so the visible part is the largest centred
        // region with the screen's aspect ratio; `scale` is picture pixels per screen point.
        let scale = min(width / screenSize.width, height / screenSize.height)
        let offsetX = (width - screenSize.width * scale) / 2
        let offsetY = (height - screenSize.height * scale) / 2
        let area = CGRect(x: (screenSize.width - strip.width) / 2, y: 0, width: strip.width, height: strip.height)
        let crop = CGRect(x: offsetX + area.minX * scale, y: offsetY + area.minY * scale,
                          width: area.width * scale, height: area.height * scale).integral
            .intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard !crop.isEmpty, let region = image.cropping(to: crop) else { return nil }

        let w = 32, h = 4
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                          bytesPerRow: w * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(region, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return drawn ? Luminance.mean(rgba: pixels) : nil
    }
}
