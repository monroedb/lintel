import LintelCore
import SwiftUI

/// Expanded card content: Media, Calendar, both side by side ("Duo"), or the clock when nothing is
/// chosen.
struct ExpandedContentView: View {
    let content: ExpandedContent
    let hub: ActivityHub
    /// Card size without the notification band.
    let size: CGSize
    /// Height of the strip beside the notch.
    let bandHeight: CGFloat
    /// This island's Ruler picker (timer page).
    let ruler: TimerRulerModel

    var body: some View {
        Group {
            switch content {
            case .nothing:
                ClockCard()
            case .media:
                NowPlayingPanel(center: hub.nowPlaying, size: size)
            case .calendar:
                CalendarCardView(hub: hub, size: size)
            case .timer:
                TimerCardView(hub: hub, size: size, ruler: ruler)
            case .both:
                HStack(spacing: 0) {
                    NowPlayingColumn(center: hub.nowPlaying)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    Rectangle()
                        .fill(.white.opacity(0.12))
                        .frame(width: 1)
                        .padding(.top, bandHeight + 6)
                        .padding(.bottom, 18)
                    CalendarDuoColumn(hub: hub)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }
                .padding(.horizontal, 18)
                .padding(.top, 14)
            case .shelf:
                ShelfPageView(size: size, bandHeight: bandHeight)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .foregroundStyle(.white)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(content.spokenName.prefix(1).uppercased() + content.spokenName.dropFirst())
    }
}

/// Notification shown inside the expanded card, in the strip level with the notch.
struct NotificationBand: View {
    let kind: NotificationKind
    let hub: ActivityHub
    let base: CGSize
    let width: CGFloat
    let edgeInset: CGFloat

    var body: some View {
        CompactContentView(presentation: .notification(kind), hub: hub, base: base,
                           size: CGSize(width: width, height: base.height), edgeInset: 6)
            .accessibilityLabel("Alert: \(kind.spokenName)")
    }
}

// Media panels (player and the Duo column) are in Media/NowPlayingViews.swift.

/// Shown when the expanded activity is "Nothing": time and date below the notch.
struct ClockCard: View {
    var body: some View {
        MinuteTicks { now in
            VStack(spacing: 2) {
                Text(now, format: .dateTime.hour().minute())
                    .font(.system(size: 40, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(now, format: .dateTime.weekday(.wide).day().month(.wide))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                Capsule()
                    .fill(Brand.copper)
                    .frame(width: 28, height: 3)
                    .padding(.top, 10)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.top, 30)
        }
    }
}
