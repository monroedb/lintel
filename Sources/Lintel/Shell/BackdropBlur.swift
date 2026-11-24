import AppKit
import LintelCore

/// Progressive blur behind the expanded card, drawn in the backdrop panel.
/// There is no public variable-blur filter, so a behind-window `NSVisualEffectView` is masked with
/// a gradient: full strength along the top edge, fading out downward and towards the sides
/// (approximation).
@MainActor
final class BackdropBlur {
    /// How far the blur reaches beyond the card.
    static let sideMargin: CGFloat = 40
    static let bottomMargin: CGFloat = 40

    private let effectView: NSVisualEffectView
    private var maskSize: CGSize = .zero
    private(set) var isShown = false

    init(container: NSView) {
        effectView = NSVisualEffectView(frame: .zero)
        effectView.material = .fullScreenUI
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.appearance = NSAppearance(named: .darkAqua)
        effectView.alphaValue = 0
        effectView.isHidden = true
        container.addSubview(effectView)
    }

    var alpha: CGFloat { effectView.isHidden ? 0 : effectView.alphaValue }

    /// - Parameters:
    ///   - cardRect: the expanded card in the container's coordinates.
    ///   - show: whether the blur should be visible.
    func update(cardRect: CGRect, show: Bool, canvasHeight: CGFloat) {
        // Hidden and staying hidden (the blur is off, or the card closed): the view isn't touched.
        // The backdrop panel is extended sRGB, so preparing the mask means converting a card-sized
        // image to half floats on the main thread at commit (5–10 ms): in the baseline recording it
        // happened as the card opened or closed and coincided with the animation's longest late
        // frames.
        guard show || isShown else { return }
        let frame = CGRect(x: cardRect.minX - Self.sideMargin, y: cardRect.minY - Self.bottomMargin,
                           width: cardRect.width + 2 * Self.sideMargin,
                           height: canvasHeight - (cardRect.minY - Self.bottomMargin)).integral
        if frame.size != maskSize {
            maskSize = frame.size
            effectView.maskImage = Self.mask(size: frame.size, sideFade: Self.sideMargin)
        }
        if effectView.frame != frame { effectView.frame = frame }
        guard show != isShown else { return }
        isShown = show
        if show { effectView.isHidden = false }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = show ? 0.25 : 0.18
            context.timingFunction = CAMediaTimingFunction(name: show ? .easeOut : .easeIn)
            effectView.animator().alphaValue = show ? 1 : 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isShown else { return }
                self.effectView.isHidden = true
            }
        })
    }

    /// Alpha mask: opaque along the top, fading to clear at the bottom and at both sides.
    static func mask(size: CGSize, sideFade: CGFloat) -> NSImage {
        NSImage(size: size, flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let black = NSColor.black
            let vertical = CGGradient(colorsSpace: nil,
                                      colors: [black.withAlphaComponent(0).cgColor, black.withAlphaComponent(0.85).cgColor,
                                               black.cgColor] as CFArray,
                                      locations: [0, 0.55, 1])!
            context.drawLinearGradient(vertical, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: rect.height), options: [])
            context.setBlendMode(.destinationOut)
            let fade = CGGradient(colorsSpace: nil, colors: [black.cgColor, black.withAlphaComponent(0).cgColor] as CFArray,
                                  locations: [0, 1])!
            context.saveGState()
            context.clip(to: CGRect(x: 0, y: 0, width: sideFade, height: rect.height))
            context.drawLinearGradient(fade, start: .zero, end: CGPoint(x: sideFade, y: 0), options: [])
            context.restoreGState()
            context.saveGState()
            context.clip(to: CGRect(x: rect.width - sideFade, y: 0, width: sideFade, height: rect.height))
            context.drawLinearGradient(fade, start: CGPoint(x: rect.width, y: 0), end: CGPoint(x: rect.width - sideFade, y: 0), options: [])
            context.restoreGState()
            return true
        }
    }
}
