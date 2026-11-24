import CoreGraphics
import Foundation
import LintelCore

// Checks for the Ruler picker: style and settings, the scale's
// geometry, colours and fades, the rubber band, the motion after a release (lands on whole minutes,
// starts at the release speed, no overshoot), the release speed, haptic ticks, gesture routing,
// wheel and keys, keyboard focus and quick presets.

private func approx(_ a: Double, _ b: Double, _ eps: Double = 1e-6) -> Bool { abs(a - b) <= eps }

/// Runs a motion at 120 Hz until it finishes; returns the sampled positions.
private func run(_ motion: RulerMotion, seconds: Double = 4) -> [Double] {
    stride(from: motion.startTime, through: motion.startTime + seconds, by: 1.0 / 120).map { motion.position(at: $0) }
}

@MainActor
func runTimerRulerChecks() {
    let scale = TimerRulerScale()
    let physics = RulerPhysics()

    // MARK: Style and settings
    check(Keys.timerPickerStyle.defaultValue == .ruler, "Ruler is the default picker style")
    check(TimerPickerStyle.decode("classic") == .classic && TimerPickerStyle.decode("ruler") == .ruler, "styles decode")
    check(TimerPickerStyle.decode("wheel") == nil, "an unknown style is unusable (falls back to Ruler)")
    check(Keys.timerRulerLastMinutes.defaultValue == 15, "the ruler opens at 15 min by default")
    check(Keys.timerPresets.defaultValue.minutes == [3, 5, 10], "default quick presets 3, 5, 10")
    check(TimerPolicy.presetMinutes == [1, 3, 5, 10, 15, 25, 30], "Classic keeps its fixed tiles")
    check(Keys.timerPickerStyle.name.hasPrefix(Keys.timerKeyPrefix) && Keys.timerPresets.name.hasPrefix(Keys.timerKeyPrefix)
          && Keys.timerRulerLastMinutes.name.hasPrefix(Keys.timerKeyPrefix), "new keys use the timer. prefix")

    let suite = "lintel-checks-ruler-\(ProcessInfo.processInfo.processIdentifier)"
    if let defaults = UserDefaults(suiteName: suite) {
        let store = SettingsStore(defaults: defaults, center: NotificationCenter())
        check(store[Keys.timerPresets] == .standard && store[Keys.timerPickerStyle] == .ruler, "nothing stored → defaults")
        store[Keys.timerPresets] = TimerQuickPresets(minutes: [25, 1])
        check(defaults.array(forKey: Keys.timerPresets.name) as? [Int] == [1, 25], "presets stored as a sorted array of numbers")
        check(store[Keys.timerPresets].minutes == [1, 25], "presets read back")
        defaults.set("1,3, 5;10", forKey: Keys.timerPresets.name)
        check(store[Keys.timerPresets].minutes == [1, 3, 5, 10], "presets given as text (launch argument)")
        defaults.set("nonsense", forKey: Keys.timerPresets.name)
        check(store[Keys.timerPresets] == .standard, "an unusable value falls back to 3, 5, 10")
        store[Keys.timerPresets] = TimerQuickPresets(minutes: [])
        check(store[Keys.timerPresets].minutes.isEmpty, "an empty list is kept (no pills, menus only Custom…)")
        defaults.set("classic", forKey: Keys.timerPickerStyle.name)
        check(store[Keys.timerPickerStyle] == .classic, "style read from defaults")
        defaults.removePersistentDomain(forName: suite)
    }

    // MARK: Scale and geometry
    check(scale.minimum == 1 && scale.maximum == 120 && scale.origin == 0 && scale.spacing == 9 && scale.width == 345,
          "range 1 … 120 min, origin 0, 9 pt per minute across the 345 pt body")
    check(scale.selected(15.4) == 15 && scale.selected(15.5) == 16 && scale.selected(0.2) == 1 && scale.selected(-4) == 1
          && scale.selected(130) == 120 && scale.selected(.nan) == 1, "selected minute: rounded, within 1 … 120")
    check(near(scale.x(of: 15, position: 15), 172.5) && near(scale.x(of: 16, position: 15), 181.5)
          && near(scale.x(of: 20, position: 15.5), 172.5 + 4.5 * 9), "the selected minute sits under the centre (x 172.5)")
    check(scale.visibleMinutes(position: 15) == 0...36, "at 15: ticks 0 … 36 are drawn (nothing before 0)")
    check(scale.visibleMinutes(position: 120) == 99...120, "at 120: nothing after the end")
    check(scale.visibleMinutes(position: 1) == 0...22, "at 1: from the origin tick")
    check((0...120).filter(scale.isLabelled) == Array(stride(from: 0, through: 120, by: 5)), "labels every 5 min, 0 … 120")
    check(scale.tone(of: 14, selected: 15) == .passed && scale.tone(of: 15, selected: 15) == .selected
          && scale.tone(of: 16, selected: 15) == .ahead, "ticks up to the selection bright, the selected light, the rest dim")
    check(approx(scale.edgeOpacity(x: 0), 0) && approx(scale.edgeOpacity(x: 28), 0.5) && approx(scale.edgeOpacity(x: 56), 1)
          && approx(scale.edgeOpacity(x: 172.5), 1) && approx(scale.edgeOpacity(x: 317), 0.5) && approx(scale.edgeOpacity(x: 345), 0),
          "edges fade linearly over 56 pt on both sides")
    check(scale.clock(15) == "15:00" && scale.clock(1) == "1:00" && scale.clock(78) == "1:18:00" && scale.clock(120) == "2:00:00",
          "duration digits: 15:00, 1:18:00")

    // Rubber band past the ends.
    check(scale.rubberBanded(50) == 50 && scale.rubberBanded(1) == 1 && scale.rubberBanded(120) == 120, "no resistance inside the range")
    let banded = scale.rubberBanded(0)
    check(banded < 1 && banded > 0, "1 min past the start shows less than 1 min of stretch (got \(banded))")
    check(scale.rubberBanded(-1000) > 1 - scale.bandMinutes && scale.rubberBanded(2000) < 120 + scale.bandMinutes,
          "the stretch never exceeds half the ruler")
    var monotonic = true, inverse = true
    var previous = -Double.infinity
    for raw in stride(from: -40.0, through: 160, by: 0.25) {
        let shown = scale.rubberBanded(raw)
        if shown < previous { monotonic = false }
        previous = shown
        if !approx(scale.unbanded(shown), raw, 1e-6) { inverse = false }
    }
    check(monotonic, "the rubber band is monotonic")
    check(inverse, "a drag can pick up a stretched ruler where it is drawn (unbanded inverts rubberBanded)")

    // MARK: Motion after a release
    let slow = physics.release(position: 15.4, velocity: 1.0, time: 10, scale: scale)
    check(slow.kind == .settle && slow.target == 15, "a slow release settles to the nearest minute")
    let still = physics.release(position: 15, velocity: 0, time: 10, scale: scale)
    check(still.kind == .settle && still.target == 15 && approx(still.position(at: 10.5), 15), "no speed → stays on its minute")

    let flick = physics.release(position: 15, velocity: 20, time: 10, scale: scale)
    check(flick.kind == .momentum && flick.target == 25, "momentum travels speed × 0.5 s: 20 min/s from 15 → 25")
    check(approx(flick.velocity(at: 10), 20, 1e-9), "momentum starts at exactly the release speed")
    let flickPath = run(flick)
    check(zip(flickPath, flickPath.dropFirst()).allSatisfy { $0.0 <= $0.1 + 1e-12 } && flickPath.allSatisfy { $0 <= 25 + 1e-9 },
          "momentum decelerates without overshooting")
    check(abs(flick.position(at: 11.5) - 25) < 0.5 && abs(flick.position(at: 13) - 25) < 0.03 && !flick.isFinished(at: 13)
          && flick.isFinished(at: 14) && approx(flick.position(at: 14), 25, 0.01),
          "momentum reaches 25's tick within 1.5 s, is a quarter point away at 3 s, and rests there")

    let rounded = physics.release(position: 15, velocity: 9, time: 0, scale: scale)
    check(rounded.target == 20 && rounded.kind == .momentum, "the projected point (19.5) is rounded to a whole minute (20)")
    let backwards = physics.release(position: 30, velocity: -12, time: 0, scale: scale)
    let backPath = run(backwards)
    check(backwards.target == 24 && zip(backPath, backPath.dropFirst()).allSatisfy { $0.0 >= $0.1 - 1e-12 },
          "momentum to fewer minutes: 30 at −12 min/s → 24, monotonic")
    let toEnd = physics.release(position: 110, velocity: 60, time: 0, scale: scale)
    check(toEnd.target == 120 && approx(toEnd.position(at: 5), 120, 1e-3), "momentum that would pass 120 stops at 120")
    let atEnd = physics.release(position: 119.8, velocity: 5, time: 0, scale: scale)
    let atEndPath = run(atEnd)
    check(atEnd.target == 120 && (atEndPath.max() ?? 0) < 120.05 && approx(atEndPath.last ?? 0, 120, 1e-3),
          "a fast release next to the end bounces at most a twentieth of a minute and rests on 120")
    let toStart = physics.release(position: 4, velocity: -40, time: 0, scale: scale)
    check(toStart.target == 1 && approx(toStart.position(at: 5), 1, 1e-3), "momentum towards 0 stops at 1 min")
    let pastStart = physics.release(position: 0.4, velocity: -3, time: 0, scale: scale)
    check(pastStart.kind == .settle && pastStart.target == 1 && approx(pastStart.position(at: 3), 1, 1e-3), "released past the start → springs back to 1")
    let pastEnd = physics.release(position: 121.3, velocity: 4, time: 0, scale: scale)
    check(pastEnd.kind == .settle && pastEnd.target == 120 && approx(pastEnd.position(at: 3), 120, 1e-3), "released past the end → springs back to 120")

    var allWhole = true
    for start in stride(from: 1.0, through: 120, by: 3.7) {
        for speed in [-300.0, -45, -7, -1.6, -0.5, 0, 0.7, 2, 13, 80, 400] {
            let motion = physics.release(position: start, velocity: speed, time: 0, scale: scale)
            let rest = motion.position(at: 20)
            if !scale.contains(motion.target) || !approx(rest, Double(motion.target), 1e-3) || !motion.isFinished(at: 20) { allWhole = false }
            if motion.kind == .momentum, !approx(motion.velocity(at: 0), speed, 1e-9) {
                // Only the end-clamped decelerations may start slower or faster (shortest/longest limits).
                let tau = abs(Double(motion.target) - start) / abs(speed)
                if tau >= physics.shortestDeceleration, tau <= physics.longestDeceleration { allWhole = false }
            }
        }
    }
    check(allWhole, "every release from 1 … 120 at −300 … 400 min/s rests on a whole minute in range, from the release speed")

    let step = physics.step(from: 15, velocity: 0, to: 16, time: 0, scale: scale)
    let stepPath = run(step, seconds: 1)
    check(step.kind == .step && step.target == 16 && stepPath.allSatisfy { $0 >= 15 - 1e-9 && $0 <= 16 + 1e-9 }
          && approx(step.position(at: 0.6), 16, 2e-3), "a step springs to the next minute in about 0.25 s without overshoot")
    check(physics.step(from: 119, velocity: 0, to: 130, time: 0, scale: scale).target == 120
          && physics.step(from: 2, velocity: 0, to: 0, time: 0, scale: scale).target == 1, "steps stay within 1 … 120")
    let chained = physics.step(from: step.position(at: 0.05), velocity: step.velocity(at: 0.05), to: 17, time: 0.05, scale: scale)
    check(approx(chained.position(at: 0.05), step.position(at: 0.05)) && approx(chained.velocity(at: 0.05), step.velocity(at: 0.05), 1e-9),
          "a step during a step continues from the current position and speed")

    // MARK: Release speed
    var tracker = RulerVelocityTracker()
    for frame in 0..<30 { tracker.add(position: 15 + Double(frame) * 0.1, time: Double(frame) / 120) }
    check(approx(tracker.velocity(at: 29.0 / 120 + 0.004), 12, 1e-6), "speed from the last 80 ms: 0.1 min per 120 Hz frame = 12 min/s")
    check(tracker.velocity(at: 29.0 / 120 + 0.07) == 0, "held still 60 ms before the release → no momentum")
    tracker.reset()
    tracker.add(position: 3, time: 1)
    check(tracker.velocity(at: 1) == 0, "a click without movement → no momentum")

    // MARK: Haptic ticks
    var ticker = RulerTicker()
    ticker.reset(to: 15)
    check(ticker.update(selected: 15, now: 0) == nil, "no tick without a change")
    check(ticker.update(selected: 16, now: 0) == .minute, "a minute → light tick")
    check(ticker.update(selected: 17, now: 0.010) == nil && ticker.merged == 1, "changes within 25 ms are merged")
    check(ticker.update(selected: 17, now: 0.030) == .minute, "…into the next tick")
    check(ticker.update(selected: 20, now: 0.060) == .five, "reaching a multiple of 5 → the stronger tick")
    check(ticker.update(selected: 21, now: 0.090) == .minute, "leaving a multiple of 5 → light")
    check(ticker.update(selected: 20, now: 0.120) == .five, "coming back to it → strong")
    check(ticker.update(selected: 19, now: 0.150) == .minute, "19 → light")
    _ = ticker.update(selected: 18, now: 0.160)
    check(ticker.update(selected: 12, now: 0.190) == .five, "merged changes that passed 15 → strong")
    check(RulerTicker.passesFive(from: 14, to: 15) && !RulerTicker.passesFive(from: 15, to: 16) && RulerTicker.passesFive(from: 16, to: 15)
          && !RulerTicker.passesFive(from: 15, to: 14) && RulerTicker.passesFive(from: 12, to: 18) && !RulerTicker.passesFive(from: 11, to: 14)
          && !RulerTicker.passesFive(from: 3, to: 3), "multiples of 5: reached or passed, not left")
    // A fast sweep over the whole ruler at 120 Hz: no more than one tick per 25 ms, and the last
    // minute is ticked once the ruler rests.
    var sweep = RulerTicker()
    sweep.reset(to: 1)
    var ticks: [RulerTicker.Tick] = []
    for frame in 0...60 {
        let minute = 1 + Int((Double(frame) / 60 * 119).rounded())
        if let tick = sweep.update(selected: minute, now: Double(frame) / 120) { ticks.append(tick) }
    }
    if let tick = sweep.update(selected: 120, now: 0.6) { ticks.append(tick) }
    check(ticks.count <= 22 && ticks.count >= 15 && sweep.lastMinute == 120 && !sweep.isPending(selected: 120),
          "a 0.5 s sweep over 119 minutes: \(ticks.count) ticks (at most one per 25 ms), ending on 120")

    // MARK: Gesture routing
    var router = RulerGestureRouter()
    router.began()
    check(router.changed(dx: -3, dy: 1) == .wait, "under 8 pt nothing is decided")
    check(router.changed(dx: -6, dy: 0) == .ruler(dx: -9), "mostly horizontal → the ruler, with the movement so far")
    check(router.changed(dx: -4, dy: 6) == .ruler(dx: -4), "…and the rest of the gesture, even if it turns")
    check(router.ended() == .ruler && router.lastOwner == .ruler && router.owner == .undecided, "its momentum events belong to the ruler too")
    router.began()
    _ = router.changed(dx: 0, dy: 5)
    check(router.changed(dx: 1, dy: 5) == .island(dx: 1, dy: 10), "mostly vertical → the island's swipes (next page, close)")
    check(router.changed(dx: 30, dy: 0) == .island(dx: 30, dy: 0) && router.ended() == .island, "a vertical gesture never scrubs")
    router.began()
    _ = router.changed(dx: 2, dy: -1)
    check(router.ended() == .undecided, "a touch without movement belongs to no one")

    // MARK: Wheel and scroll
    check(RulerInput.wheelSteps(deltaX: 0, deltaY: -1) == 1 && RulerInput.wheelSteps(deltaX: 0, deltaY: 1) == -1,
          "wheel down → one more minute, up → one less")
    check(RulerInput.wheelSteps(deltaX: 0, deltaY: -3.2) == 4 && RulerInput.wheelSteps(deltaX: -1, deltaY: 0) == 1
          && RulerInput.wheelSteps(deltaX: 0, deltaY: 0) == 0, "wheel acceleration moves more; horizontal wheels too")
    check(RulerInput.minutes(forScroll: -9, scale: scale) == 1 && RulerInput.minutes(forScroll: 18, scale: scale) == -2,
          "9 pt of scroll = 1 minute; scrolling right (content left) → more")

    // MARK: Keys
    func key(_ code: UInt16, shift: Bool = false, command: Bool = false) -> RulerKeyAction {
        RulerKeyAction.from(keyCode: code, shift: shift, command: command, option: false, control: false)
    }
    check(key(123) == .step(-1) && key(124) == .step(1) && key(123, shift: true) == .previousFive && key(124, shift: true) == .nextFive,
          "← → one minute, ⇧← ⇧→ to the 5-minute marks")
    check(key(36) == .start && key(76) == .start && key(36, shift: true) == .start && key(53) == .close,
          "Return and Enter start, Escape closes")
    check(key(0) == .other && key(49) == .other && key(123, command: true) == .other && key(12, command: true) == .other,
          "other keys and ⌘ shortcuts aren't the ruler's")
    check(RulerKeyAction.step(1).target(from: 120, scale: scale) == 120 && RulerKeyAction.step(-1).target(from: 1, scale: scale) == 1,
          "keys stay within 1 … 120")
    check(RulerKeyAction.previousFive.target(from: 13, scale: scale) == 10 && RulerKeyAction.previousFive.target(from: 15, scale: scale) == 10
          && RulerKeyAction.previousFive.target(from: 3, scale: scale) == 1, "⇧←: 13 → 10, 15 → 10, 3 → 1")
    check(RulerKeyAction.nextFive.target(from: 13, scale: scale) == 15 && RulerKeyAction.nextFive.target(from: 15, scale: scale) == 20
          && RulerKeyAction.nextFive.target(from: 118, scale: scale) == 120 && RulerKeyAction.nextFive.target(from: 1, scale: scale) == 5,
          "⇧→: 13 → 15, 15 → 20, 118 → 120, 1 → 5")
    check(RulerKeyAction.start.target(from: 15, scale: scale) == nil, "Start isn't a step")

    check(RulerKeyboard.wantsFocus(rulerOpen: true, pointerInside: true, gaveBack: false), "keyboard: ruler open with the pointer inside")
    check(!RulerKeyboard.wantsFocus(rulerOpen: true, pointerInside: false, gaveBack: false)
          && !RulerKeyboard.wantsFocus(rulerOpen: false, pointerInside: true, gaveBack: false)
          && !RulerKeyboard.wantsFocus(rulerOpen: true, pointerInside: true, gaveBack: true),
          "…not with the pointer outside, on another page, or after a foreign key")

    // MARK: Quick presets
    check(TimerQuickPresets(minutes: [10, 3, 5, 3, 0, 2000]).minutes == [3, 5, 10], "presets: sorted, unique, 1 … 1440")
    check(TimerQuickPresets(minutes: Array(1...12)).minutes == Array(1...8), "at most eight presets")
    check(TimerQuickPresets.decode([3, 5, 10] as [NSNumber])?.minutes == [3, 5, 10], "decodes a stored array")
    check(TimerQuickPresets.decode([] as [Any])?.minutes == [], "an empty list stays empty")
    check(TimerQuickPresets.decode(["abc"]) == nil && TimerQuickPresets.decode("abc") == nil
          && TimerQuickPresets.decode([2.5] as [NSNumber]) == nil && TimerQuickPresets.decode(7) == nil, "unusable values → nil (default)")
    check(TimerQuickPresets.decode([3, 2.5, 10] as [NSNumber])?.minutes == [3, 10], "unusable entries are dropped")
    check(TimerQuickPresets.standard.encoded as? [Int] == [3, 5, 10], "encoded as an array of numbers")
    let presets = TimerQuickPresets.standard
    check(presets.adding("25") == .added(TimerQuickPresets(minutes: [3, 5, 10, 25])), "add 25")
    check(presets.adding("12 min") == .added(TimerQuickPresets(minutes: [3, 5, 10, 12])) && presets.adding(" 7m ") != .invalid,
          "add with a unit")
    check(presets.adding("5") == .duplicate && presets.adding("0") == .invalid && presets.adding("1441") == .invalid
          && presets.adding("1.5") == .invalid && presets.adding("-3") == .invalid && presets.adding("abc") == .invalid,
          "duplicates and values outside 1 … 1440 aren't added")
    check(TimerQuickPresets(minutes: Array(1...8)).adding("30") == .full, "a full list says so")
    check(presets.removing(5).minutes == [3, 10] && presets.removing(42) == presets, "remove")
    check(TimerQuickPresets.message(for: .full) == "Up to 8 presets." && TimerQuickPresets.message(for: .added(presets)) == nil,
          "messages for the Settings row")
    check(TimerFormat.presetMenuTitle(minutes: 1) == "1 Minute" && TimerFormat.presetMenuTitle(minutes: 90) == "90 Minutes",
          "menu titles for presets")

    // MARK: A whole scrub, as the app runs it: a swipe at 120 Hz, then the release.
    var held = 15.0
    var swipeTicker = RulerTicker()
    swipeTicker.reset(to: 15)
    var swipeSpeed = RulerVelocityTracker()
    var light = 0, strong = 0
    for frame in 1...24 {
        let now = Double(frame) / 120
        held += RulerInput.minutes(forScroll: -2.7, scale: scale) // 0.3 min per frame = 36 min/s
        swipeSpeed.add(position: held, time: now)
        switch swipeTicker.update(selected: scale.selected(scale.rubberBanded(held)), now: now) {
        case .minute?: light += 1
        case .five?: strong += 1
        case nil: break
        }
    }
    let release = physics.release(position: scale.rubberBanded(held), velocity: swipeSpeed.velocity(at: 24.0 / 120), time: 24.0 / 120, scale: scale)
    var now = release.startTime
    while !release.isFinished(at: now) {
        now += 1.0 / 120
        switch swipeTicker.update(selected: scale.selected(release.position(at: now)), now: now) {
        case .minute?: light += 1
        case .five?: strong += 1
        case nil: break
        }
    }
    _ = swipeTicker.update(selected: release.target, now: now + 0.03)
    check(approx(swipeSpeed.velocity(at: 24.0 / 120), 36, 1e-6) && release.kind == .momentum && release.target == 40,
          "a 36 min/s swipe from 15 released at 22.2 coasts to 40 (got \(release.target))")
    check(light > 0 && strong >= 4 && swipeTicker.lastMinute == 40,
          "ticks along the way: \(light) light, \(strong) strong (20, 25, 30, 35, 40), the last on 40")
}
