import CoreGraphics
import Foundation
import LintelCore

// Minimal assertion runner (XCTest / swift-testing are unavailable without full Xcode).
nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var passes = 0

func check(_ condition: @autoclosure () -> Bool, _ message: String, file: StaticString = #fileID, line: UInt = #line) {
    if condition() {
        passes += 1
    } else {
        failures += 1
        print("FAIL \(file):\(line): \(message)")
    }
}

func near(_ a: CGFloat, _ b: CGFloat, _ eps: CGFloat = 0.01) -> Bool { abs(a - b) <= eps }

// MARK: - Fixtures

let builtIn = ScreenDescriptor(uuid: "BUILTIN", name: "Built-in Retina Display",
                               frame: CGRect(x: 0, y: 0, width: 1710, height: 1107),
                               notchSize: CGSize(width: 185, height: 33.5), menuBarHeight: 33.5,
                               isBuiltIn: true, isPrimary: true)
let external = ScreenDescriptor(uuid: "EXT", name: "Studio Display",
                                frame: CGRect(x: 1710, y: 0, width: 2560, height: 1440),
                                notchSize: nil, menuBarHeight: 24, isBuiltIn: false, isPrimary: false)

// MARK: - Notch size from auxiliary areas

check(ScreenDescriptor.notchSize(screenWidth: 1710, auxLeftWidth: 762.5, auxRightWidth: 762.5, safeAreaTop: 33.5)
      == CGSize(width: 185, height: 33.5), "notch size from aux areas")
check(ScreenDescriptor.notchSize(screenWidth: 2560, auxLeftWidth: nil, auxRightWidth: nil, safeAreaTop: 0) == nil,
      "no notch without aux areas")

// MARK: - Display planning

do {
    let plans = DisplayPlanner.plan(screens: [builtIn, external], selection: .main, chosenUUID: nil,
                                    forceSimulatedNotch: false, tuning: .zero)
    check(plans.count == 1 && plans[0].screenUUID == "BUILTIN", "main display → primary only")
    let p = plans[0]
    check(p.shape == .notch, "notched display uses notch shape")
    check(p.canvas == CGRect(x: 543, y: 787, width: 624, height: 320), "canvas 624×320 top-centre (got \(p.canvas))")
    check(p.compactSize == CGSize(width: 185, height: 33.5), "compact = hardware notch")
    let r = p.islandRect(size: p.compactSize)
    check(near(r.minX, 762.5) && near(r.maxY, 1107), "island hugs the top edge, centred (got \(r))")
}
do {
    let plans = DisplayPlanner.plan(screens: [builtIn, external], selection: .all, chosenUUID: nil,
                                    forceSimulatedNotch: false, tuning: .zero)
    check(plans.count == 2, "all displays → two islands")
    let ext = plans.first { $0.screenUUID == "EXT" }
    check(ext?.shape == .pill, "notchless external display → pill")
    check(ext?.hiddenWhenIdle == true, "pill hidden while idle")
    check(near(ext?.compactSize.height ?? 0, 18), "pill height = menu bar − 6, min 18 (got \(ext?.compactSize.height ?? -1))")
    check(near(ext?.topInset ?? -1, 3), "pill centred in menu bar")
    check(ext?.canvas.midX == external.frame.midX, "external canvas centred on its display")
}
do {
    let plans = DisplayPlanner.plan(screens: [builtIn, external], selection: .all, chosenUUID: nil,
                                    forceSimulatedNotch: true, tuning: .zero)
    let ext = plans.first { $0.screenUUID == "EXT" }
    check(ext?.shape == .simulatedNotch && ext?.compactSize == CGSize(width: 185, height: 24),
          "force simulated notch on notchless display")
    check(plans.first { $0.screenUUID == "BUILTIN" }?.shape == .notch, "real notch unaffected by force simulated")
}
do {
    let chosen = DisplayPlanner.plan(screens: [builtIn, external], selection: .selected, chosenUUID: "EXT",
                                     forceSimulatedNotch: false, tuning: .zero)
    check(chosen.map(\.screenUUID) == ["EXT"], "chosen display by UUID")
    let missing = DisplayPlanner.plan(screens: [builtIn, external], selection: .selected, chosenUUID: "GONE",
                                      forceSimulatedNotch: false, tuning: .zero)
    check(missing.map(\.screenUUID) == ["BUILTIN"], "missing chosen display falls back to primary")
    let builtInOnly = DisplayPlanner.plan(screens: [external], selection: .builtIn, chosenUUID: nil,
                                          forceSimulatedNotch: false, tuning: .zero)
    check(builtInOnly.count == 1, "built-in selection falls back when there is no built-in display")
    check(DisplayPlanner.plan(screens: [], selection: .all, chosenUUID: nil, forceSimulatedNotch: false,
                              tuning: .zero).isEmpty, "no screens → no islands")
}
do {
    let tuned = DisplayPlanner.plan(for: builtIn, forceSimulatedNotch: false, tuning: CGSize(width: 2, height: 1))
    check(tuned.compactSize == CGSize(width: 187, height: 34.5), "tuning adds to the notch size")
    let pill = DisplayPlanner.plan(for: builtIn, forceSimulatedNotch: false, tuning: .zero, treatAsNotchless: true)
    check(pill.shape == .pill, "debug override renders a pill on a notched display")
    check(pill.hoverZone.width == IslandMetrics.pillHoverZoneWidth, "hidden pill uses the wider hover zone")
}

// MARK: - Interaction state machine

do {
    var m = IslandInteraction()
    let hoverOff = InteractionConfig(expandOnHover: false, hoverDelay: 0.4)
    check(m.pointerEntered(hoverOff) == [.cancelCollapse] && m.phase == .elevated, "enter elevates, no expand timer")
    check(m.expandTimerFired() == [] && m.phase == .elevated, "stray expand timer ignored")
    check(m.clicked() == [.cancelExpand, .cancelCollapse] && m.phase == .expanded, "click expands")
    check(m.clicked() == [] && m.phase == .expanded, "click inside expanded keeps it open")
    check(m.pointerExited(hoverOff) == [.cancelExpand, .scheduleCollapse(after: IslandTiming.collapseDelay)], "exit schedules collapse")
    _ = m.collapseTimerFired()
    check(m.phase == .idle, "collapse returns to idle")
}
do {
    var m = IslandInteraction()
    let hoverOn = InteractionConfig(expandOnHover: true, hoverDelay: 0.4)
    check(m.pointerEntered(hoverOn) == [.cancelCollapse, .scheduleExpand(after: 0.4)], "hover schedules expand after delay")
    _ = m.expandTimerFired()
    check(m.phase == .expanded, "expand timer expands while inside")
    _ = m.pointerExited(hoverOn)
    _ = m.pointerEntered(hoverOn)
    _ = m.collapseTimerFired()
    check(m.phase == .expanded, "re-entering before the collapse delay keeps it expanded")
    check(m.pointerEntered(hoverOn) == [], "duplicate enter ignored")
}
do {
    var m = IslandInteraction()
    let hoverOn = InteractionConfig(expandOnHover: true, hoverDelay: 0.4)
    _ = m.pointerEntered(hoverOn)
    check(m.pointerExited(hoverOn) == [.cancelExpand, .scheduleCollapse(after: IslandTiming.collapseDelay)], "leaving early cancels expand")
    _ = m.expandTimerFired()
    check(m.phase != .expanded, "late expand timer after exit does nothing")
    _ = m.collapseTimerFired()
    check(m.phase == .idle, "elevation released after exit")
}

// MARK: - Settings store

await MainActor.run {
    let suite = "lintel.checks.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    let store = SettingsStore(defaults: defaults, center: NotificationCenter())
    check(store[Keys.expandOnHover] == false, "default expand-on-hover is off")
    check(store[Keys.hoverDelay] == 0, "default hover delay 0 s")
    check(store[Keys.displaySelection] == .main, "default display is the main display")
    check(store[Keys.hideInFullScreen] == true && store[Keys.progressiveBlur] == true, "island defaults")
    store[Keys.hoverDelay] = 0.4
    check(store[Keys.hoverDelay] == 0.4 && defaults.double(forKey: "island.hoverDelay") == 0.4, "double round-trip")
    store[Keys.displaySelection] = .all
    check(defaults.string(forKey: "island.display") == "all" && store[Keys.displaySelection] == .all, "choice stored as raw value")
    defaults.set("garbage", forKey: "island.display")
    check(store[Keys.displaySelection] == .main, "unusable stored value falls back to default")
    store[Keys.chosenDisplayUUID] = "ABC"
    check(store[Keys.chosenDisplayUUID] == "ABC", "optional string stored")
    store[Keys.chosenDisplayUUID] = nil
    check(defaults.object(forKey: "island.display.uuid") == nil && store[Keys.chosenDisplayUUID] == nil, "nil removes key")
    defaults.set("YES", forKey: Keys.debugShowIdlePill.name)
    check(store[Keys.debugShowIdlePill] == true, "launch-argument style \"YES\" decodes as true")
    defaults.set("0.25", forKey: Keys.hoverDelay.name)
    check(store[Keys.hoverDelay] == 0.25, "numeric string decodes as Double")
    store.reset(Keys.hoverDelay)
    check(!store.hasValue(for: Keys.hoverDelay) && store[Keys.hoverDelay] == 0, "reset removes explicit value")
    defaults.removePersistentDomain(forName: suite)
}

runIslandChecks()
runIslandSupportChecks()
runHUDChecks()
runMediaChecks()
runAlertChecks()
runCalendarChecks()
runRegressionChecks()
runLockStateChecks()
runTimerChecks()
runTimerRulerChecks()
runShelfChecks()
runSpaceChecks()
runMissionControlChecks()
runSettingsChecks()
runMenuBarItemChecks()
runPerformanceChecks()

print("lintel-checks: \(passes) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
