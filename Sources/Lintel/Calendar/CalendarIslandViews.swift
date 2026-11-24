import LintelCore
import SwiftUI

extension Color {
    init(eventColor: EventColor) {
        self.init(.sRGB, red: eventColor.red, green: eventColor.green, blue: eventColor.blue)
    }
}

extension CalendarSnapshot {
    /// Glyph and ring colour: the calendar's colour when the coloured indicator is on, else copper.
    var tintColor: Color { tint.map(Color.init(eventColor:)) ?? Brand.copper }
}

/// Small calendar badge on the artwork when media and an event share the island.
struct CalendarBadge: View {
    var tint: EventColor?

    var body: some View {
        Circle()
            .fill(tint.map(Color.init(eventColor:)) ?? Brand.copper)
            .overlay {
                Image(systemName: "clock.fill")
                    .font(.system(size: 5.5, weight: .bold))
                    .foregroundStyle(.black.opacity(0.75))
            }
            .overlay(Circle().stroke(.black, lineWidth: 1.5))
            .frame(width: 10, height: 10)
    }
}

/// Leading glyph of the calendar live activity: a calendar with a small clock. Placement fitted to
/// the design's screenshot (17 × 14 pt glyph, 10.5 pt from the body edge, centred 0.75 pt below the
/// band's middle).
struct CalendarGlyph: View {
    let size: CGFloat
    var tint: EventColor?

    var body: some View {
        Image(systemName: "calendar.badge.clock")
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(tint.map(Color.init(eventColor:)) ?? Brand.copper)
            .padding(.leading, 1)
            .offset(y: 1)
    }
}

/// Trailing indicator of the calendar live activity: a countdown to the start ("12m"), then a ring
/// with the progress through the event. `size` is the ring's outer diameter
/// (17 pt, 8.5 pt from the body edge). Its timeline only runs while it is
/// on screen and only ticks when the label or ring would change.
struct CalendarRing: View {
    let calendar: CalendarSnapshot?
    let size: CGFloat
    private let lineWidth: CGFloat = 2.5
    @Environment(\.islandOnScreen) private var onScreen

    var body: some View {
        let start = calendar?.start ?? .distantPast
        if onScreen {
            TimelineView(CalendarIndicatorSchedule(start: start)) { context in
                indicator(at: context.date)
            }
        } else {
            // Off screen: drawn once, ticking again when it can be seen.
            indicator(at: Date())
        }
    }

    @ViewBuilder private func indicator(at date: Date) -> some View {
        if let calendar, date < calendar.start {
            Text(CountdownLabel.compact(until: calendar.start, now: date))
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(calendar.tintColor)
                .lineLimit(1)
                .fixedSize()
                .accessibilityLabel("Starts in \(CountdownLabel.minutes(until: calendar.start, now: date)) minutes")
        } else {
            ZStack {
                Circle().inset(by: lineWidth / 2).stroke(.white.opacity(0.16), lineWidth: lineWidth)
                Circle()
                    .inset(by: lineWidth / 2)
                    .trim(from: 0, to: calendar?.progress(at: date) ?? 0)
                    .stroke(calendar?.tintColor ?? Brand.copper, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: size, height: size)
            .padding(.trailing, 1)
        }
    }
}

/// Updates at each minute boundary before the start (when the rounded-up countdown changes), at the
/// start itself, then every 30 s for the ring.
struct CalendarIndicatorSchedule: TimelineSchedule {
    let start: Date

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
        var next = startDate
        let eventStart = start
        return AnyIterator {
            let current = next
            if current < eventStart {
                let remaining = eventStart.timeIntervalSince(current)
                if remaining <= 60.5 {
                    next = eventStart
                } else {
                    let step = remaining.truncatingRemainder(dividingBy: 60)
                    next = current.addingTimeInterval(step > 0.5 ? step : 60 + step)
                }
            } else {
                next = current.addingTimeInterval(30)
            }
            return current
        }
    }
}
