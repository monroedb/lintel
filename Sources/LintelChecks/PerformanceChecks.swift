import Foundation
import LintelCore

/// Performance and energy pass: full screen is looked for in
/// bursts, the Mission Control watcher rests while the user is away, the live waveform's tap runs
/// only while a waveform is seen, invisible bar moves aren't committed, and the Focus database is
/// watched instead of re-read every second.
func runPerformanceChecks() {
    // Full-screen bursts.
    var burst = FullScreenBurst()
    burst.trigger(now: 100)
    check(burst.until == 100 + FullScreenBurst.settleWindow && FullScreenBurst.pollInterval == 0.25,
          "a trigger keeps the burst going for 2 s at 4 Hz")
    check(!burst.ends(now: 100.5, settled: true, missionControl: false), "settled early: the burst still runs out its window")
    check(!burst.ends(now: 103, settled: false, missionControl: false), "not settled: the burst goes on past its window")
    check(burst.ends(now: 102, settled: true, missionControl: false), "settled after the window: the burst ends")
    check(burst.ends(now: 100.25, settled: false, missionControl: true), "Mission Control ends a burst (one starts when it leaves)")
    burst.trigger(now: 101.9)
    check(!burst.ends(now: 102, settled: true, missionControl: false), "a new trigger extends the window")

    // Mission Control watcher rests.
    check(MissionControlRest.restAfter == 4 && MissionControlRest.looksPerCheck == 30, "rest after 4 s without input, checked once a second")
    check(MissionControlRest.restingInterval == 1, "resting looks once a second (Mission Control opened by a script is seen within a second)")
    check(!MissionControlRest.shouldRest(secondsSinceInput: 3.9, overlay: false, bar: false, knownWindows: 0), "input 3.9 s ago: keep looking")
    check(MissionControlRest.shouldRest(secondsSinceInput: 4, overlay: false, bar: false, knownWindows: 0), "4 s without input: rest")
    check(!MissionControlRest.shouldRest(secondsSinceInput: 60, overlay: true, bar: false, knownWindows: 1),
          "Mission Control's overlay is up: never rest (the user can look at it without touching anything)")
    check(!MissionControlRest.shouldRest(secondsSinceInput: 60, overlay: false, bar: true, knownWindows: 1), "its Spaces bar is up: never rest")
    check(!MissionControlRest.shouldRest(secondsSinceInput: 60, overlay: false, bar: false, knownWindows: 1),
          "a Mission Control window is still known: never rest")

    // What wakes the resting watcher.
    check(MissionControlRest.wakes(eventType: 10, sourcePID: 0) && MissionControlRest.wakes(eventType: 5, sourcePID: 0)
          && MissionControlRest.wakes(eventType: 12, sourcePID: 0) && MissionControlRest.wakes(eventType: 29, sourcePID: 0),
          "any input from the hardware wakes it (keys, pointer moves, modifiers, gestures)")
    check(!MissionControlRest.wakes(eventType: 0, sourcePID: 0) && !MissionControlRest.wakes(eventType: 0, sourcePID: 931),
          "null events never wake it (an app posted them about once a second)")
    check(!MissionControlRest.wakes(eventType: 12, sourcePID: 931) && !MissionControlRest.wakes(eventType: 5, sourcePID: 931),
          "modifier and pointer echoes posted by an app don't wake it")
    check(MissionControlRest.wakes(eventType: 10, sourcePID: 931) && MissionControlRest.wakes(eventType: 14, sourcePID: 931)
          && MissionControlRest.wakes(eventType: 1, sourcePID: 931) && MissionControlRest.wakes(eventType: 30, sourcePID: 931),
          "a key, the Mission Control key, a click or a gesture a program posts wakes it")
    check(MissionControlRest.wakes(eventType: 0xFFFF_FFFE, sourcePID: 0), "the tap switched off for being slow counts as input")
    check(!MissionControlRest.wakes(eventType: 0xFFFF_FFFF, sourcePID: 0),
          "\"disabled by user input\" (sent when the tap switches itself off) doesn't: counting it looped the tap")

    // Live waveform demand.
    func shows(onScreen: Bool = true, tucked: Bool = false, expanded: Bool = false, content: ExpandedContent = .media,
               displayed: CompactPresentation = .live([.media]), focus: Bool = false, compact: Bool = true) -> Bool {
        MediaWaveformDemand.shows(onScreen: onScreen, tucked: tucked, expanded: expanded, expandedContent: content,
                                  displayed: displayed, focusGlyphReplaces: focus, compactWaveform: compact)
    }
    check(shows(), "Now Playing alone in the compact island: its waveform shows")
    check(shows(displayed: .peek(.media)), "a media Quick Peek shows the waveform")
    check(!shows(onScreen: false), "island hidden, displays asleep or locked: no waveform")
    check(!shows(tucked: true), "tucked into the notch for Mission Control: no waveform")
    check(!shows(displayed: .live([.media, .calendar])), "media with an event: the calendar ring takes the slot")
    check(!shows(displayed: .live([.media, .timer])), "media with a timer: the countdown takes the slot")
    check(!shows(displayed: .live([.calendar])) && !shows(displayed: .idle), "no media: no waveform")
    check(!shows(focus: true), "a Focus glyph replaces the compact waveform")
    check(shows(displayed: .peek(.media), focus: true), "the peek's waveform isn't replaced by the Focus glyph")
    check(!shows(compact: false) && !shows(displayed: .peek(.media), compact: false), "compact waveform switched off: none in the compact island")
    check(!shows(displayed: .notification(.volume)), "a HUD in the compact island: no waveform")
    check(shows(expanded: true, content: .media, displayed: .idle) && shows(expanded: true, content: .both, compact: false),
          "the open player (media or both) has its own waveform, whatever the compact setting")
    check(!shows(expanded: true, content: .calendar) && !shows(expanded: true, content: .timer) && !shows(expanded: true, content: .shelf),
          "the card open on another page: no waveform")
    check(!shows(onScreen: false, expanded: true, content: .media), "the open player off screen: no waveform")

    // Visible waveform steps.
    check(WaveformStep.minimumStep == 0.25, "a quarter point is half a pixel on a 2× display")
    check(!WaveformStep.isVisible([2.1, 5, 7.2, 14, 3], from: [2.1, 5.2, 7, 13.8, 3.1]), "moves under a quarter point aren't committed")
    check(WaveformStep.isVisible([2.1, 5, 7.2, 14, 3], from: [2.1, 5, 7.2, 14, 2.7]), "one bar moving 0.3 pt is committed")
    check(WaveformStep.isVisible([2.1, 5], from: []), "the first level set is always committed")
    check(WaveformStep.isVisible([2.1, 5, 7], from: [2.1, 5]), "a different bar count is always committed")

    // Focus provider timer.
    check(FocusPolling.interval(detection: .system, databaseConfigured: true, databaseReadable: true, entitled: true, authorized: true) == 0.25,
          "status polled at 4 Hz only when it can be trusted (entitlement and access)")
    check(FocusPolling.interval(detection: .database, databaseConfigured: true, databaseReadable: true, entitled: false, authorized: false) == 10,
          "database watched: a cheap stat every 10 s instead of reading it every second")
    check(FocusPolling.interval(detection: .unavailable, databaseConfigured: true, databaseReadable: false, entitled: false, authorized: false) == 5,
          "database not readable (Full Disk Access missing): tried again every 5 s")
    check(FocusPolling.interval(detection: .unavailable, databaseConfigured: false, databaseReadable: false, entitled: false, authorized: false) == nil,
          "no entitlement and no database: no timer at all (the access state can't be used)")
    check(FocusPolling.interval(detection: .unavailable, databaseConfigured: false, databaseReadable: false, entitled: true, authorized: false) == 5,
          "entitled but not authorised: access re-checked every 5 s")
}
