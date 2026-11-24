import CoreGraphics
import Foundation
import LintelCore

/// Mission Control: tracking its windows, tucking the island.
func runMissionControlChecks() {
    // Setting.
    check(Keys.animateMissionControl.name == "island.missionControl.animate" && Keys.animateMissionControl.defaultValue,
          "Animate with Mission Control is on by default")

    // Tracker: hidden from the overlay's first frame until the Spaces bar has left.
    var tracker = MissionControlTracker()
    check(!tracker.hidesIsland && tracker.phase == .none, "nothing hidden at first")
    check(tracker.update(overlay: true, bar: true, at: 10.0) && tracker.phase == .shown, "overlay and bar → shown, hidden at once")
    check(!tracker.update(overlay: true, bar: true, at: 10.5) && tracker.phase == .shown, "still shown")
    check(!tracker.update(overlay: false, bar: true, at: 10.79) && tracker.phase == .leaving && tracker.hidesIsland,
          "overlay gone, bar still there → leaving, still hidden (never over the Spaces bar)")
    check(tracker.update(overlay: false, bar: false, at: 10.93) && tracker.phase == .none, "bar gone → shows again")
    check(tracker.update(overlay: true, bar: true, at: 20.0), "a quick visit opens…")
    check(tracker.update(overlay: false, bar: false, at: 20.05) && !tracker.hidesIsland, "…and closing at once shows again")
    _ = tracker.update(overlay: true, bar: true, at: 30.0)
    _ = tracker.update(overlay: false, bar: true, at: 30.3)
    check(!tracker.update(overlay: true, bar: true, at: 30.35) && tracker.phase == .shown,
          "re-entered while leaving → shown again, never shown in between")
    var bar = MissionControlTracker()
    check(!bar.update(overlay: false, bar: true, at: 1) && bar.phase == .none, "a bar alone doesn't start Mission Control")
    var stuck = MissionControlTracker()
    _ = stuck.update(overlay: true, bar: true, at: 40.0)
    _ = stuck.update(overlay: false, bar: true, at: 40.2)
    check(!stuck.tick(at: 41.19) && stuck.hidesIsland, "a lingering bar keeps it hidden up to the timeout")
    check(stuck.tick(at: 41.2) && !stuck.hidesIsland && stuck.log.last?.contains("timeout") == true,
          "a bar that never leaves releases the island after 1 s")
    check(tracker.log.count >= 6 && tracker.log.first?.contains("none → shown") == true, "phase changes are logged")

    // Which windows are Mission Control's (measured layout: overlay 19 full display, bar 14 across the top).
    let display = CGRect(x: 0, y: 0, width: 1710, height: 1107)
    let second = CGRect(x: 1710, y: 0, width: 2560, height: 1440)
    func kind(_ owner: String, _ layer: Int, _ rect: CGRect) -> MissionControlWindow? {
        MissionControlWindow.classify(owner: owner, layer: layer, bounds: rect, displays: [display, second])
    }
    check(kind("WindowManager", 19, display) == .overlay, "overlay over the display")
    check(kind("WindowManager", 19, second) == .overlay, "overlay over another display")
    check(kind("WindowManager", 19, CGRect(x: 0, y: 0, width: 855, height: 1107)) == nil, "half a display isn't the overlay")
    check(kind("WindowManager", 14, CGRect(x: 0, y: 0, width: 1710, height: 130)) == .bar, "Spaces bar across the top")
    check(kind("WindowManager", 14, CGRect(x: 0, y: 500, width: 1710, height: 130)) == nil, "not at the top → not the bar")
    check(kind("WindowManager", 14, CGRect(x: 0, y: 0, width: 600, height: 130)) == nil, "not full width → not the bar")
    check(kind("WindowManager", 14, CGRect(x: 0, y: 0, width: 1710, height: 600)) == nil, "too tall → not the bar")
    check(kind("WindowManager", 17, CGRect(x: 1148, y: 1074, width: 93, height: 82)) == nil, "thumbnails don't count")
    check(kind("Dock", 20, display) == nil && kind("Finder", 19, display) == nil, "other owners never count")

    // The shape the island tucks into.
    let notched = ScreenDescriptor(uuid: "N", name: "Built-in", frame: display, notchSize: CGSize(width: 185, height: 33.5),
                                   menuBarHeight: 33.5, isBuiltIn: true, isPrimary: true)
    let plain = ScreenDescriptor(uuid: "P", name: "External", frame: second, notchSize: nil, menuBarHeight: 24,
                                 isBuiltIn: false, isPrimary: false)
    let tuning = CGSize(width: 17, height: 2)
    let notchPlan = DisplayPlanner.plan(for: notched, forceSimulatedNotch: false, tuning: tuning)
    check(notchPlan.compactSize == CGSize(width: 202, height: 35.5) && notchPlan.tuckSize == CGSize(width: 185, height: 33.5),
          "notch: tucks into the hardware notch exactly, without the tuning")
    check(notchPlan.tuckHiddenByHardware, "the notch hides the tucked island")
    let simulated = DisplayPlanner.plan(for: plain, forceSimulatedNotch: true, tuning: tuning)
    check(simulated.tuckSize == CGSize(width: 185, height: 24) && !simulated.tuckHiddenByHardware,
          "simulated notch: its untuned shape, then fades")
    let pill = DisplayPlanner.plan(for: plain, forceSimulatedNotch: false, tuning: .zero)
    check(pill.tuckSize == pill.compactSize && !pill.tuckHiddenByHardware, "no notch: collapses into the pill, then fades")

    // Timing: the tuck is a critically damped spring fitted to the zoom-out; content leads the shape.
    check(MissionControlTiming.tuckDamping == 1.0 && MissionControlTiming.tuckResponse == 0.24, "tuck spring (no overshoot)")
    check(MissionControlTiming.contentFadeOut < MissionControlTiming.tuckDuration, "content fades before the shape is in")
    check(MissionControlTiming.contentFadeInDelay == 0.16, "content fades in when growing back as when the card opens")
    let fadeEnd = MissionControlTiming.windowFadeDelay + MissionControlTiming.windowFadeDuration
    check(MissionControlTiming.windowFadeDelay >= 0.2 && fadeEnd <= 0.4,
          "the window fades only once the island is almost in the notch, and is gone when the zoom-out ends (≈ 0.4 s)")
}
