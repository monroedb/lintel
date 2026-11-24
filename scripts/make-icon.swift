// Draws Lintel's app icon (own artwork) into an .iconset folder.
// Usage: swift scripts/make-icon.swift <output.iconset>
import AppKit

let args = CommandLine.arguments
guard args.count == 2 else { FileHandle.standardError.write("usage: make-icon.swift <out.iconset>\n".data(using: .utf8)!); exit(2) }
let outDir = URL(fileURLWithPath: args[1])
try? FileManager.default.removeItem(at: outDir)
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

func drawIcon(size s: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(s), pixelsHigh: Int(s), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.clear(CGRect(x: 0, y: 0, width: s, height: s))

    // Squircle-ish tile with the standard macOS icon margin.
    let inset = s * 0.098
    let tile = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.225, yRadius: tile.width * 0.225)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = color(0x000000, 0.35)
    shadow.shadowBlurRadius = s * 0.02
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.008)
    shadow.set()
    color(0x1A1C20).setFill()
    tilePath.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: [color(0x30333A), color(0x111215)])!.draw(in: tilePath, angle: -90)

    // The opening (a dark doorway) and its two posts.
    let openW = tile.width * 0.56, openH = tile.height * 0.50
    let opening = CGRect(x: tile.midX - openW / 2, y: tile.minY + tile.height * 0.14, width: openW, height: openH)
    NSGradient(colors: [color(0x07080A), color(0x16181C)])!.draw(in: NSBezierPath(rect: opening), angle: 90)
    let postW = tile.width * 0.075
    for x in [opening.minX - postW, opening.maxX] {
        let post = NSBezierPath(roundedRect: CGRect(x: x, y: opening.minY, width: postW, height: openH),
                                xRadius: postW * 0.25, yRadius: postW * 0.25)
        NSGradient(colors: [color(0x4A4E57), color(0x2C2F35)])!.draw(in: post, angle: 0)
    }

    // The lintel: a copper beam spanning the opening.
    let beamH = tile.height * 0.11
    let beam = CGRect(x: opening.minX - postW * 1.6, y: opening.maxY, width: openW + postW * 3.2, height: beamH)
    let beamPath = NSBezierPath(roundedRect: beam, xRadius: beamH * 0.22, yRadius: beamH * 0.22)
    NSGradient(colors: [color(0xF2A566), color(0xD9773A), color(0xA4521F)])!.draw(in: beamPath, angle: -90)
    color(0xFFD7B0, 0.55).setFill()
    NSBezierPath(rect: CGRect(x: beam.minX + beamH * 0.3, y: beam.maxY - beamH * 0.16,
                              width: beam.width - beamH * 0.6, height: beamH * 0.06)).fill()

    // The island: a black capsule hanging under the beam, with a warm rim light.
    let capW = openW * 0.46, capH = beamH * 0.62
    let capsule = CGRect(x: tile.midX - capW / 2, y: beam.minY - capH * 1.25, width: capW, height: capH)
    let capPath = NSBezierPath(roundedRect: capsule, xRadius: capH / 2, yRadius: capH / 2)
    NSGraphicsContext.saveGraphicsState()
    let glow = NSShadow()
    glow.shadowColor = color(0xD9773A, 0.85)
    glow.shadowBlurRadius = s * 0.03
    glow.set()
    color(0x000000).setFill()
    capPath.fill()
    NSGraphicsContext.restoreGraphicsState()
    color(0xD9773A, 0.9).setStroke()
    capPath.lineWidth = max(1, s * 0.006)
    capPath.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let sizes: [(String, CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, size) in sizes {
    let data = drawIcon(size: size).representation(using: .png, properties: [:])!
    try data.write(to: outDir.appendingPathComponent("\(name).png"))
}
print(outDir.path)
