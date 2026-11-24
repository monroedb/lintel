import CoreGraphics
import Foundation
import ImageIO
import LintelCore

/// Checks for island support logic: swap plans, haptic debounce, programmatic open/close and peek
/// dismissal.
func runIslandSupportChecks() {
    // MARK: Swap plans
    check(SwapPlan.between(.idle, .notification(.volume)) == .grow, "idle → HUD grows directly")
    check(SwapPlan.between(.live([.calendar]), .notification(.volume)) == .contractThenGrow,
          "live → HUD contracts to the notch first (measured sequence)")
    check(SwapPlan.between(.notification(.volume), .live([.calendar])) == .contractThenGrow, "HUD → live restores via the notch")
    check(SwapPlan.between(.live([.media]), .live([.media, .calendar])) == .morph, "adding a live activity morphs")
    check(SwapPlan.between(.live([.media]), .idle) == .contract, "ending the last activity contracts")
    check(SwapPlan.between(.notification(.volume), .notification(.volume)) == .none, "same HUD updates in place")
    check(SwapPlan.between(.live([.calendar]), .peek(.calendar)) == .morph, "a peek grows out of the live activity")
    check(SwapPlan.between(.peek(.media), .live([.calendar])) == .morph, "peek end shrinks back to the live activity")
    check(SwapPlan.between(.peek(.media), .notification(.focus)) == .contractThenGrow, "an alert replaces a peek via the notch")

    // MARK: Haptic debounce
    var gate = HapticGate(interval: 0.12)
    check(gate.shouldFire(now: 1.0), "first haptic fires")
    check(!gate.shouldFire(now: 1.05), "haptic within the debounce window dropped")
    check(gate.shouldFire(now: 1.2), "haptic after the window fires")

    // MARK: Programmatic open / close
    var interaction = IslandInteraction()
    let cfg = InteractionConfig(expandOnHover: false, hoverDelay: 0)
    _ = interaction.pointerEntered(cfg)
    _ = interaction.open()
    check(interaction.phase == .expanded, "swipe down opens")
    _ = interaction.close()
    check(interaction.phase == .elevated, "swipe up closes to the elevated shape while the pointer is inside")
    _ = interaction.pointerExited(cfg)
    _ = interaction.collapseTimerFired()
    check(interaction.phase == .idle, "leaving after a swipe-close rests")
    var away = IslandInteraction()
    _ = away.open()
    _ = away.close()
    check(away.phase == .idle, "close without the pointer inside rests")
    check(away.close().isEmpty, "closing a closed island does nothing")

    // MARK: Peek dismissal and dismissible state
    var engine = ActivityEngine()
    check(!engine.hasDismissible, "nothing to dismiss while idle")
    _ = engine.requestPeek(.media, userInitiated: false, now: 0)
    check(engine.hasDismissible, "a peek can be swiped away")
    check(engine.dismissPeek() && engine.compactPresentation == .idle, "peek dismissed")
    engine.setLive(.calendar, active: true, identity: "c", now: 1)
    check(engine.hasDismissible, "a live activity can be dismissed")
    check(ExpandedContent(idle: .both) == .both && ExpandedContent(idle: .nothing) == .nothing, "idle setting maps to content")

    // MARK: Desktop-picture sampling (aspect fill, top-centre strip)
    func picture(width: Int, height: Int, topBand: CGFloat, top: CGFloat, rest: CGFloat) -> CGImage? {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(srgbRed: rest, green: rest, blue: rest, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(srgbRed: top, green: top, blue: top, alpha: 1))
        // CoreGraphics origin is bottom-left: the band is the image's top rows.
        context.fill(CGRect(x: 0, y: CGFloat(height) * (1 - topBand), width: CGFloat(width), height: CGFloat(height) * topBand))
        return context.makeImage()
    }
    let screen = CGSize(width: 1710, height: 1107)
    if let dark = picture(width: 855, height: 554, topBand: 0.08, top: 0.05, rest: 0.95),
       let light = picture(width: 855, height: 554, topBand: 0.08, top: 0.95, rest: 0.05),
       let wide = picture(width: 1200, height: 400, topBand: 0.12, top: 0.05, rest: 0.95) {
        let d = WallpaperSampler.sample(image: dark, screenSize: screen) ?? -1
        let l = WallpaperSampler.sample(image: light, screenSize: screen) ?? -1
        let w = WallpaperSampler.sample(image: wide, screenSize: screen) ?? -1
        check(d >= 0 && Luminance.shouldOutline(luminance: d), "dark strip under the island → outline (\(d))")
        check(l > 0.5 && !Luminance.shouldOutline(luminance: l), "light strip under the island → no outline (\(l))")
        check(w >= 0 && w < 0.25, "aspect-fill crop keeps the top strip on a wider picture (\(w))")
        // The file path: write the dark picture as PNG, sample it through ImageIO, remove it.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lintel-check-\(UUID().uuidString).png")
        if let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) {
            CGImageDestinationAddImage(destination, dark, nil)
            _ = CGImageDestinationFinalize(destination)
        }
        let fromFile = WallpaperSampler.sample(url: url, screenSize: screen) ?? -1
        try? FileManager.default.removeItem(at: url)
        check(fromFile >= 0 && abs(fromFile - d) < 0.02, "sampling a picture file matches the in-memory result (\(fromFile))")
    } else {
        check(false, "could not create test pictures")
    }
}
