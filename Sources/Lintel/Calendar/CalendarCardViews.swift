import AppKit
import LintelCore
import SwiftUI

/// Layout of the open calendar card, fitted to the design screenshots (weekday caps at
/// 21–28 pt, day digits 36.5–60 pt, 18 pt from the body's edges; tomorrow's events start just
/// below the notch).
enum CalendarCardStyle {
    static let horizontalPadding: CGFloat = 18
    static let topPadding: CGFloat = 18.5
    static let bottomPadding: CGFloat = 10
    static let columnGap: CGFloat = 12
    static let cardSpacing: CGFloat = 5
    static let listTopSpacing: CGFloat = 4
    static let headerFont = Font.system(size: 10, weight: .bold)
    static let overflowHeight: Double = 12

    /// Card heights used to decide how many fit, as rendered: all-day rows are one line (25 pt),
    /// timed events add the time (39 pt) and, with a place, a third line (53 pt).
    static func estimatedHeight(_ event: CalendarEventRecord) -> Double {
        let placeLine: Double = place(for: event) == nil ? 0 : 14
        return (event.isAllDay ? 25 : 39) + placeLine
    }

    /// The event's place as text, unless it is only a link.
    static func place(for event: CalendarEventRecord) -> String? {
        guard let text = event.location?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        var probe = event
        probe.latitude = nil
        probe.longitude = nil
        return TimeToLeavePlanner.hasPlace(probe) ? text : nil
    }
}

/// What the card shows: the agenda's lists, or (while the agenda is off) only the island's calendar
/// activity.
struct CalendarCardData {
    var today: AgendaDay
    var tomorrow: AgendaDay
    var month: MonthGrid?
    var busyDays: Set<Date> = []
    var showDots = false

    @MainActor
    static func current(feature: CalendarFeature?, activity: CalendarSnapshot?, now: Date) -> CalendarCardData {
        if let feature, feature.agenda.isActive {
            let agenda = feature.agenda
            return CalendarCardData(today: agenda.today, tomorrow: agenda.tomorrow, month: agenda.month,
                                    busyDays: agenda.busyDays, showDots: feature.settings[Keys.calendarEventDots])
        }
        let calendar = Calendar.current
        let events = activity.map {
            [CalendarEventRecord(id: $0.identity, calendarID: "demo", title: $0.title, start: $0.start, end: $0.end, color: $0.tint ?? .copper)]
        } ?? []
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now
        return CalendarCardData(today: AgendaBuilder.day(now, events: events, now: now, calendar: calendar),
                                tomorrow: AgendaBuilder.day(tomorrow, events: [], now: now, calendar: calendar))
    }
}

/// Calendar-only open card: today on the left; tomorrow — or this month —
/// on the right.
struct CalendarCardView: View {
    let hub: ActivityHub
    let size: CGSize

    var body: some View {
        let feature = CalendarFeature.shared
        MinuteTicks { now in
            let data = CalendarCardData.current(feature: feature, activity: hub.calendar, now: now)
            HStack(alignment: .top, spacing: CalendarCardStyle.columnGap) {
                VStack(alignment: .leading, spacing: 0) {
                    CalendarDateHeader(date: now, alignment: .leading, feature: feature)
                    AgendaEventList(feature: feature, day: data.today, now: now, isToday: true)
                        .padding(.top, CalendarCardStyle.listTopSpacing)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                if let month = data.month {
                    MonthGridColumn(grid: month, busyDays: data.busyDays, showDots: data.showDots)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Tomorrow")
                            .textCase(.uppercase)
                            .font(CalendarCardStyle.headerFont)
                            .foregroundStyle(.white.opacity(0.45))
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        AgendaEventList(feature: feature, day: data.tomorrow, now: now, isToday: false,
                                        emptyAlignment: .trailing)
                            .padding(.top, CalendarCardStyle.listTopSpacing)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            .padding(.horizontal, CalendarCardStyle.horizontalPadding)
            .padding(.top, CalendarCardStyle.topPadding)
            .padding(.bottom, CalendarCardStyle.bottomPadding)
        }
        .frame(width: size.width, height: size.height, alignment: .top)
    }
}

/// Calendar half of the side-by-side card: today's date (right-aligned) and today's events.
struct CalendarDuoColumn: View {
    let hub: ActivityHub

    var body: some View {
        let feature = CalendarFeature.shared
        MinuteTicks { now in
            let data = CalendarCardData.current(feature: feature, activity: hub.calendar, now: now)
            VStack(alignment: .trailing, spacing: 0) {
                CalendarDateHeader(date: now, alignment: .trailing, feature: feature)
                AgendaEventList(feature: feature, day: data.today, now: now, isToday: true, emptyAlignment: .trailing)
                    .padding(.top, CalendarCardStyle.listTopSpacing)
            }
            // The side-by-side container starts 14 pt down; line the date up with the calendar card.
            .padding(.top, CalendarCardStyle.topPadding - 14)
            .padding(.bottom, CalendarCardStyle.bottomPadding - 4)
        }
    }
}

/// Abbreviated weekday over the day number; a click opens the calendar app.
struct CalendarDateHeader: View {
    let date: Date
    let alignment: HorizontalAlignment
    let feature: CalendarFeature?

    var body: some View {
        VStack(alignment: alignment, spacing: -3) {
            Text(date, format: .dateTime.weekday(.abbreviated))
                .textCase(.uppercase)
                .font(CalendarCardStyle.headerFont)
                .foregroundStyle(Brand.copper)
            Text(date, format: .dateTime.day())
                .font(.system(size: 33, weight: .light))
                .monospacedDigit()
                // Drop most of the descender space so the list starts just below the digits.
                .padding(.bottom, -7)
        }
        .contentShape(Rectangle())
        .onTapGesture { feature?.openToday() }
        .help(feature.map { "Open \($0.calendarApp.title)" } ?? "")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

/// A day's events as cards, as many as fit, then "+N more"; or the empty state.
struct AgendaEventList: View {
    let feature: CalendarFeature?
    let day: AgendaDay
    let now: Date
    let isToday: Bool
    /// Alignment of the empty state (right-hand columns align it with their header).
    var emptyAlignment: Alignment = .leading

    var body: some View {
        GeometryReader { geometry in
            let events = day.events
            if events.isEmpty {
                CalendarEmptyDay(feature: feature, empty: day.empty, isToday: isToday)
                    .frame(width: geometry.size.width, alignment: emptyAlignment)
            } else {
                let fit = AgendaLayout.fittingCount(heights: events.map(CalendarCardStyle.estimatedHeight),
                                                    available: Double(geometry.size.height),
                                                    spacing: Double(CalendarCardStyle.cardSpacing),
                                                    overflowLine: CalendarCardStyle.overflowHeight)
                VStack(alignment: .leading, spacing: CalendarCardStyle.cardSpacing) {
                    ForEach(events.prefix(fit)) { event in
                        AgendaEventCard(feature: feature, event: event, now: now)
                    }
                    if fit < events.count {
                        Text("+\(events.count - fit) more")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.45))
                            .padding(.leading, 2)
                    }
                }
                .frame(width: geometry.size.width, alignment: .leading)
            }
        }
    }
}

/// One event: a bar in the calendar's colour, the title (optionally tinted), the time range and the
/// place. Click joins the meeting or shows the event; ⌥-click does the other.
struct AgendaEventCard: View {
    let feature: CalendarFeature?
    let event: CalendarEventRecord
    let now: Date

    var body: some View {
        let color = Color(eventColor: event.color.readableOnBlack())
        let tintTitle = feature?.settings[Keys.calendarTintTitles] ?? false
        let hovered = feature?.agenda.hoveredEventID == event.id
        HStack(alignment: .top, spacing: 6) {
            Capsule().fill(color).frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                if event.isAllDay {
                    // All-day events take a single line; "all day" is added when it fits.
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 3) {
                            titleLine(color: color, tintTitle: tintTitle).fixedSize()
                            Spacer(minLength: 6)
                            Text("all day")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.white.opacity(0.45))
                                .fixedSize()
                        }
                        titleLine(color: color, tintTitle: tintTitle)
                    }
                } else {
                    titleLine(color: color, tintTitle: tintTitle)
                }
                if !event.isAllDay {
                    // Under way: range and time left, shortened when the column is narrow.
                    ViewThatFits(in: .horizontal) {
                        ForEach(timeLabels, id: \.self) { label in
                            HStack(spacing: 4) {
                                Text(label)
                                if event.meeting != nil {
                                    Image(systemName: "video.fill").font(.system(size: 8, weight: .semibold))
                                }
                            }
                            .fixedSize()
                        }
                    }
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                }
                if let place = CalendarCardStyle.place(for: event) {
                    HStack(spacing: 2) {
                        Image(systemName: "mappin").font(.system(size: 8, weight: .semibold))
                        Text(place)
                    }
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
                }
            }
            .lineLimit(1)
            .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 5)
        .padding(.leading, 5)
        .padding(.trailing, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(hovered ? 0.14 : 0.075)))
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { inside in
            guard let agenda = feature?.agenda else { return }
            if inside { agenda.hoveredEventID = event.id } else if agenda.hoveredEventID == event.id { agenda.hoveredEventID = nil }
        }
        .onTapGesture {
            let flags = NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags
            feature?.performPrimary(on: event, alternate: flags.contains(.option))
        }
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .global)
        } action: { frame in
            feature?.agenda.cardFrames[event.id] = frame
        }
        .onDisappear { feature?.agenda.cardFrames[event.id] = nil }
        .help(helpText)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private func titleLine(color: Color, tintTitle: Bool) -> some View {
        HStack(spacing: 3) {
            if let symbol = kindSymbol {
                Image(systemName: symbol).font(.system(size: 9, weight: .semibold)).foregroundStyle(color)
            }
            Text(event.title.isEmpty ? "Untitled" : event.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tintTitle ? color : .white)
        }
    }

    private var kindSymbol: String? {
        switch event.kind {
        case .birthday: return "gift.fill"
        case .holiday: return "star.fill"
        case .regular: return nil
        }
    }

    /// Time line candidates, longest first: "9:30–10:00 · 20 min left", "until 10:00 · 20 min left",
    /// "20 min left" for an event under way; the range otherwise.
    private var timeLabels: [String] {
        let calendar = Calendar.current
        let range: String
        if calendar.isDate(event.start, inSameDayAs: event.end) || event.end == event.start {
            range = (event.start..<event.end).formatted(.interval.hour().minute())
        } else {
            range = "\(event.start.formatted(.dateTime.hour().minute())) – \(event.end.formatted(.dateTime.hour().minute()))"
        }
        guard event.isOngoing(at: now) else { return [range] }
        let left = CountdownLabel.remaining(until: event.end, now: now)
        return ["\(range) · \(left)", "until \(event.end.formatted(.dateTime.hour().minute())) · \(left)", left]
    }

    private var helpText: String {
        guard let feature else { return "" }
        let show = "Show in \(feature.calendarApp.title)"
        if let link = event.meeting { return "Join on \(link.service.title) · ⌥-click: \(show)" }
        return show
    }
}

/// Empty day: the weather when "weather on free days" is on (and allowed), else a short note.
struct CalendarEmptyDay: View {
    let feature: CalendarFeature?
    let empty: AgendaEmptyState
    let isToday: Bool

    var body: some View {
        if isToday, let feature, feature.settings[Keys.calendarWeatherOnFreeDay], let report = feature.weather.displayReport {
            FreeDayWeather(report: report)
        } else {
            Text(isToday && empty == .allDone ? "All done for today" : "Nothing planned")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.4))
                .padding(.top, 2)
        }
    }
}

struct FreeDayWeather: View {
    let report: WeatherReport

    var body: some View {
        HStack(alignment: .center, spacing: 7) {
            Image(systemName: report.condition.symbol(isDay: report.isDay))
                .symbolRenderingMode(.multicolor)
                .font(.system(size: 22))
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 0) {
                Text(WeatherStore.unit.label(celsius: report.temperatureCelsius))
                    .font(.system(size: 18, weight: .medium))
                    .monospacedDigit()
                Text(report.condition.title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Compact month grid with today marked and optional dots on days with events.
struct MonthGridColumn: View {
    let grid: MonthGrid
    let busyDays: Set<Date>
    let showDots: Bool

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            Text(grid.month, format: .dateTime.month(.wide))
                .textCase(.uppercase)
                .font(CalendarCardStyle.headerFont)
                .foregroundStyle(.white.opacity(0.45))
            Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array(grid.weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                        Text(symbol)
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.35))
                            .frame(maxWidth: .infinity)
                            .frame(height: 12)
                    }
                }
                ForEach(Array(grid.weeks.enumerated()), id: \.offset) { _, week in
                    GridRow {
                        ForEach(week, id: \.date) { day in
                            MonthDayCell(day: day, busy: showDots && busyDays.contains(day.date))
                        }
                    }
                }
            }
        }
    }
}

struct MonthDayCell: View {
    let day: MonthGridDay
    let busy: Bool

    var body: some View {
        VStack(spacing: 1) {
            Text("\(day.day)")
                .font(.system(size: 9.5, weight: day.isToday ? .bold : .medium).monospacedDigit())
                .foregroundStyle(day.isToday ? Color.black : .white.opacity(day.inMonth ? 0.85 : 0.22))
                .frame(width: 15, height: 15)
                .background { if day.isToday { Circle().fill(Brand.copper) } }
            Circle()
                .fill(day.isToday ? Brand.copper : .white.opacity(day.inMonth ? 0.6 : 0.25))
                .frame(width: 3, height: 3)
                .opacity(busy ? 1 : 0)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 19)
    }
}
