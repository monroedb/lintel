import AppKit
import SwiftUI

/// Lintel's own visual identity: copper accent on graphite.
enum Brand {
    /// Lintel Copper #D9773A.
    static let copper = Color(red: 0xD9 / 255, green: 0x77 / 255, blue: 0x3A / 255)
    static let copperNS = NSColor(srgbRed: 0xD9 / 255, green: 0x77 / 255, blue: 0x3A / 255, alpha: 1)

    /// Menu-bar template glyph: a beam on two posts with a small capsule hanging beneath it.
    static func statusItemImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: NSRect(x: 1.5, y: 3.5, width: 15, height: 3), xRadius: 1.2, yRadius: 1.2).fill()
            NSBezierPath(roundedRect: NSRect(x: 2.5, y: 6.5, width: 2, height: 8.5), xRadius: 0.8, yRadius: 0.8).fill()
            NSBezierPath(roundedRect: NSRect(x: 13.5, y: 6.5, width: 2, height: 8.5), xRadius: 0.8, yRadius: 0.8).fill()
            NSBezierPath(roundedRect: NSRect(x: 6.5, y: 8, width: 5, height: 2.6), xRadius: 1.3, yRadius: 1.3).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Lintel"
        return image
    }
}
