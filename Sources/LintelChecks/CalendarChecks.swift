import CoreGraphics
import Foundation
import LintelCore

/// Checks for calendar models and filters, agenda and month grid, live-event planning,
/// meeting links and calendar apps, time to leave, fetch limiting, chime schedule, Open-Meteo
/// weather and caching, units, synthesised sounds and settings keys.
@MainActor
func runCalendarChecks() {
    checkColorsAndFilters()
    checkMeetingLinks()
    checkAgenda()
    checkMonthGrid()
    checkLivePlanner()
    checkTimeToLeave()
    checkTimingHelpers()
    checkWeather()
    checkTones()
    checkCalendarSettings()
}

// MARK: - Fixtures

private let utc = TimeZone(identifier: "UTC")!

private func gregorian(firstWeekday: Int = 1) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = utc
    calendar.locale = Locale(identifier: "en_US_POSIX")
    calendar.firstWeekday = firstWeekday
    return calendar
}

/// 2026-11-21 (a Saturday) at hh:mm UTC, plus `days`.
private func at(_ hour: Int, _ minute: Int = 0, _ second: Int = 0, days: Int = 0) -> Date {
    let base = gregorian().date(from: DateComponents(year: 2026, month: 11, day: 21, hour: hour, minute: minute, second: second))!
    return base.addingTimeInterval(Double(days) * 86_400)
}

private func event(_ id: String, _ start: Date, _ end: Date, allDay: Bool = false, calendar: String = "work",
                   declined: Bool = false, cancelled: Bool = false, location: String? = nil) -> CalendarEventRecord {
    CalendarEventRecord(id: id, calendarID: calendar, title: id, start: start, end: end, isAllDay: allDay, location: location,
                        declined: declined, cancelled: cancelled)
}

// MARK: - Colours and filters

@MainActor
private func checkColorsAndFilters() {
    let blue = EventColor(hex: "#3A8DD9")
    check(blue != nil && blue?.hex == "#3A8DD9", "hex colour round trip")
    check(EventColor(hex: "12345") == nil && EventColor(hex: "zzzzzz") == nil, "invalid hex rejected")
    let nearBlack = EventColor(hex: "#101010")!
    let lifted = nearBlack.readableOnBlack()
    check(lifted.luminance >= 0.1 && lifted != nearBlack, "very dark calendar colours are lifted to stay visible on black")
    check(blue?.readableOnBlack() == blue, "bright colours are kept as they are")
    let gray = CGColor(gray: 0.5, alpha: 1)
    let converted = EventColor(cgColor: gray)
    check(converted.map { abs($0.red - $0.green) < 0.01 && abs($0.green - $0.blue) < 0.01 && $0.red > 0.3 } ?? false,
          "grey CGColor converts to an sRGB grey")

    let filter = CalendarEventFilter(excluded: ["hidden"], modes: CalendarModeAssignments(["islandOnly": .island, "cardOnly": .card]))
    let base = event("x", at(10), at(11))
    var e = base
    e.calendarID = "hidden"
    check(!filter.includesInIsland(e) && !filter.includesInCard(e) && !filter.includesAnywhere(e), "excluded calendars are ignored everywhere")
    e.calendarID = "islandOnly"
    check(filter.includesInIsland(e) && !filter.includesInCard(e), "'island only' calendars stay out of the open card")
    e.calendarID = "cardOnly"
    check(!filter.includesInIsland(e) && filter.includesInCard(e), "'open card only' calendars don't drive the island")
    check(filter.includesInIsland(base) && filter.includesInCard(base), "other calendars default to both")
    check(!filter.includesInCard(event("d", at(10), at(11), declined: true)) && !filter.includesInIsland(event("c", at(10), at(11), cancelled: true)),
          "declined and cancelled events are hidden")
    let modes = CalendarModeAssignments.decode(["a": "island", "b": "bogus", "c": 3] as [String: Any])
    check(modes?.mode(for: "a") == .island && modes?.mode(for: "b") == .both && modes?.mode(for: "c") == .both,
          "mode map decoding skips unknown values")
    check(CalendarExclusions.decode(["a", 1, "b"] as [Any])?.ids == ["a", "b"], "exclusion list decoding")
}

// MARK: - Meeting links and calendar apps

@MainActor
private func checkMeetingLinks() {
    let zoom = MeetingLinkDetector.detect(url: nil, location: "https://us02web.zoom.us/j/81234567890?pwd=abcDEF123", notes: nil)
    check(zoom?.service == .zoom, "Zoom link detected")
    check(zoom?.appURL?.absoluteString == "zoommtg://zoom.us/join?action=join&confno=81234567890&pwd=abcDEF123",
          "Zoom opens in its app with meeting number and passcode (got \(zoom?.appURL?.absoluteString ?? "nil"))")
    let inNotes = MeetingLinkDetector.detect(url: nil, location: "Room 4", notes: "Agenda… Join: https://zoom.us/j/123456789.")
    check(inNotes?.webURL.absoluteString == "https://zoom.us/j/123456789", "trailing punctuation stripped from links in notes")
    let meet = MeetingLinkDetector.detect(in: ["meet.google.com/abc-defg-hij"])
    check(meet?.service == .googleMeet && meet?.webURL.absoluteString == "https://meet.google.com/abc-defg-hij" && meet?.appURL == nil,
          "Google Meet without a scheme gets https and opens on the web")
    let teams = MeetingLinkDetector.detect(in: ["https://teams.microsoft.com/l/meetup-join/19%3ameeting_ABC%40thread.v2/0?context=%7b%7d"])
    check(teams?.service == .teams && teams?.appURL?.scheme == "msteams", "Teams link opens in the Teams app")
    check(MeetingLinkDetector.detect(in: ["https://acme.webex.com/meet/jdoe"])?.service == .webex, "Webex link detected")
    let facetime = MeetingLinkDetector.detect(in: ["https://facetime.apple.com/join#v=1&p=AbCdEf&k=xyz"])
    check(facetime?.service == .facetime && facetime?.appURL == nil, "FaceTime link detected (the app takes the web link)")
    let priority = MeetingLinkDetector.detect(url: "https://zoom.us/j/111", location: nil, notes: "https://meet.google.com/aaa-bbbb-ccc")
    check(priority?.service == .zoom, "the event URL is searched before the notes")
    let first = MeetingLinkDetector.detect(in: ["Meet https://meet.google.com/aaa-bbbb-ccc or https://zoom.us/j/1"])
    check(first?.service == .googleMeet, "the earliest link in a text wins")
    check(MeetingLinkDetector.detect(in: ["Room 4, Main Street"]) == nil && MeetingLinkDetector.detect(in: ["https://zoom.us/pricing"]) == nil,
          "no false positives for places and non-meeting pages")
    check(MeetingService.zoom.appBundleIDs == ["us.zoom.xos"] && MeetingService.googleMeet.appBundleIDs.isEmpty, "native app bundle identifiers")

    let ical = CalendarAppChoice.calendar.eventURL(externalID: "ABC-123@google.com", start: at(10))
    check(ical?.absoluteString == "ical://ekevent/ABC-123%40google.com?method=show&options=more", "Calendar event link")
    check(CalendarAppChoice.calendar.eventURL(externalID: nil, start: at(10)) == nil, "no event link without an identifier")
    check(CalendarAppChoice.fantastical.dayURL(for: at(10), calendar: gregorian())?.absoluteString == "x-fantastical3://show/calendar/2026-11-21",
          "Fantastical day link")
    var chinese = Calendar(identifier: .chinese)
    chinese.timeZone = utc
    check(CalendarAppChoice.fantastical.dayURL(for: at(10), calendar: chinese)?.absoluteString == "x-fantastical3://show/calendar/2026-11-21",
          "app links use Gregorian dates under a lunar calendar")
    check(CalendarAppChoice.notionCalendar.eventURL(externalID: "x", start: at(10)) == nil && CalendarAppChoice.notionCalendar.bundleIDs == ["com.cron.electron"],
          "Notion Calendar is opened as an app")
}

// MARK: - Agenda

@MainActor
private func checkAgenda() {
    let cal = gregorian()
    let now = at(14)
    let events = [
        event("A", at(9), at(10)),
        event("B", at(13, 30), at(14, 30)),
        event("C", at(16), at(17)),
        event("D", at(0), at(23, 59, 59), allDay: true),
        event("E", at(15), at(15, 30), declined: true),
        event("F", at(15), at(15, 30), cancelled: true),
        event("G", at(10, days: 1), at(11, days: 1)),
        event("H", at(20), at(2, days: 1)),
    ]
    let today = AgendaBuilder.day(now, events: events, now: now, calendar: cal)
    check(today.events.map(\.id) == ["D", "B", "C", "H"], "today: remaining events, all-day first (got \(today.events.map(\.id)))")
    check(today.empty == .none && today.day == at(0), "today has events")
    let tomorrow = AgendaBuilder.day(at(0, days: 1), events: events, now: now, calendar: cal)
    check(tomorrow.events.map(\.id) == ["H", "G"], "tomorrow includes an event running past midnight (got \(tomorrow.events.map(\.id)))")
    check(AgendaBuilder.day(now, events: [events[0]], now: now, calendar: cal).empty == .allDone, "all of today's events over → done")
    check(AgendaBuilder.day(now, events: [], now: now, calendar: cal).empty == .nothingPlanned, "no events → nothing planned")
    check(AgendaBuilder.day(now, events: [events[4]], now: now, calendar: cal).empty == .nothingPlanned, "a declined event alone counts as nothing")
    let month = DateInterval(start: at(0, days: -20), end: at(0, days: 10))
    let busy = AgendaBuilder.busyDays(events: events, in: month, calendar: cal)
    check(busy == [at(0), at(0, days: 1)], "busy days include both days of an overnight event (got \(busy.count))")
    check(AgendaBuilder.nextListChange(events: events, now: now, calendar: cal) == at(14, 30), "list changes when the ongoing event ends")
    check(AgendaBuilder.nextListChange(events: [], now: now, calendar: cal) == at(0, days: 1), "otherwise at midnight")

    check(AgendaLayout.fittingCount(heights: [34, 34, 34], available: 130, spacing: 5, overflowLine: 13) == 3, "three cards fit exactly")
    check(AgendaLayout.fittingCount(heights: [34, 34, 34, 34], available: 130, spacing: 5, overflowLine: 13) == 3,
          "overflow line kept when not all fit")
    check(AgendaLayout.fittingCount(heights: [34, 34, 34], available: 92, spacing: 5, overflowLine: 13) == 2, "two cards plus overflow")
    check(AgendaLayout.fittingCount(heights: [34], available: 20, spacing: 5, overflowLine: 13) == 0, "nothing fits")
}

// MARK: - Month grid

@MainActor
private func checkMonthGrid() {
    let sunday = MonthGrid.make(containing: at(14), today: at(14), calendar: gregorian(firstWeekday: 1))
    check(sunday.weeks.count == 5 && sunday.weeks.allSatisfy { $0.count == 7 }, "November 2026, Sunday first: 5 weeks")
    check(sunday.weeks[0][0].day == 1 && sunday.weeks[0][0].inMonth, "Nov 1 2026 is a Sunday")
    check(sunday.weeks.joined().filter(\.isToday).map(\.day) == [21], "today marked once")
    check(sunday.weekdaySymbols.first == "S" && sunday.weekdaySymbols.count == 7, "weekday symbols start on Sunday")
    let monday = MonthGrid.make(containing: at(14), today: at(14), calendar: gregorian(firstWeekday: 2))
    check(monday.weeks.count == 6 && monday.weeks[0][0].day == 26 && !monday.weeks[0][0].inMonth, "Monday first: starts Oct 26, 6 weeks")
    check(monday.weekdaySymbols.first == "M", "weekday symbols start on Monday")
    check(monday.interval.start == at(0, days: -26) && monday.interval.duration == 42 * 86_400, "grid interval covers every cell")
    var chinese = Calendar(identifier: .chinese)
    chinese.timeZone = utc
    let lunar = MonthGrid.make(containing: at(14), today: at(14), calendar: chinese)
    let lunarDays = lunar.weeks.joined().filter(\.inMonth).count
    check((29...30).contains(lunarDays) && lunar.weeks.joined().filter(\.isToday).count == 1, "lunar month: 29–30 days, today once")
}

// MARK: - Live activity planning

@MainActor
private func checkLivePlanner() {
    let x = event("X", at(10), at(11))
    let options = LiveEventOptions(leadTime: 15 * 60)
    check(LiveEventPlanner.state(events: [x], now: at(9, 40), options: options) == nil, "no activity before the lead time")
    check(LiveEventPlanner.state(events: [x], now: at(9, 46), options: options) == LiveEventState(event: x, phase: .upcoming),
          "countdown within 15 min")
    check(LiveEventPlanner.state(events: [x], now: at(10), options: options)?.phase == .ongoing, "under way at the start")
    check(LiveEventPlanner.state(events: [x], now: at(11), options: options) == nil, "gone at the end")
    let hiding = LiveEventOptions(leadTime: 15 * 60, hideDuringEvents: true)
    check(LiveEventPlanner.state(events: [x], now: at(10, 30), options: hiding) == nil, "no activity during events when disabled")
    check(LiveEventPlanner.state(events: [x], now: at(9, 50), options: hiding)?.phase == .upcoming, "countdown still shown")
    check(LiveEventPlanner.nextChange(events: [x], now: at(9, 40), options: options) == at(9, 45), "next change: countdown begins")
    check(LiveEventPlanner.nextChange(events: [x], now: at(9, 50), options: options) == at(10), "next change: start")
    check(LiveEventPlanner.nextChange(events: [x], now: at(10, 30), options: options) == at(11), "next change: end")
    check(LiveEventPlanner.nextChange(events: [x], now: at(11), options: options) == nil, "nothing left to wait for")

    let block = event("L", at(9), at(13)), meeting = event("M", at(11), at(11, 30))
    check(LiveEventPlanner.state(events: [block, meeting], now: at(10, 50), options: options)?.event.id == "M",
          "a meeting inside a long block counts down")
    check(LiveEventPlanner.state(events: [block, meeting], now: at(11, 5), options: options)?.event.id == "M",
          "the most recently started event wins")
    check(LiveEventPlanner.state(events: [block, meeting], now: at(11, 30), options: options)?.event.id == "L", "back to the block")
    let first = event("N1", at(10), at(11)), second = event("N2", at(11), at(11, 30))
    check(LiveEventPlanner.state(events: [first, second], now: at(10, 50), options: options)?.event.id == "N1",
          "back-to-back: the current event stays until it ends")
    check(LiveEventPlanner.state(events: [event("D", at(0), at(23, 59), allDay: true)], now: at(10), options: options) == nil,
          "all-day events never drive the island")
    check(LiveEventPlanner.state(events: [x], now: at(10, 10), options: options, dismissed: ["X"]) == nil, "dismissed events are skipped")

    let began = LiveEventPlanner.crossings(events: [x], from: at(9, 44, 30), to: at(9, 45, 10), options: options)
    check(began == [.countdownBegan(x)], "countdown crossing detected")
    check(LiveEventPlanner.crossings(events: [x], from: at(9, 59, 50), to: at(10, 0, 5), options: options) == [.started(x)], "start crossing detected")
    check(LiveEventPlanner.crossings(events: [x], from: at(9), to: at(10, 5), options: options).isEmpty, "stale crossings after sleep dropped")
    check(LiveEventPlanner.crossings(events: [x], from: at(9, 59, 50), to: at(10, 0, 5), options: options, dismissed: ["X"]).isEmpty,
          "no crossings for dismissed events")

    check(CountdownLabel.compact(until: at(10), now: at(9, 48)) == "12m", "countdown 12m")
    check(CountdownLabel.compact(until: at(10), now: at(9, 48, 30)) == "12m", "countdown rounds up")
    check(CountdownLabel.compact(until: at(10), now: at(9, 59, 40)) == "1m", "last minute shows 1m")
    check(CountdownLabel.compact(until: at(10), now: at(9, 59).addingTimeInterval(-0.0001)) == "1m"
          && CountdownLabel.compact(until: at(10), now: at(9, 59).addingTimeInterval(-0.4)) == "1m",
          "timer jitter at a minute boundary doesn't show the previous minute")
    check(CountdownLabel.compact(until: at(10), now: at(8, 45)) == "1h15", "long countdown")
    check(CountdownLabel.remaining(until: at(11), now: at(10, 40)) == "20 min left", "time remaining")
    check(CountdownLabel.remaining(until: at(11, 5), now: at(10)) == "1 h 5 min left", "time remaining over an hour")
    check(CountdownLabel.peekCaption(start: at(10), now: at(9, 45)) == "Starts in 15 min", "before-start peek caption")
    check(CountdownLabel.peekCaption(start: at(10), now: at(9, 59, 50)) == "Starting now", "at-start peek caption")
}

// MARK: - Time to leave

@MainActor
private func checkTimeToLeave() {
    var geo = event("geo", at(16), at(17))
    geo.latitude = 52.5
    geo.longitude = 13.4
    check(TimeToLeavePlanner.hasPlace(geo), "coordinates are a place")
    check(TimeToLeavePlanner.hasPlace(event("addr", at(16), at(17), location: "Room 4, Main Street 1")), "an address is a place")
    check(!TimeToLeavePlanner.hasPlace(event("url", at(16), at(17), location: "https://zoom.us/j/1")), "a link is not a place")
    check(!TimeToLeavePlanner.hasPlace(event("bare", at(16), at(17), location: "zoom.us/j/123")), "a bare meeting link is not a place")
    check(!TimeToLeavePlanner.hasPlace(event("none", at(16), at(17))), "no location, no travel")
    let events = [
        event("late", at(19), at(20), location: "Far away"),
        event("soon", at(15), at(16), location: "Office"),
        event("allday", at(0), at(23, 59), allDay: true, location: "Office"),
        event("past", at(13), at(13, 30), location: "Office"),
        event("done", at(15, 30), at(16), location: "Office"),
        event("noplace", at(15), at(16)),
    ]
    let candidates = TimeToLeavePlanner.candidates(events: events, now: at(14), alerted: ["done"])
    check(candidates.map(\.id) == ["soon"], "candidates: timed, upcoming within 4 h, with a place, not yet alerted (got \(candidates.map(\.id)))")
    check(TimeToLeavePlanner.leaveTime(start: at(15), travel: 1500, buffer: 600) == at(14, 25), "leave = start − travel − buffer")
    check(!TimeToLeavePlanner.isDue(now: at(14, 24, 59), start: at(15), travel: 1500, buffer: 600), "not due before the leave time")
    check(TimeToLeavePlanner.isDue(now: at(14, 25), start: at(15), travel: 1500, buffer: 600), "due at the leave time")
    check(TimeToLeavePlanner.isDue(now: at(14, 50), start: at(15), travel: 3600, buffer: 600), "already late: due at once")
    check(!TimeToLeavePlanner.isDue(now: at(15), start: at(15), travel: 600, buffer: 600), "not after the start")
    check(TimeToLeavePlanner.nextCheck(now: at(14), start: at(15), travel: 1500, buffer: 600) == at(14, 10), "estimate refreshed every 10 min")
    check(TimeToLeavePlanner.nextCheck(now: at(14, 20), start: at(15), travel: 1500, buffer: 600) == at(14, 25), "or checked at the leave time")
    check(TimeToLeavePlanner.travelLabel(1500) == "25 min" && TimeToLeavePlanner.travelLabel(4200) == "1 h 10 min"
          && TimeToLeavePlanner.travelLabel(3600) == "1 h", "travel time labels")
}

// MARK: - Fetch limiting and chime

@MainActor
private func checkTimingHelpers() {
    var limiter = CalendarFetchLimiter()
    check(limiter.runTime(requestedAt: 10) == 10.25, "first fetch after the debounce")
    limiter.didFetch(at: 10.25)
    check(limiter.runTime(requestedAt: 10.5) == 11.5, "at most one fetch every 1.25 s")
    check(limiter.runTime(requestedAt: 20) == 20.25, "later requests only wait for the debounce")
    let cal = gregorian()
    check(HourlyChimeSchedule.next(after: at(14, 20, 10), calendar: cal) == at(15), "chime at the next top of the hour")
    check(HourlyChimeSchedule.next(after: at(14, 59, 59), calendar: cal) == at(15), "one second before the hour")
    check(HourlyChimeSchedule.next(after: at(15), calendar: cal) == at(16), "exactly on the hour → the next one")
}

// MARK: - Weather

@MainActor
private func checkWeather() {
    check(WeatherCondition(wmoCode: 0) == .clear && WeatherCondition(wmoCode: 2) == .partlyCloudy && WeatherCondition(wmoCode: 61) == .rain
          && WeatherCondition(wmoCode: 65) == .heavyRain && WeatherCondition(wmoCode: 95) == .thunderstorm
          && WeatherCondition(wmoCode: 99) == .hail && WeatherCondition(wmoCode: 1000) == .unknown, "WMO code mapping")
    check(WeatherCondition.clear.symbol(isDay: true) == "sun.max.fill" && WeatherCondition.clear.symbol(isDay: false) == "moon.stars.fill",
          "day and night symbols")
    check(WeatherCondition.rain.isWet && !WeatherCondition.cloudy.isWet, "wet conditions")

    check(OpenMeteo.rounded(52.5163) == 52.52 && OpenMeteo.rounded(13.3777) == 13.38 && OpenMeteo.rounded(-33.8688) == -33.87,
          "coordinates rounded to 0.01°")
    let url = OpenMeteo.requestURL(latitude: 52.516_312, longitude: 13.377_704)?.absoluteString ?? ""
    check(url.hasPrefix("https://api.open-meteo.com/v1/forecast?") && url.contains("latitude=52.52&longitude=13.38")
          && url.contains("timeformat=unixtime") && !url.contains("52.516"), "request sends only rounded coordinates (got \(url))")

    let sample = """
    {"latitude":52.52,"longitude":13.42,"current":{"time":1795365900,"temperature_2m":3.9,"weather_code":61,"is_day":0,"precipitation":0.0},
     "daily":{"time":[1795302000,1795388400],"sunrise":[1795329598,1795416098],"sunset":[1795359864,1795446198],
              "precipitation_probability_max":[88,23]}}
    """
    let fetchedAt = Date(timeIntervalSince1970: 1_795_365_900)
    let report = try? OpenMeteo.parse(Data(sample.utf8), fetchedAt: fetchedAt, latitude: 52.5163, longitude: 13.3777)
    check(report?.condition == .rain && report?.temperatureCelsius == 3.9 && report?.isDay == false, "current conditions parsed")
    check(report?.sunrise == Date(timeIntervalSince1970: 1_795_329_598) && report?.sunset == Date(timeIntervalSince1970: 1_795_359_864),
          "today's sunrise and sunset")
    check(report?.nextSunrise == Date(timeIntervalSince1970: 1_795_416_098) && report?.nextSunset == Date(timeIntervalSince1970: 1_795_446_198),
          "next sunrise and sunset after the fetch")
    check(report?.precipitationChance == 0.88 && report?.isRaining == true, "precipitation chance and rain flag")
    check(report?.latitude == 52.52 && report?.longitude == 13.38, "report keeps the rounded coordinates")
    do {
        _ = try OpenMeteo.parse(Data(#"{"error":true,"reason":"Latitude must be in range"}"#.utf8), fetchedAt: fetchedAt, latitude: 0, longitude: 0)
        check(false, "service errors are thrown")
    } catch {
        check(error as? OpenMeteo.ParseError == .service("Latitude must be in range"), "service error reason kept")
    }
    check((try? OpenMeteo.parse(Data("nope".utf8), fetchedAt: fetchedAt, latitude: 0, longitude: 0)) == nil, "garbage rejected")
    if let report {
        let json = report.encodedJSON()
        check(WeatherReport.decode(json: json) == report, "weather cache JSON round trip")
        let now = fetchedAt
        check(!WeatherCachePolicy.needsRefresh(cached: report, now: now.addingTimeInterval(600), latitude: 52.52, longitude: 13.38),
              "fresh report for the same place is kept")
        check(WeatherCachePolicy.needsRefresh(cached: report, now: now.addingTimeInterval(31 * 60), latitude: 52.52, longitude: 13.38),
              "refetched after 30 min")
        check(WeatherCachePolicy.needsRefresh(cached: report, now: now.addingTimeInterval(60), latitude: 52.75, longitude: 13.38),
              "refetched after moving")
        check(!WeatherCachePolicy.needsRefresh(cached: report, now: now.addingTimeInterval(60), latitude: 52.56, longitude: 13.38),
              "small moves keep the cache")
        check(WeatherCachePolicy.needsRefresh(cached: report, now: now.addingTimeInterval(-600), latitude: 52.52, longitude: 13.38),
              "a report from the future (clock change) is refetched")
        check(WeatherCachePolicy.isDisplayable(report, now: now.addingTimeInterval(2 * 3600))
              && !WeatherCachePolicy.isDisplayable(report, now: now.addingTimeInterval(4 * 3600)), "stale weather is hidden")
    }
    check(WeatherCachePolicy.needsRefresh(cached: nil, now: fetchedAt, latitude: 0, longitude: 0), "no cache → fetch")

    check(TemperatureUnitChoice.resolve(preference: "Fahrenheit", regionCode: "DE") == .fahrenheit, "explicit °F preference")
    check(TemperatureUnitChoice.resolve(preference: "Celsius", regionCode: "US") == .celsius, "explicit °C preference")
    check(TemperatureUnitChoice.resolve(preference: nil, regionCode: "US") == .fahrenheit, "US region → °F")
    check(TemperatureUnitChoice.resolve(preference: nil, regionCode: "GB") == .celsius, "UK region → °C")
    check(TemperatureUnitChoice.celsius.label(celsius: 3.9) == "4°" && TemperatureUnitChoice.fahrenheit.label(celsius: 3.9) == "39°",
          "temperature labels")
    check(TemperatureUnitChoice.celsius.label(celsius: -0.3) == "0°", "no negative zero")
}

// MARK: - Sounds

@MainActor
private func checkTones() {
    for cue in ToneCue.allCases {
        let samples = ToneSynth.render(cue.notes)
        let peak = samples.map { abs($0) }.max() ?? 0
        let expected = (cue.notes.map { $0.onset + $0.decay * 1.1 }.max() ?? 0) * Double(ToneSynth.sampleRate)
        check(abs(Double(samples.count) - expected) <= 1, "\(cue.rawValue): length follows the notes")
        check(abs(Double(peak) - 0.45) < 0.01, "\(cue.rawValue): normalised to the target peak")
        check(abs(samples.last ?? 1) < 0.01, "\(cue.rawValue): fades to silence")
        let wav = ToneSynth.wav(samples)
        check(wav.count == 44 + samples.count * 2 && wav.prefix(4) == Data("RIFF".utf8) && wav[8..<12] == Data("WAVE".utf8),
              "\(cue.rawValue): 16-bit PCM WAV")
    }
    check(Set(ToneCue.allCases.map { ToneSynth.render($0.notes).count }).count == ToneCue.allCases.count, "each cue sounds different")
}

// MARK: - Settings keys

@MainActor
private func checkCalendarSettings() {
    let suite = "lintel.checks.m6.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    let store = SettingsStore(defaults: defaults, center: NotificationCenter())
    check(store[Keys.calendarEnabled] == false, "calendar off by default (enableCalendar)")
    check(store[Keys.calendarLeadMinutes] == 15, "time before event 15 min")
    check(store[Keys.calendarTintIcon] == true && store[Keys.calendarTintTitles] == false, "coloured indicator on, coloured titles off")
    check(store[Keys.calendarHideDuringEvents] == false && store[Keys.calendarMonthView] == false && store[Keys.calendarEventDots] == false
          && store[Keys.calendarWeatherOnFreeDay] == false, "card options off by default")
    check(store[Keys.calendarStartSound] == true && store[Keys.calendarHourlyChime] == false, "event sound on, chime off")
    check(store[Keys.timeToLeaveEnabled] == false && store[Keys.timeToLeaveBufferMinutes] == 10 && store[Keys.timeToLeaveSound] == true
          && store[Keys.timeToLeaveMode] == .driving && store[Keys.duration(.timeToLeave)] == 8, "time-to-leave defaults")
    check(store[Keys.calendarPeek] && !store[Keys.calendarPeekBefore] && store[Keys.calendarPeekAtStart] && store[Keys.calendarPeekDuration] == 4,
          "calendar Quick Peek defaults")
    check(store[Keys.calendarExclusions].ids.isEmpty && store[Keys.calendarModes].modes.isEmpty, "all calendars included, mode both")
    check(store[Keys.calendarApp] == .calendar && store[Keys.locationPendingTarget] == nil && store[Keys.weatherCache] == nil,
          "calendar app, pending location target and weather cache defaults")
    store[Keys.calendarExclusions] = CalendarExclusions(["b", "a"])
    check(defaults.array(forKey: "calendar.excluded") as? [String] == ["a", "b"] && store[Keys.calendarExclusions].ids == ["a", "b"],
          "exclusions stored as a sorted list")
    store[Keys.calendarModes] = CalendarModeAssignments(["a": .card])
    check((defaults.dictionary(forKey: "calendar.modes") as? [String: String]) == ["a": "card"] && store[Keys.calendarModes].mode(for: "a") == .card,
          "display modes stored as a map")
    store[Keys.locationPendingTarget] = .timeToLeave
    check(defaults.string(forKey: "location.pendingTarget") == "timeToLeave", "pending location target stored")
    store[Keys.locationPendingTarget] = nil
    check(defaults.object(forKey: "location.pendingTarget") == nil, "pending target cleared")
    check(Keys.calendarKeyPrefixes.allSatisfy { prefix in
        [Keys.calendarEnabled.name, Keys.weatherCache.name, Keys.locationPendingTarget.name, Keys.timeToLeaveMode.name].contains { $0.hasPrefix(prefix) }
    }, "calendar key prefixes cover the keys")
    defaults.removePersistentDomain(forName: suite)
}
