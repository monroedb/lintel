import Foundation

/// Why a day column has nothing to list.
public enum AgendaEmptyState: String, Sendable, Equatable {
    /// There are events to show.
    case none
    /// Nothing at all on that day.
    case nothingPlanned
    /// Today had events, but all of them are over.
    case allDone
}

/// One day of the open calendar card: the events still relevant, all-day ones first.
public struct AgendaDay: Equatable, Sendable {
    public var day: Date
    public var events: [CalendarEventRecord]
    public var empty: AgendaEmptyState

    public init(day: Date, events: [CalendarEventRecord], empty: AgendaEmptyState) {
        self.day = day
        self.events = events
        self.empty = empty
    }
}

/// Builds the open card's day lists. Date maths always uses the given
/// `Calendar`, so non-Gregorian (e.g. lunar) calendars work the same way.
public enum AgendaBuilder {
    /// Events of the day containing `date` that haven't ended at `now`.
    public static func day(_ date: Date, events: [CalendarEventRecord], now: Date, calendar: Calendar) -> AgendaDay {
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        let onDay = events.filter { $0.isVisible && $0.overlaps(from: start, to: end) }
        let remaining = sorted(onDay.filter { $0.isAllDay || $0.end > now })
        let empty: AgendaEmptyState = onDay.isEmpty ? .nothingPlanned : (remaining.isEmpty ? .allDone : .none)
        return AgendaDay(day: start, events: remaining, empty: empty)
    }

    /// All-day events first (by title), then by start, end and title.
    public static func sorted(_ events: [CalendarEventRecord]) -> [CalendarEventRecord] {
        events.sorted { a, b in
            if a.isAllDay != b.isAllDay { return a.isAllDay }
            if a.isAllDay { return a.title.localizedStandardCompare(b.title) == .orderedAscending }
            if a.start != b.start { return a.start < b.start }
            if a.end != b.end { return a.end < b.end }
            return a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
    }

    /// Start of each day in `interval` on which at least one visible event takes place
    /// (the month view's event indicators).
    public static func busyDays(events: [CalendarEventRecord], in interval: DateInterval, calendar: Calendar) -> Set<Date> {
        var days = Set<Date>()
        for event in events where event.isVisible && event.overlaps(from: interval.start, to: interval.end) {
            var day = calendar.startOfDay(for: max(event.start, interval.start))
            let last = max(event.start, min(event.end, interval.end).addingTimeInterval(-1))
            while day <= last {
                days.insert(day)
                guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                day = next
            }
        }
        return days
    }

    /// When the open card's lists next change on their own: the next end of a listed timed event,
    /// or the start of the next day.
    public static func nextListChange(events: [CalendarEventRecord], now: Date, calendar: Calendar) -> Date {
        let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now.addingTimeInterval(86_400)
        let ends = events.filter { $0.isVisible && !$0.isAllDay && $0.end > now }.map(\.end)
        return ([midnight] + ends).min() ?? midnight
    }
}

/// One cell of the compact month grid.
public struct MonthGridDay: Equatable, Hashable, Sendable {
    public var date: Date
    public var day: Int
    public var inMonth: Bool
    public var isToday: Bool
}

/// Compact month grid for the open card ("Always show month view").
public struct MonthGrid: Equatable, Sendable {
    /// First day of the month shown.
    public var month: Date
    /// Very short weekday symbols, starting with the calendar's first weekday.
    public var weekdaySymbols: [String]
    public var weeks: [[MonthGridDay]]
    /// First to last cell (for fetching the events behind the indicators).
    public var interval: DateInterval

    public static func make(containing date: Date, today: Date, calendar: Calendar) -> MonthGrid {
        let monthInterval = calendar.dateInterval(of: .month, for: date)
            ?? DateInterval(start: calendar.startOfDay(for: date), duration: 86_400 * 30)
        let first = calendar.startOfDay(for: monthInterval.start)
        let weekday = calendar.component(.weekday, from: first)
        let leading = (weekday - calendar.firstWeekday + 7) % 7
        let dayCount = calendar.range(of: .day, in: .month, for: first)?.count ?? 30
        let cellCount = Int((Double(leading + dayCount) / 7).rounded(.up)) * 7
        let gridStart = calendar.date(byAdding: .day, value: -leading, to: first) ?? first
        var weeks: [[MonthGridDay]] = []
        var row: [MonthGridDay] = []
        var last = gridStart
        for index in 0..<cellCount {
            let cell = calendar.date(byAdding: .day, value: index, to: gridStart) ?? gridStart
            last = cell
            row.append(MonthGridDay(date: cell, day: calendar.component(.day, from: cell),
                                    inMonth: calendar.isDate(cell, equalTo: first, toGranularity: .month),
                                    isToday: calendar.isDate(cell, inSameDayAs: today)))
            if row.count == 7 {
                weeks.append(row)
                row = []
            }
        }
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let rotation = (calendar.firstWeekday - 1) % max(1, symbols.count)
        let ordered = Array(symbols[rotation...] + symbols[..<rotation])
        let end = calendar.date(byAdding: .day, value: 1, to: last) ?? last
        return MonthGrid(month: first, weekdaySymbols: ordered, weeks: weeks, interval: DateInterval(start: gridStart, end: end))
    }
}

/// How many event cards fit in a column (the rest become an overflow line).
public enum AgendaLayout {
    public static func fittingCount(heights: [Double], available: Double, spacing: Double, overflowLine: Double) -> Int {
        func total(_ count: Int) -> Double {
            count == 0 ? 0 : heights.prefix(count).reduce(0, +) + spacing * Double(count - 1)
        }
        if total(heights.count) <= available { return heights.count }
        var count = 0
        while count < heights.count, total(count + 1) + spacing + overflowLine <= available { count += 1 }
        return count
    }
}
