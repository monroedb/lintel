import AppKit
import LintelCore
import SwiftUI

/// Compact island content: a leading and a trailing slot on either side of the notch (or the
/// pill's centre), plus a second row for Quick Peek.
struct CompactContentView: View {
    let presentation: CompactPresentation
    let hub: ActivityHub
    /// Notch/pill size the slots sit beside.
    let base: CGSize
    /// Current drawn size of the island.
    let size: CGSize
    /// Inset that keeps glyphs clear of the notch's curved ears.
    let edgeInset: CGFloat

    private var slot: CGFloat { max(0, (size.width - base.width) / 2) }

    var body: some View {
        let slot = self.slot
        let band = isPeek ? min(size.height, base.height) : size.height
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                leading
                    .frame(width: slot, height: band, alignment: .leading)
                    .padding(.leading, 0)
                Spacer(minLength: 0)
                trailing
                    .frame(width: slot, height: band, alignment: .trailing)
            }
            .frame(width: size.width, height: band)
            if case .peek(let kind) = presentation {
                PeekRow(kind: kind, hub: hub)
                    .padding(.horizontal, 18 + edgeInset)
                    .frame(width: size.width, height: max(0, size.height - band))
            }
        }
        .frame(width: size.width, height: size.height, alignment: .top)
    }

    private var isPeek: Bool {
        if case .peek = presentation { return true }
        return false
    }

    private var padding: CGFloat { edgeInset + 8 }

    @ViewBuilder private var leading: some View {
        switch presentation {
        case .idle:
            EmptyView()
        case .lock:
            Image(systemName: "lock.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.leading, padding)
        case .live(let kinds) where kinds.contains(.timer):
            TimerCompactLeading(kinds: kinds, hub: hub, padding: padding)
        case .live(let kinds) where kinds == [.shelf]:
            ShelfCompactGlyph()
                .padding(.leading, padding)
        case .live(let kinds):
            Group {
                if kinds.contains(.media) {
                    NowPlayingArtwork(center: hub.nowPlaying, fallbackSeed: hub.media?.artworkSeed ?? 0, size: 20, corner: 5)
                        .overlay(alignment: .bottomTrailing) {
                            if kinds.contains(.calendar) { CalendarBadge(tint: hub.calendar?.tint).offset(x: 4, y: 4) }
                        }
                } else {
                    CalendarGlyph(size: 14, tint: hub.calendar?.tint)
                }
            }
            .padding(.leading, padding)
        case .notification(let kind):
            let payload = hub.payloads[kind] ?? .make(kind, value: nil)
            if kind.isSystemAlert {
                SystemAlertLeading(kind: kind, payload: payload, padding: padding)
            } else if kind.isHUD, let hudKind = HUDKind(notification: kind) {
                HUDLeadingView(kind: hudKind, payload: payload, state: hub.hud, slot: slot, leadingPadding: padding + 1)
                    .padding(.leading, padding + 1)
            } else {
                Image(systemName: payload.symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Brand.copper)
                    .padding(.leading, padding)
            }
        case .peek(let kind):
            Group {
                if kind == .media {
                    NowPlayingArtwork(center: hub.nowPlaying, fallbackSeed: hub.media?.artworkSeed ?? 0, size: 18, corner: 4)
                } else {
                    CalendarGlyph(size: 13, tint: hub.calendar?.tint)
                }
            }
            .padding(.leading, padding)
        }
    }

    @ViewBuilder private var trailing: some View {
        switch presentation {
        case .idle, .lock:
            EmptyView()
        case .live(let kinds) where kinds.contains(.timer):
            TimerCompactTrailing(timer: hub.timer, slot: slot, padding: padding)
        case .live(let kinds) where kinds == [.shelf]:
            ShelfCompactCount(count: hub.shelf?.count ?? 0)
                .padding(.trailing, padding)
        case .live(let kinds):
            Group {
                if kinds.contains(.calendar) {
                    CalendarRing(calendar: hub.calendar, size: 17)
                } else {
                    FocusAwareWaveform(hub: hub)
                }
            }
            .padding(.trailing, padding)
        case .notification(let kind):
            let payload = hub.payloads[kind] ?? .make(kind, value: nil)
            if kind.isSystemAlert {
                SystemAlertTrailing(kind: kind, payload: payload, padding: padding)
            } else if kind.isHUD, let hudKind = HUDKind(notification: kind) {
                HUDTrailingView(kind: hudKind, payload: payload, state: hub.hud, slot: slot, trailingPadding: padding + 3)
                    .padding(.trailing, padding + 3)
            } else if let level = payload.level {
                LevelBar(level: level)
                    .frame(width: 58)
                    .padding(.trailing, padding + 4)
            } else {
                Text(payload.value ?? "")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Brand.copper)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.trailing, padding)
            }
        case .peek(let kind):
            Group {
                if kind == .media {
                    NowPlayingCompactWaveform(center: hub.nowPlaying)
                } else {
                    CalendarRing(calendar: hub.calendar, size: 15)
                }
            }
            .padding(.trailing, padding)
        }
    }
}

/// Second row of a Quick Peek: the new title (media) or the starting event (calendar).
struct PeekRow: View {
    let kind: QuickPeekKind
    let hub: ActivityHub

    var body: some View {
        HStack(spacing: 10) {
            if kind == .media {
                VStack(alignment: .leading, spacing: 1) {
                    Text(hub.media?.title ?? "Now playing")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(hub.media?.artist ?? "")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                }
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    Text(hub.calendar?.title ?? "Event")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(hub.calendar.map { CountdownLabel.peekCaption(start: $0.start, now: Date()) } ?? "Starting now")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(hub.calendar?.tintColor ?? Brand.copper)
                }
            }
            Spacer(minLength: 0)
        }
        .lineLimit(1)
    }
}

/// Lintel's generated placeholder artwork (until real artwork arrives with Now Playing).
struct ArtworkView: View {
    let seed: Int
    let size: CGFloat
    let corner: CGFloat

    var body: some View {
        let hue = Double(seed % 360) / 360
        RoundedRectangle(cornerRadius: corner, style: .continuous)
            .fill(LinearGradient(colors: [Color(hue: hue, saturation: 0.55, brightness: 0.85),
                                          Color(hue: (hue + 0.12).truncatingRemainder(dividingBy: 1), saturation: 0.7, brightness: 0.45)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay {
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.42, weight: .bold))
                    .foregroundStyle(.white.opacity(0.75))
            }
            .frame(width: size, height: size)
    }
}

/// HUD level bar.
struct LevelBar: View {
    let level: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.2))
                Capsule().fill(.white).frame(width: max(4, geo.size.width * min(1, max(0, level))))
            }
        }
        .frame(height: 4)
        .animation(.easeOut(duration: 0.12), value: level)
    }
}
