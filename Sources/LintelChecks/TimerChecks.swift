import CoreGraphics
import Foundation
import LintelCore

// Checks for the timer: input grammar, links, the state machine and its
// alert, persistence and restore, formatting, settings and the activity-engine contract.

private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

private func at(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }

private func url(_ text: String) -> Result<TimerURLCommand, TimerURLCommand.Failure> {
    guard let url = URL(string: text) else { return .failure(.notLintel) }
    return TimerURLCommand.parse(url)
}

private func started(_ seconds: Double, repeats: Bool = true) -> TimerMachine {
    var machine = TimerMachine()
    machine.repeats = repeats
    machine.start(seconds: seconds, now: t0, id: "T")
    return machine
}

func runTimerChecks() {
    // MARK: Custom-duration grammar
    let durations: [(String, Double?)] = [
        ("25", 1500), ("2.5", 150), ("2,5", 150), (".5", 30), ("90s", 90), ("90 sec", 90), ("90 seconds", 90),
        ("10m", 600), ("10 min", 600), ("10 minutes", 600), ("1h", 3600), ("1 hr", 3600), ("2 hours", 7200),
        ("1h 30m", 5400), ("1h30", 5400), ("1h30m", 5400), ("2m30s", 150), ("2m 30", 150), ("1.5h", 5400),
        ("1:30", 90), ("1:30:00", 5400), ("90:00", 5400), (" 1 : 05 ", 65), ("24:00:00", 86400), ("1440", 86400),
        ("0", nil), ("", nil), ("abc", nil), ("1:5", nil), ("1:60", nil), ("1:30:60", nil), ("24:00:01", nil),
        ("1441", nil), ("-5", nil), ("+5", nil), ("1e3", nil), ("5.", nil), ("1,000.5", nil), ("30m 1h", nil),
        ("1h 2h", nil), ("10x", nil), ("1h 30 20", nil), ("0.001", nil), ("0s", nil),
    ]
    for (text, expected) in durations {
        check(TimerDuration.parse(text) == expected, "duration \"\(text)\" → \(expected.map { "\($0)" } ?? "nil") (got \(TimerDuration.parse(text).map { "\($0)" } ?? "nil"))")
    }

    // MARK: Links
    check(url("lintel://timer?minutes=25") == .success(.start(seconds: 1500)), "link: minutes=25 starts 25 min")
    check(url("lintel://timer/start?minutes=1") == .success(.start(seconds: 60)), "link: /start alias")
    check(url("LINTEL://Timer?minutes=2.5") == .success(.start(seconds: 150)), "link: scheme and host are case-insensitive; decimals")
    check(url("lintel://timer?minutes=2,5") == .success(.start(seconds: 150)), "link: comma as the decimal separator")
    check(url("lintel://timer/?minutes=0.5") == .success(.start(seconds: 30)), "link: trailing slash; 0.5 = 30 s")
    check(url("lintel://timer?minutes=0.01") == .success(.start(seconds: 1)), "link: 0.6 s rounds to 1 s")
    check(url("lintel://timer?minutes=1440") == .success(.start(seconds: 86400)), "link: 24 h is the maximum")
    check(url("lintel://timer?minutes=%32%35") == .success(.start(seconds: 1500)), "link: percent-encoded value")
    check(url("lintel://timer?label=x&minutes=3&minutes=9") == .success(.start(seconds: 180)), "link: first minutes counts, others ignored")
    check(url("lintel://timer?minutes=1441") == .failure(.outOfRange("1441")), "link: above 24 h rejected")
    check(url("lintel://timer?minutes=0") == .failure(.outOfRange("0")), "link: zero rejected")
    check(url("lintel://timer?minutes=0.001") == .failure(.outOfRange("0.001")), "link: under 1 s rejected")
    check(url("lintel://timer?minutes=-5") == .failure(.invalidMinutes("-5")), "link: negative rejected")
    check(url("lintel://timer?minutes=1e3") == .failure(.invalidMinutes("1e3")), "link: exponent rejected")
    check(url("lintel://timer?minutes=abc") == .failure(.invalidMinutes("abc")), "link: text rejected")
    check(url("lintel://timer?minutes=") == .failure(.missingMinutes), "link: empty minutes rejected")
    check(url("lintel://timer") == .failure(.missingMinutes), "link: no minutes rejected")
    check(url("lintel://timer/pause") == .success(.pause) && url("lintel://timer/resume") == .success(.resume)
          && url("lintel://timer/restart") == .success(.restart) && url("lintel://timer/cancel") == .success(.cancel),
          "link: pause, resume, restart, cancel")
    check(url("lintel://timer/add") == .success(.add(seconds: 60)) && url("lintel://timer/add?minutes=5") == .success(.add(seconds: 300)),
          "link: add defaults to 1 min")
    check(url("lintel://timer/add?minutes=x") == .failure(.invalidMinutes("x")), "link: add with a bad value rejected")
    check(url("lintel://timer/explode") == .failure(.unknownRoute("explode")), "link: unknown route")
    check(url("lintel://settings") == .failure(.notLintel) && url("https://timer?minutes=5") == .failure(.notLintel),
          "link: other hosts and schemes aren't timer links")

    // MARK: State machine
    do {
        var m = TimerMachine()
        check(!m.start(seconds: 0, now: t0) && !m.start(seconds: 86401, now: t0) && m.state == nil, "start: outside 1 s … 24 h refused")
        check(m.start(seconds: 1499.6, now: t0, id: "A") && m.state?.duration == 1500 && m.state?.preset == 1500, "start: whole seconds")
        check(m.state?.phase == .running(end: at(1500)) && m.state?.identity == "timer-A-0", "start: running to now + duration")
        check(m.state?.shownSeconds(at: at(0.3)) == 1500, "shown: rounds up (25:00 just after the start)")
        check(m.state?.shownSeconds(at: at(1499.0)) == 1 && m.state?.shownSeconds(at: at(1499.9)) == 1, "shown: 0:01 until the end")
        check(m.state?.shownSeconds(at: at(1490)) == 10 && m.state?.shownSeconds(at: at(1489.96)) == 10,
              "shown: tolerance keeps a hair above a second on that second")
        check(m.state?.isUrgent(at: at(1489.9)) == false && m.state?.isUrgent(at: at(1490)) == true, "urgent from 0:10")
        check(abs((m.state?.remainingFraction(at: at(750)) ?? 0) - 0.5) < 1e-9, "progress: half way")
        check(m.nextDeadline() == at(1500), "deadline: the end")

        check(m.pause(now: at(100)) && m.state?.phase == .paused(remaining: 1400) && m.state?.revision == 1, "pause keeps the time left")
        check(m.nextDeadline() == nil, "paused: nothing scheduled")
        check(!m.pause(now: at(110)), "pause twice: no change")
        check(m.add(now: at(200)) && m.state?.phase == .paused(remaining: 1460) && m.state?.duration == 1560, "+1 min while paused")
        check(m.resume(now: at(300)) && m.state?.phase == .running(end: at(1760)) && m.state?.revision == 3, "resume: end = now + left")
        check(m.add(now: at(400)) && m.state?.phase == .running(end: at(1820)) && m.state?.duration == 1620, "+1 min while running")
        check(m.restart(now: at(500)) && m.state?.phase == .running(end: at(2000)) && m.state?.duration == 1500, "restart: the preset again")
        check(m.state?.id == "A" && m.state?.identity == "timer-A-5", "every change bumps the identity")
        check(m.togglePause(now: at(600)) && m.state?.isPaused == true && m.togglePause(now: at(700)) && m.state?.isRunning == true,
              "toggle pause")
        check(m.cancel() && m.state == nil && !m.cancel(), "cancel: gone")
    }
    do {
        var m = started(86_300)
        check(m.add(now: t0) && m.state?.phase == .running(end: at(86_360)), "+1 min below the cap")
        check(m.add(now: t0) && m.state?.phase == .running(end: at(86_400)) && m.state?.duration == 86_400 && !m.add(now: t0),
              "+1 min clamps at 24 h left")
        var p = started(60)
        check(!p.pause(now: at(59.97)) && p.state?.isRunning == true, "pause in the last 0.05 s lets it finish")
    }

    // MARK: Alert
    do {
        var m = started(60)
        check(m.advance(now: at(59.9)).isEmpty, "nothing before the end")
        let first = m.advance(now: at(60.004))
        var lateness = -1.0
        if case .alertStarted(let late)? = first.first { lateness = late }
        check(first.count == 2 && first.last == .ring(index: 0) && abs(lateness - 0.004) < 1e-6,
              "end: the alert starts and rings at once (got \(first))")
        check(m.isRinging && m.state?.phase == .finished(at: at(60), alerted: true, silenced: false) && m.state?.revision == 1,
              "end: ringing; the end bumps the identity")
        check(m.nextDeadline() == at(63.004), "next ring 3 s later")
        check(m.advance(now: at(61)).isEmpty, "no ring between")
        check(m.advance(now: at(63.004)) == [.ring(index: 1)], "second ring")
        check(m.advance(now: at(80)) == [.ring(index: 6)], "after a gap one ring is played, not the missed ones")
        check(m.alert?.ringCount(policy: m.policy) == 40, "40 rings in the 2 min cap")
        check(m.advance(now: at(179.0)) == [.ring(index: 39)], "last ring before the cap")
        check(m.nextDeadline() == at(180.004), "then the cap")
        check(m.advance(now: at(180.004)) == [.silenced] && !m.isRinging && m.state?.isDone == true, "cap: quiet, done")
        check(m.nextDeadline() == at(60 + 12 * 3600), "done: forgotten after 12 h")
        check(m.advance(now: at(60 + 12 * 3600)) == [.forgotten] && m.state == nil, "forgotten")
    }
    do {
        var m = started(60, repeats: false)
        check(m.advance(now: at(60)) == [.alertStarted(late: 0), .ring(index: 0)], "single ring")
        check(m.nextDeadline() == at(70) && m.advance(now: at(65)).isEmpty, "single ring: no repeat; stays 10 s")
        check(m.advance(now: at(70)) == [.cleared] && m.state == nil, "single ring: gone after 10 s")
    }
    do {
        var m = started(60)
        _ = m.advance(now: at(60))
        check(m.add(now: at(62)) && m.state?.phase == .running(end: at(122)) && m.state?.duration == 60 && m.state?.preset == 60 && !m.isRinging,
              "+1 min on the alert: runs 60 s, stops ringing")
        _ = m.advance(now: at(122))
        check(m.restart(now: at(125)) && m.state?.phase == .running(end: at(185)) && !m.isRinging, "restart on the alert")
        _ = m.advance(now: at(185))
        check(m.cancel() && m.state == nil && !m.isRinging, "stop on the alert")
    }
    do {
        var m = started(60)
        check(m.advance(now: at(60 + 240)) == [.alertStarted(late: 240), .ring(index: 0)], "4 min late (sleep): still rings")
        var n = started(60)
        check(n.advance(now: at(60 + 301)) == [.missed(late: 301)] && n.state?.isDone == true && !n.isRinging,
              "over 5 min late: done without a sound")
    }

    // MARK: Persistence and restore
    do {
        let running = started(1500)
        guard let snapshot = running.snapshot, let json = snapshot.json else { check(false, "snapshot encodes"); return }
        check(json.contains("\"phase\":\"running\"") && json.contains("\"version\":1"), "snapshot JSON (got \(json))")
        check(TimerSnapshot.decode(json) == snapshot && snapshot.state == running.state, "snapshot round trip")
        var later = TimerMachine()
        check(later.restore(TimerSnapshot.decode(json), now: at(600)).isEmpty && later.state?.phase == .running(end: at(1500)),
              "restore: keeps counting to the same end")
        var late = TimerMachine()
        check(late.restore(snapshot, now: at(1500 + 120)) == [.alertStarted(late: 120), .ring(index: 0)], "restore: ended 2 min ago → rings")
        var missed = TimerMachine()
        check(missed.restore(snapshot, now: at(1500 + 600)) == [.missed(late: 600)] && missed.state?.isDone == true,
              "restore: ended 10 min ago → done, silently")
        var old = TimerMachine()
        check(old.restore(snapshot, now: at(1500 + 13 * 3600)) == [.missed(late: 13 * 3600), .forgotten] && old.state == nil,
              "restore: ended 13 h ago → forgotten")

        var paused = started(1500)
        paused.pause(now: at(100))
        var restoredPaused = TimerMachine()
        check(restoredPaused.restore(paused.snapshot, now: at(99_999)).isEmpty && restoredPaused.state?.phase == .paused(remaining: 1400),
              "restore: paused with the same time left")

        var ringing = started(60)
        _ = ringing.advance(now: at(60))
        var quitRinging = TimerMachine()
        check(quitRinging.restore(ringing.snapshot, now: at(90)) == [.alertStarted(late: 30), .ring(index: 0)], "restore: quit while ringing → rings again")
        var quitSingle = TimerMachine()
        quitSingle.repeats = false
        check(quitSingle.restore(ringing.snapshot, now: at(65)) == [.cleared] && quitSingle.state == nil,
              "restore: a single-ring alert that played isn't repeated")
        _ = ringing.advance(now: at(180))
        var quiet = TimerMachine()
        check(ringing.state?.isDone == true && quiet.restore(ringing.snapshot, now: at(200)).isEmpty && quiet.state?.isDone == true,
              "restore: done stays done")

        var empty = TimerMachine(state: running.state)
        check(empty.restore(nil, now: t0).isEmpty && empty.state == nil, "restore: nothing stored")
        check(TimerSnapshot.decode("{garbage") == nil, "restore: unreadable JSON dropped")
        var future = snapshot
        future.version = 2
        check(future.state == nil, "restore: unknown version dropped")
        var broken = snapshot
        broken.phase = "running"
        broken.end = nil
        check(broken.state == nil, "restore: inconsistent snapshot dropped")
    }

    // MARK: Formatting
    check(TimerFormat.clock(299) == "4:59" && TimerFormat.clock(1499) == "24:59" && TimerFormat.clock(9) == "0:09"
          && TimerFormat.clock(3600) == "1:00:00" && TimerFormat.clock(86399) == "23:59:59", "clock M:SS / H:MM:SS")
    check(TimerFormat.duration(1500) == "25 min" && TimerFormat.duration(90) == "1 min 30 s" && TimerFormat.duration(5400) == "1 h 30 min"
          && TimerFormat.duration(45) == "45 s" && TimerFormat.duration(3600) == "1 h", "duration in words")
    check(TimerFormat.title(preset: 1500) == "25 min timer" && TimerFormat.presetMenuTitle(minutes: 1) == "1 Minute"
          && TimerFormat.presetMenuTitle(minutes: 25) == "25 Minutes", "titles")
    check(TimerFormat.lateNote(10) == nil && TimerFormat.lateNote(45) == "Ended 1 min ago" && TimerFormat.lateNote(200) == "Ended 3 min ago",
          "late note")
    check(TimerFormat.tickAnchor(end: at(10), now: at(4.7)) == at(4) && TimerFormat.tickAnchor(end: at(10), now: at(5)) == at(5),
          "ticks align with the whole seconds before the end")
    check(TimerFormat.entryText(1200) == "20" && TimerFormat.entryText(90) == "1:30" && TimerFormat.entryText(5400) == "1h 30m"
          && TimerFormat.entryText(3600) == "1h" && TimerFormat.entryText(3661) == "1:01:01", "custom prefill text")
    for seconds in [1200.0, 90, 5400, 3600, 3661, 45] {
        check(TimerDuration.parse(TimerFormat.entryText(seconds)) == seconds, "prefill \(seconds) parses back")
    }
    check(TimerFormat.entryHint(for: 5400) == "Starts a 1 h 30 min timer" && TimerFormat.entryHint(for: nil).hasPrefix("Try"), "entry hint")
    do {
        var m = started(1500)
        let time: (Date) -> String = { _ in "14:35" }
        check(TimerFormat.menuHeader(m.state!, ringing: false, now: at(1), time: time) == "Timer — 24:59 left", "menu header running")
        m.pause(now: at(1248))
        check(TimerFormat.menuHeader(m.state!, ringing: false, now: at(1), time: time) == "Timer — paused, 4:12 left", "menu header paused")
        m.resume(now: at(1248))
        _ = m.advance(now: at(1500))
        check(TimerFormat.menuHeader(m.state!, ringing: true, now: at(1500), time: time) == "Timer — time's up"
              && TimerFormat.menuHeader(m.state!, ringing: false, now: at(1500), time: time) == "Timer — ended at 14:35", "menu header ended")
    }

    // MARK: Sound
    let wav = TimerSound.wav()
    let samples = (wav.count - 44) / 2
    check(wav.prefix(4) == Data("RIFF".utf8) && abs(Double(samples) / Double(ToneSynth.sampleRate) - 1.27) < 0.02,
          "cue: a 1.27 s WAV (got \(Double(samples) / Double(ToneSynth.sampleRate)) s)")
    check(Set(ToneCue.allCases.map { ToneSynth.render($0.notes).count }).contains(ToneSynth.render(TimerSound.notes).count) == false,
          "cue: its own length, unlike the calendar cues")

    // MARK: Settings
    MainActor.assumeIsolated {
        let suite = "lintel.checks.timer.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = SettingsStore(defaults: defaults, center: NotificationCenter())
        check(store[Keys.timerEnabled] && store[Keys.timerSound] && store[Keys.timerRepeatAlert] && store[Keys.timerOpenOnFinish],
              "timer switches default on")
        check(store[Keys.timerLastCustomSeconds] == 1200 && store[Keys.timerState] == nil, "custom prefill 20 min; nothing stored")
        check([Keys.timerEnabled.name, Keys.timerSound.name, Keys.timerRepeatAlert.name, Keys.timerOpenOnFinish.name,
               Keys.timerLastCustomSeconds.name, Keys.timerState.name].allSatisfy { $0.hasPrefix(Keys.timerKeyPrefix) }, "keys under timer.")
        check(IdleActivity(rawValue: "timer")?.title == "Timer" && ExpandedContent(idle: .timer) == .timer, "Timer as the idle choice")
        defaults.removePersistentDomain(forName: suite)
    }

    // MARK: Activity-engine contract
    do {
        let base = CGSize(width: 185, height: 33.5)
        check(PresentationMetrics.compactSize(for: .live([.timer]), base: base) == CGSize(width: 309, height: 34.5), "timer island 309 × 34.5")
        check(PresentationMetrics.compactSize(for: .live([.media, .timer]), base: base).width == 309, "timer + media share the wider island")
        check(PresentationMetrics.compactSize(for: .live([.media]), base: base).width == 276, "without a timer the live width is unchanged")

        var e = ActivityEngine()
        e.timerPageEnabled = true
        e.shelfEnabled = false // the cycle with both pages is checked in RegressionChecks
        e.setLive(.media, active: true, identity: "m", now: 1)
        e.setLive(.timer, active: true, identity: "timer-A-0", now: 2)
        check(e.compactPresentation == .live([.media, .timer]), "timer and media share the compact island")
        check(e.expandedContent == .timer, "a timer started last opens the timer page")
        e.setLive(.calendar, active: true, identity: "c", now: 3)
        check(e.expandedContent == .both, "a later event: the media/calendar logic")
        e.setLive(.timer, active: true, identity: "timer-A-1", now: 4)
        check(e.expandedContent == .timer, "changing the timer makes it most recent again")
        check(e.mostRecent == .timer, "the timer becomes the most recent activity")
        e.setLive(.lock, active: true, now: 5)
        check(e.expandedContent == .timer, "the lock doesn't count as a later activity")
        e.setLive(.lock, active: false, now: 6)
        e.setExpanded(true)
        e.cycleExpanded()
        check(e.expandedContent == .media, "cycle from the timer page wraps to Media")
        e.cycleExpanded(); e.cycleExpanded(); e.cycleExpanded()
        check(e.expandedContent == .timer, "media → calendar → both → timer")
        e.setExpanded(false)
        check(e.dismissTopLiveActivity() == .timer && e.compactPresentation == .live([.media, .calendar]), "the timer can be dismissed (most recent)")
        e.setLive(.timer, active: true, identity: "timer-A-2", now: 7)
        check(e.visibleLiveKinds.contains(.timer), "a changed timer shows again after a dismiss")
        e.setLive(.timer, active: false, now: 8)
        check(e.compactPresentation == .live([.media, .calendar]) && e.expandedContent == .both, "timer gone: back to the others")

        var kept = ActivityEngine()
        kept.timerPageEnabled = true
        kept.setLive(.timer, active: true, identity: "timer-B-0", now: 1)
        kept.setExpanded(true)
        kept.keepExpanded(.timer)
        kept.setLive(.timer, active: false, now: 2)
        check(kept.expandedContent == .timer, "a card on the timer page keeps it (presets) after the timer is cancelled")
        kept.setExpanded(false)
        check(kept.expandedContent == .media, "closing the card drops the kept page")
        kept.keepExpanded(.timer)
        check(kept.expandedContent == .media, "keeping a page needs an open card")

        var off = ActivityEngine()
        off.shelfEnabled = false
        off.setExpanded(true)
        off.cycleExpanded(); off.cycleExpanded(); off.cycleExpanded()
        check(off.expandedContent == .media, "Timers off: the timer page isn't in the cycle")
        var idle = ActivityEngine()
        idle.timerPageEnabled = true
        idle.idleContent = .timer
        check(idle.expandedContent == .timer, "idle choice Timer opens the presets")
    }
}
