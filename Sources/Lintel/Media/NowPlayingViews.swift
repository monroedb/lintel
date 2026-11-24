import AppKit
import LintelCore
import SwiftUI

// Media views of the island. Geometry follows the reference
// screenshots measured on the 345 pt card body: artwork 56 pt at (18, 18); title 13.5 pt semibold
// at x 90.5; waveform 6 × 2 pt bars ending 25.5 pt from the right; progress row centred at
// y 93.75 (labels 9.5 pt, bar 53…286.5 pt, 6 pt high); controls centred at y 134.75 with
// previous / play / next at −65.75 / 0 / +66.25 pt from the centre, output at x 302.75.

enum PlayerMetrics {
    static let artwork: CGFloat = 56
    static let artworkOrigin = CGPoint(x: 18, y: 18)
    static let artworkCorner: CGFloat = 12
    static let textX: CGFloat = 90.5
    static let titleTop: CGFloat = 41.2
    static let waveformRight: CGFloat = 25.5
    static let waveformCenterY: CGFloat = 45.75
    static let progressCenterY: CGFloat = 93.75
    static let labelInset: CGFloat = 22
    static let barStart: CGFloat = 53
    static let barEnd: CGFloat = 286.5
    static let barHeight: CGFloat = 6
    static let controlsCenterY: CGFloat = 134.75
    static let previousOffset: CGFloat = -65.75
    static let nextOffset: CGFloat = 66.25
    static let outputCenterX: CGFloat = 302.75
    static let extraCenterX: CGFloat = 42.25
}

extension PaletteColor {
    var color: Color { Color(red: r, green: g, blue: b) }
    var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: 1) }
}

// MARK: - Artwork

/// Compact artwork: cross-fades through a blur when the artwork changes.
struct NowPlayingArtwork: View {
    let center: NowPlayingCenter
    let fallbackSeed: Int
    let size: CGFloat
    let corner: CGFloat

    var body: some View {
        let track = center.track
        ZStack {
            ArtworkImage(image: track?.artwork, seed: fallbackSeed, size: size, corner: corner)
                .id(track?.artworkKey ?? "none")
                .transition(.blurFade)
        }
        .frame(width: size, height: size)
        .animation(.easeInOut(duration: 0.4), value: track?.artworkKey)
    }
}

/// The artwork, or Lintel's generated placeholder.
struct ArtworkImage: View {
    let image: NSImage?
    let seed: Int
    let size: CGFloat
    let corner: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            } else {
                ArtworkView(seed: seed, size: size, corner: corner)
            }
        }
        .frame(width: size, height: size)
    }
}

private struct BlurFade: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        content.blur(radius: active ? 5 : 0).opacity(active ? 0 : 1)
    }
}

extension AnyTransition {
    static var blurFade: AnyTransition {
        .modifier(active: BlurFade(active: true), identity: BlurFade(active: false))
    }
}

/// Player artwork: flips on a track change unless "Disable artwork flip" is on, in which case it
/// cross-fades; artwork that arrives later for the same item cross-fades. Clicking it
/// focuses the source app or browser tab.
struct FlippingArtwork: View {
    let center: NowPlayingCenter
    let size: CGFloat
    let corner: CGFloat
    @State private var displayed: NSImage?
    @State private var displayedKey = "none"
    @State private var identity = ""
    @State private var angle: Double = 0
    @State private var flipping = false

    var body: some View {
        let track = center.track
        ZStack {
            ArtworkImage(image: displayed, seed: NowPlayingController.seed(identity), size: size, corner: corner)
                .id(displayedKey)
                .transition(.blurFade)
        }
        .frame(width: size, height: size)
        .animation(.easeInOut(duration: 0.4), value: displayedKey)
        .rotation3DEffect(.degrees(angle), axis: (x: 0, y: 1, z: 0), perspective: 0.45)
        .opacity(track == nil ? 0.35 : 1)
        .contentShape(Rectangle())
        .onTapGesture { center.focusSource() }
        // Item or artwork changes (tracks of one album share their artwork but still flip).
        .onChange(of: (track?.info.identity ?? "") + "#" + (track?.artworkKey ?? "none"), initial: true) { _, _ in
            update(key: center.track?.artworkKey ?? "none")
        }
        .accessibilityLabel("Artwork")
        .accessibilityAddTraits(.isButton)
    }

    private func update(key: String) {
        let track = center.track
        let newIdentity = track?.info.identity ?? ""
        let trackChanged = !identity.isEmpty && newIdentity != identity
        if newIdentity != identity { identity = newIdentity }
        if flipping { return } // the flip picks up the latest artwork at its midpoint and end
        guard trackChanged, center.appearance.artworkFlip, center.openPlayers > 0 else {
            displayed = track?.artwork
            displayedKey = key
            return
        }
        flipping = true
        withAnimation(.easeIn(duration: 0.16)) { angle = 90 } completion: {
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) {
                displayed = center.track?.artwork
                displayedKey = center.track?.artworkKey ?? "none"
                angle = -90
            }
            withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) { angle = 0 } completion: {
                flipping = false
                if displayedKey != center.track?.artworkKey ?? "none" { update(key: center.track?.artworkKey ?? "none") }
            }
        }
    }
}

// MARK: - Waveform

/// The media waveform: dots when paused or right after a track change, animated bars otherwise,
/// live levels when the process tap runs. Bars are Core Animation layers.
struct MediaWaveform: NSViewRepresentable {
    struct Style: Equatable {
        var bars: Int
        var barWidth: CGFloat
        var gap: CGFloat
        var height: CGFloat
        var dot: CGFloat

        static let compact = Style(bars: 5, barWidth: 2.1, gap: 1.25, height: 14, dot: 2.1)
        static let player = Style(bars: 6, barWidth: 2, gap: 2, height: 14, dot: 2)

        var size: CGSize { CGSize(width: CGFloat(bars) * barWidth + CGFloat(bars - 1) * gap, height: height) }
    }

    let center: NowPlayingCenter
    let style: Style
    /// Whether animations may run (false while the card holding the view is closed).
    var active = true

    func makeNSView(context: Context) -> MediaWaveformLayerView {
        MediaWaveformLayerView(style: style, feed: center.levelFeed)
    }

    func updateNSView(_ view: MediaWaveformLayerView, context: Context) {
        // Off screen (island hidden, displays asleep, compact content behind the card) the bars rest.
        let mode = active && context.environment.islandOnScreen ? center.waveformMode : .flat
        view.update(mode: mode, colors: Self.colors(for: center.track?.palette, count: style.bars))
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MediaWaveformLayerView, context: Context) -> CGSize? {
        style.size
    }

    /// Left-to-right tint from the artwork's colours (copper without artwork).
    static func colors(for palette: ArtworkPalette?, count: Int) -> [NSColor] {
        let stops = palette?.gradient ?? [PaletteColor.copper, PaletteColor.copper]
        return (0..<count).map { index in
            let t = count > 1 ? Double(index) / Double(count - 1) : 0
            let a = stops[0], b = stops[min(1, stops.count - 1)]
            return NSColor(srgbRed: a.r + (b.r - a.r) * t, green: a.g + (b.g - a.g) * t, blue: a.b + (b.b - a.b) * t, alpha: 0.9)
        }
    }
}

final class MediaWaveformLayerView: NSView {
    private let style: MediaWaveform.Style
    private var bars: [CALayer] = []
    private var mode: NowPlayingCenter.WaveformMode?
    private var colors: [NSColor] = []
    private weak var feed: WaveformLevelFeed?
    private static let periods: [Double] = [0.46, 0.58, 0.39, 0.52, 0.44, 0.61]

    init(style: MediaWaveform.Style, feed: WaveformLevelFeed) {
        self.style = style
        self.feed = feed
        super.init(frame: NSRect(origin: .zero, size: style.size))
        wantsLayer = true
        for _ in 0..<style.bars {
            let bar = CALayer()
            bar.cornerRadius = style.barWidth / 2
            bar.backgroundColor = Brand.copperNS.cgColor
            layer?.addSublayer(bar)
            bars.append(bar)
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        MainActor.assumeIsolated { feed?.unsubscribe(self) }
    }

    override var intrinsicContentSize: NSSize { style.size }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, bar) in bars.enumerated() {
            let x = CGFloat(index) * (style.barWidth + style.gap) + style.barWidth / 2
            bar.position = CGPoint(x: x, y: bounds.midY)
            if bar.animation(forKey: "level") == nil {
                bar.bounds = CGRect(x: 0, y: 0, width: style.barWidth, height: restingHeight)
            }
        }
        CATransaction.commit()
    }

    private var restingHeight: CGFloat { mode == .flat || mode == nil ? style.dot : style.height * 0.4 }

    func update(mode newMode: NowPlayingCenter.WaveformMode, colors newColors: [NSColor]) {
        if newColors != colors {
            colors = newColors
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.4)
            for (index, bar) in bars.enumerated() where index < newColors.count {
                bar.backgroundColor = newColors[index].cgColor
            }
            CATransaction.commit()
        }
        guard newMode != mode else { return }
        mode = newMode
        shownHeights = []
        feed?.unsubscribe(self)
        for (index, bar) in bars.enumerated() {
            bar.removeAnimation(forKey: "level")
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.18)
            bar.bounds = CGRect(x: 0, y: 0, width: style.barWidth, height: newMode == .flat ? style.dot : style.height * 0.4)
            CATransaction.commit()
            guard newMode == .simulated else { continue }
            let animation = CABasicAnimation(keyPath: "bounds.size.height")
            animation.fromValue = style.height * 0.22
            animation.toValue = style.height
            animation.duration = Self.periods[index % Self.periods.count]
            animation.autoreverses = true
            animation.repeatCount = .infinity
            animation.timeOffset = Double(index) * 0.17
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            bar.add(animation, forKey: "level")
        }
        if newMode == .live {
            feed?.subscribe(self) { [weak self] levels in self?.show(levels: levels) }
        }
    }

    /// Bar heights last committed for live levels.
    private var shownHeights: [CGFloat] = []

    private func show(levels: [Float]) {
        let values = resampleLevels(levels, to: bars.count)
        let heights = values.map { max(style.dot, style.height * CGFloat($0)) }
        // Each update is a Core Animation commit (a message to the window server) ~30 times a second;
        // when no bar would move visibly, nothing is committed (`WaveformStep`).
        guard WaveformStep.isVisible(heights.map(Double.init), from: shownHeights.map(Double.init)) else { return }
        shownHeights = heights
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.08)
        for (index, bar) in bars.enumerated() {
            bar.bounds = CGRect(x: 0, y: 0, width: style.barWidth, height: heights[index])
        }
        CATransaction.commit()
    }
}

/// Compact trailing waveform (removed with "Disable compact waveform").
struct NowPlayingCompactWaveform: View {
    let center: NowPlayingCenter

    var body: some View {
        if center.appearance.compactWaveform {
            MediaWaveform(center: center, style: .compact)
                .padding(.trailing, 2)
        }
    }
}

// MARK: - Player (media only)

/// The open player: artwork, title and artist with a waveform badge; elapsed, progress
/// and remaining time; previous, play/pause and next with the output button on the right and the
/// optional extra control on the left.
struct NowPlayingPanel: View {
    let center: NowPlayingCenter
    /// Card body size (345 × 175).
    let size: CGSize

    var body: some View {
        let track = center.track
        let open = center.openPlayers > 0
        ZStack(alignment: .topLeading) {
            FlippingArtwork(center: center, size: PlayerMetrics.artwork, corner: PlayerMetrics.artworkCorner)
                .offset(x: PlayerMetrics.artworkOrigin.x, y: PlayerMetrics.artworkOrigin.y)
                .overlay(alignment: .topLeading) { AutoMixRing(center: center).offset(x: PlayerMetrics.artworkOrigin.x, y: PlayerMetrics.artworkOrigin.y) }

            TrackTitles(center: center, width: size.width - PlayerMetrics.textX - 60, animate: open)
                .offset(x: PlayerMetrics.textX, y: PlayerMetrics.titleTop)

            if track != nil {
                MediaWaveform(center: center, style: .player, active: open)
                    .frame(width: MediaWaveform.Style.player.size.width, height: MediaWaveform.Style.player.size.height)
                    .offset(x: size.width - PlayerMetrics.waveformRight - MediaWaveform.Style.player.size.width,
                            y: PlayerMetrics.waveformCenterY - MediaWaveform.Style.player.height / 2)
            }

            ProgressRow(center: center, width: size.width)
                .offset(y: PlayerMetrics.progressCenterY - 8)

            ControlsRow(center: center, width: size.width)
                .offset(y: PlayerMetrics.controlsCenterY - 18)

            if let notice = center.notice {
                Text(notice)
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.white.opacity(0.14)))
                    .frame(width: size.width)
                    .offset(y: 154)
                    .transition(.opacity)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .animation(.easeOut(duration: 0.2), value: center.notice)
        .contextMenuHint()
    }
}

/// Title (with badge, marquee when long) and artist (with a podcast glyph); AutoMix shows the
/// incoming track beneath.
struct TrackTitles: View {
    let center: NowPlayingCenter
    let width: CGFloat
    var animate = true
    var titleSize: CGFloat = 13.5
    var artistSize: CGFloat = 12.5

    var body: some View {
        let track = center.track
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                MarqueeText(text: track?.title ?? "Nothing playing", font: .system(size: titleSize, weight: .semibold),
                            maxWidth: width - badgeWidth(track), animate: animate)
                    .id("\(track?.title ?? "")|\(animate)")
                    .foregroundStyle(.white)
                TitleBadge(center: center)
            }
            HStack(spacing: 4) {
                if track?.info.kind == .podcast {
                    Image(systemName: "mic.fill").font(.system(size: artistSize - 3, weight: .semibold))
                }
                Text(subtitle(track))
                    .font(.system(size: artistSize, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(.white.opacity(0.5))
            .frame(maxWidth: width, alignment: .leading)
            if let incoming = center.autoMix.incoming, center.autoMix.phase != .idle {
                Text("Mixing into \(incoming.title)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Brand.copper)
                    .lineLimit(1)
                    .padding(.top, 2)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: center.autoMix.phase)
    }

    private func subtitle(_ track: NowPlayingCenter.Track?) -> String {
        guard let track else { return "Media you play appears here" }
        if !track.info.artist.isEmpty { return track.info.artist }
        return track.appName ?? track.info.album
    }

    private func badgeWidth(_ track: NowPlayingCenter.Track?) -> CGFloat {
        guard let track else { return 0 }
        switch center.appearance.titleBadge {
        case .none: return 0
        case .explicit: return track.info.explicit == true ? 18 : 0
        case .format: return track.info.format == nil ? 0 : 70
        }
    }
}

/// Explicit "E" tag or audio-format badge (title badge).
struct TitleBadge: View {
    let center: NowPlayingCenter

    var body: some View {
        if let info = center.track?.info {
            switch center.appearance.titleBadge {
            case .none:
                EmptyView()
            case .explicit:
                if info.explicit == true {
                    Text("E")
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(.black)
                        .frame(width: 13, height: 13)
                        .background(RoundedRectangle(cornerRadius: 3, style: .continuous).fill(Color.white.opacity(0.55)))
                        .accessibilityLabel("Explicit")
                }
            case .format:
                if let format = info.format {
                    HStack(spacing: 3) {
                        Image(systemName: format == .dolbyAtmos ? "dot.radiowaves.left.and.right" : "waveform")
                            .font(.system(size: 8, weight: .bold))
                        Text(format == .hiResLossless ? "HI-RES" : (format == .dolbyAtmos ? "ATMOS" : "LOSSLESS"))
                            .font(.system(size: 8, weight: .bold))
                    }
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.horizontal, 5)
                    .frame(height: 13)
                    .overlay(Capsule().stroke(Color.white.opacity(0.35), lineWidth: 1))
                    .accessibilityLabel(format.label)
                }
            }
        }
    }
}

/// A single line that scrolls back and forth when it doesn't fit (marquee). Callers key
/// it by text and open state (`.id`), so a new title or a closed card starts from a fresh view
/// and no repeating animation outlives it.
struct MarqueeText: View {
    let text: String
    let font: Font
    let maxWidth: CGFloat
    var animate = true
    @State private var textWidth: CGFloat = 0
    @State private var scrolling = false

    var body: some View {
        let overflow = max(0, textWidth - maxWidth)
        Text(text)
            .font(font)
            .lineLimit(1)
            .fixedSize()
            .background(GeometryReader { geo in
                Color.clear.onAppear { textWidth = geo.size.width }
            })
            .offset(x: scrolling ? -(overflow + 12) : 0)
            .frame(width: textWidth > 0 ? min(maxWidth, textWidth) : maxWidth, alignment: .leading)
            .clipped()
            .mask(fadeMask(overflow: overflow))
            .onChange(of: textWidth) { _, width in
                guard animate, width - maxWidth > 0, !scrolling else { return }
                let distance = width - maxWidth + 12
                withAnimation(.linear(duration: Double(distance) / 28).delay(1.5).repeatForever(autoreverses: true)) {
                    scrolling = true
                }
            }
    }

    @ViewBuilder private func fadeMask(overflow: CGFloat) -> some View {
        if overflow > 0 {
            LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.9),
                                   .init(color: .clear, location: 1)], startPoint: .leading, endPoint: .trailing)
        } else {
            Rectangle()
        }
    }
}

/// Elapsed · draggable progress bar · remaining ("-m:ss"); "LIVE" for streams without a length.
struct ProgressRow: View {
    let center: NowPlayingCenter
    let width: CGFloat
    @State private var dragFraction: Double?

    private static let labelFont = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .medium)

    private static func textWidth(_ text: String) -> Double {
        ceil((text as NSString).size(withAttributes: [.font: labelFont]).width)
    }

    var body: some View {
        let info = center.track?.info
        let duration = info?.knownDuration
        let position = center.position()
        let fraction = dragFraction ?? duration.map { min(1, max(0, position / $0)) } ?? 0
        let shown = dragFraction.flatMap { f in duration.map { $0 * f } } ?? position
        let live = info?.kind == .liveStream && info?.playing == true
        let elapsedText = PlayerProgressLayout.format(shown)
        let remainingText = live ? "LIVE" : "-" + PlayerProgressLayout.format(max(0, (duration ?? 0) - shown))
        let span = PlayerProgressLayout.bar(width: width, labelInset: PlayerMetrics.labelInset,
                                            referenceStart: PlayerMetrics.barStart, referenceEnd: PlayerMetrics.barEnd,
                                            elapsedWidth: Self.textWidth(elapsedText), remainingWidth: Self.textWidth(remainingText))
        let barStart = CGFloat(span.start), barEnd = CGFloat(span.end)
        ZStack(alignment: .topLeading) {
            Text(elapsedText)
                .fixedSize()
                .frame(width: barStart - PlayerMetrics.labelInset - 4, height: 16, alignment: .leading)
                .offset(x: PlayerMetrics.labelInset)
            bar(fraction: fraction, width: barEnd - barStart, seekable: duration != nil && info?.capabilities.contains(.seek) == true,
                duration: duration)
                .offset(x: barStart, y: 8 - PlayerMetrics.barHeight / 2)
            Text(remainingText)
                .fixedSize()
                .foregroundStyle(live ? AnyShapeStyle(Brand.copper) : AnyShapeStyle(.white.opacity(0.46)))
                .frame(width: width - barEnd - PlayerMetrics.labelInset - 4, height: 16, alignment: .trailing)
                .offset(x: barEnd + 4)
        }
        .font(.system(size: 9.5, weight: .medium).monospacedDigit())
        .foregroundStyle(.white.opacity(0.46))
        .frame(width: width, height: 16, alignment: .topLeading)
        .opacity(info == nil ? 0.4 : 1)
    }

    private func bar(fraction: Double, width: CGFloat, seekable: Bool, duration: Double?) -> some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Color.white.opacity(0.14))
            Capsule()
                .fill(fill)
                .frame(width: max(fraction > 0 ? PlayerMetrics.barHeight : 0, width * fraction))
        }
        .frame(width: width, height: PlayerMetrics.barHeight)
        .contentShape(Rectangle().inset(by: -8))
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard seekable else { return }
                dragFraction = min(1, max(0, value.location.x / width))
            }
            .onEnded { value in
                guard seekable, let duration else { return }
                let target = min(1, max(0, value.location.x / width)) * duration
                center.perform(.seek(to: target))
                dragFraction = nil
            })
        .accessibilityLabel("Playback position")
    }

    /// Monochrome (grey), Colored (artwork accent) or Gradient (artwork colours).
    private var fill: AnyShapeStyle {
        let palette = center.track?.palette
        switch center.appearance.progressStyle {
        case .mono:
            return AnyShapeStyle(Color(white: 0.475))
        case .color:
            return AnyShapeStyle((palette?.accent ?? .copper).color)
        case .gradient:
            let stops = palette?.gradient ?? [PaletteColor(r: 0.6, g: 0.33, b: 0.16), .copper]
            return AnyShapeStyle(LinearGradient(colors: stops.map(\.color), startPoint: .leading, endPoint: .trailing))
        }
    }
}

/// Previous · play/pause · next, the extra control on the left and the output button on the right.
struct ControlsRow: View {
    let center: NowPlayingCenter
    let width: CGFloat

    var body: some View {
        let track = center.track
        let playing = track?.info.playing ?? false
        let mid = width / 2
        ZStack(alignment: .topLeading) {
            ExtraControlButton(center: center)
                .position(x: PlayerMetrics.extraCenterX, y: 18)
            TransportButton(symbol: "backward.fill", size: 18, weight: .semibold, label: "Previous") {
                center.perform(.previous)
            }
            .position(x: mid + PlayerMetrics.previousOffset, y: 18)
            TransportButton(symbol: playing ? "pause.fill" : "play.fill", size: playing ? 30.5 : 28, weight: .regular,
                            label: playing ? "Pause" : "Play") {
                center.togglePlayPause()
            }
            .position(x: mid, y: 18)
            TransportButton(symbol: "forward.fill", size: 18, weight: .semibold, label: "Next") {
                center.perform(.next)
            }
            .position(x: mid + PlayerMetrics.nextOffset, y: 18)
            OutputButton(center: center)
                .position(x: PlayerMetrics.outputCenterX, y: 18)
        }
        .frame(width: width, height: 36)
        .disabled(track == nil)
        .opacity(track == nil ? 0.4 : 1)
    }
}

struct TransportButton: View {
    let symbol: String
    let size: CGFloat
    let weight: Font.Weight
    let label: String
    var tint: Color = .white
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: weight))
                .foregroundStyle(tint)
                .frame(width: 44, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityLabel(label)
    }
}

/// Slight shrink while pressed.
struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// The current output device's glyph (laptop for the built-in speakers); opens the output menu.
struct OutputButton: View {
    let center: NowPlayingCenter

    var body: some View {
        let device = center.currentOutput
        let symbol = device?.symbolNames(builtInIsLaptop: center.builtInIsLaptop)
            .first { NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil } ?? "laptopcomputer"
        Button { center.showOutputMenu() } label: {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(.white.opacity(0.44))
                .frame(width: 40, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityLabel("Output: \(device?.name ?? "default")")
    }
}

/// Favourite / Shuffle / Repeat / Copy link (settings `controlChoice`), shown when the source
/// supports it.
struct ExtraControlButton: View {
    let center: NowPlayingCenter

    var body: some View {
        if let track = center.track, let (symbol, on, label) = descriptor(track) {
            Button { center.performExtraControl() } label: {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(on ? AnyShapeStyle(Brand.copper) : AnyShapeStyle(Color.white.opacity(0.44)))
                    .frame(width: 40, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressScaleStyle())
            .accessibilityLabel(label)
        }
    }

    private func descriptor(_ track: NowPlayingCenter.Track) -> (String, Bool, String)? {
        let info = track.info
        switch center.appearance.extraControl {
        case .favorite:
            guard track.capabilities.contains(.favorite) else { return nil }
            return (info.favorite == true ? "heart.fill" : "heart", info.favorite == true, "Favourite")
        case .shuffle:
            guard track.capabilities.contains(.shuffle) else { return nil }
            return ("shuffle", info.shuffle == true, "Shuffle")
        case .repeating:
            guard track.capabilities.contains(.repeatMode) else { return nil }
            let mode = info.repeatMode ?? .off
            return (mode == .one ? "repeat.1" : "repeat", mode != .off, "Repeat")
        case .copyLink:
            guard track.canCopyLink else { return nil }
            return ("link", false, "Copy link")
        }
    }
}

/// AutoMix: a two-tone ring that sweeps around the artwork while the next track mixes in.
/// The sweeping ring only exists during a transition, so its repeating animation ends with it.
struct AutoMixRing: View {
    let center: NowPlayingCenter

    var body: some View {
        let phase = center.autoMix.phase
        ZStack {
            if phase != .idle {
                SweepingRing()
                    .opacity(phase == .finishing ? 0.3 : 1)
                    .scaleEffect(phase == .itemChanged ? 1.04 : 1)
                    .transition(.opacity)
            }
        }
        .frame(width: PlayerMetrics.artwork + 6, height: PlayerMetrics.artwork + 6)
        .offset(x: -3, y: -3)
        .animation(.easeInOut(duration: 0.35), value: phase)
        .allowsHitTesting(false)
    }
}

private struct SweepingRing: View {
    @State private var sweep = false

    var body: some View {
        RoundedRectangle(cornerRadius: PlayerMetrics.artworkCorner + 3, style: .continuous)
            .stroke(AngularGradient(colors: [Brand.copper, Brand.copper.opacity(0.1), Brand.copper],
                                    center: .center, angle: .degrees(sweep ? 360 : 0)), lineWidth: 2)
            .onAppear {
                withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) { sweep = true }
            }
    }
}

// MARK: - Duo column

/// Media half of the side-by-side card: artwork beside the notch, titles, transport.
struct NowPlayingColumn: View {
    let center: NowPlayingCenter

    var body: some View {
        let playing = center.track?.info.playing ?? false
        VStack(alignment: .leading, spacing: 0) {
            // Reference Duo shot: artwork 56 pt at (18, 18) like the player; title cap top at y 86.
            FlippingArtwork(center: center, size: PlayerMetrics.artwork, corner: PlayerMetrics.artworkCorner)
                .padding(.top, 4)
            TrackTitles(center: center, width: 137.5, animate: center.openPlayers > 0)
                .padding(.leading, 2.5)
                .padding(.top, 8.65)
            HStack(spacing: 1.5) {
                TransportButton(symbol: "backward.fill", size: 17, weight: .regular, label: "Previous") { center.perform(.previous) }
                TransportButton(symbol: playing ? "pause.fill" : "play.fill", size: playing ? 28 : 26, weight: .regular,
                                label: playing ? "Pause" : "Play") { center.togglePlayPause() }
                TransportButton(symbol: "forward.fill", size: 17, weight: .regular, label: "Next") { center.perform(.next) }
            }
            .padding(.leading, 1.75)
            .padding(.top, 9.5)
            .disabled(center.track == nil)
        }
        .padding(.trailing, 12)
    }
}

private extension View {
    /// Placeholder for the player area's accessibility grouping.
    func contextMenuHint() -> some View {
        accessibilityElement(children: .contain).accessibilityLabel("Now Playing")
    }
}
