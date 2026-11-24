import CoreGraphics
import Foundation
import LintelCore

/// Checks for activity engine, presentation metrics, swipes, window environment,
/// game classification, visibility rules and luminance.
func runIslandChecks() {
    // MARK: Activity engine — layers and priorities
    do {
        var e = ActivityEngine()
        check(e.compactPresentation == .idle, "engine starts idle")
        check(e.expandedContent == .media, "idle expanded content defaults to media (idle default 'Playing')")
        e.setLive(.media, active: true, identity: "track-1", now: 1)
        check(e.compactPresentation == .live([.media]), "media live activity")
        e.setLive(.calendar, active: true, identity: "event-1", now: 2)
        check(e.compactPresentation == .live([.media, .calendar]), "media + calendar share the island")
        check(e.expandedContent == .both, "both active → Duo")

        let g0 = e.generation
        check(e.post(.volume, duration: 1.5, now: 10) == .shown, "HUD shown")
        check(e.compactPresentation == .notification(.volume), "notification has priority over live")
        let g1 = e.generation
        check(g1 > g0, "showing a notification bumps the generation")
        check(e.post(.volume, duration: 1.5, now: 11) == .extended, "repeated HUD extends in place")
        check(e.generation == g1, "extension does not start a new transition")
        check(e.nextDeadline == 12.5, "hold extended to now + duration")
        check(e.tick(now: 12.4) == false && e.compactPresentation == .notification(.volume), "still held before deadline")
        check(e.tick(now: 12.5) == true && e.compactPresentation == .live([.media, .calendar]), "restores live activities after hold")
        check(e.post(.focus, duration: 5, now: 20) == .shown && e.post(.charging, duration: 5, now: 20.1) == .shown,
              "a different alert replaces the current one")
        check(e.compactPresentation == .notification(.charging), "latest alert wins")

        e.setLive(.lock, active: true, now: 30)
        check(e.compactPresentation == .lock, "lock has the highest priority")
        e.setLive(.lock, active: false, now: 31)
    }

    // MARK: Filters while focused
    do {
        var e = ActivityEngine()
        e.filters.allowedWhenFocused.remove(.battery)
        e.updateContext { $0.focusActive = true }
        check(e.post(.charging, duration: 5, now: 1) == .filtered, "battery alert filtered while focused")
        check(e.post(.focus, duration: 5, now: 1) == .shown, "Focus change itself is never filtered by the Focus filter")
        e.filters.allowedWhenFocused.remove(.travel)
        check(e.post(.timeToLeave, duration: 8, now: 3) == .shown, "time to leave always allowed")
    }

    // MARK: Dismiss / restore stack
    do {
        var e = ActivityEngine()
        e.setLive(.media, active: true, identity: "t", now: 1)
        e.setLive(.calendar, active: true, identity: "c", now: 2)
        check(e.dismissTopLiveActivity() == .calendar, "dismiss removes the most recently started activity first")
        check(e.compactPresentation == .live([.media]), "remaining activity stays")
        check(e.dismissTopLiveActivity() == .media && e.compactPresentation == .idle, "second dismissal empties the island")
        check(e.dismissTopLiveActivity() == nil, "nothing left to dismiss")
        e.setExpanded(true)
        e.setExpanded(false)
        check(e.compactPresentation == .live([.media, .calendar]), "dismissed activities restored on collapse")
        _ = e.dismissTopLiveActivity()
        e.setLive(.calendar, active: true, identity: "c2", now: 5)
        check(e.visibleLiveKinds.contains(.calendar), "a new instance of a dismissed activity shows again")
    }

    // MARK: Quick Peek
    do {
        var e = ActivityEngine()
        e.setLive(.calendar, active: true, identity: "c", now: 0)
        check(e.requestPeek(.media, userInitiated: false, now: 1), "media peek while another activity is shown")
        check(e.compactPresentation == .peek(.media), "peek presentation")
        check(e.nextDeadline == 3, "media peek lasts 2 s")
        _ = e.tick(now: 3)
        check(e.compactPresentation == .live([.calendar]), "peek ends")
        check(!e.requestPeek(.media, userInitiated: true, now: 4), "no peek for user-initiated changes")
        e.setLive(.calendar, active: false, now: 5)
        e.setLive(.media, active: true, identity: "m", now: 5)
        check(!e.requestPeek(.media, userInitiated: false, now: 6), "no media peek while Now Playing is already shown")
        e.setLive(.media, active: false, now: 6)
        check(e.requestPeek(.media, userInitiated: false, now: 7), "media peek while idle")
        check(e.post(.focus, duration: 5, now: 7.5) == .shown && e.peek == nil, "a notification cancels a running peek")
        _ = e.tick(now: 20)
        e.setExpanded(true)
        check(!e.requestPeek(.media, userInitiated: false, now: 21), "no peek while expanded")
        e.setExpanded(false)
        e.updateContext { $0.suppressLiveActivities = true }
        check(!e.requestPeek(.calendar, userInitiated: false, now: 22), "no peek in full screen")
        e.updateContext { $0.suppressLiveActivities = false }
        check(!e.requestPeek(.calendar, userInitiated: false, calendarTrigger: .beforeStart, now: 23),
              "calendar 'before start' peek off by default")
        check(e.requestPeek(.calendar, userInitiated: false, calendarTrigger: .atStart, now: 24) && e.nextDeadline == 28,
              "calendar 'at start' peek lasts 4 s")
    }

    // MARK: Full-screen suppression
    do {
        var e = ActivityEngine()
        e.setLive(.media, active: true, identity: "m", now: 0)
        e.updateContext { $0.suppressLiveActivities = true }
        check(e.compactPresentation == .idle, "live activities suppressed in full screen")
        check(e.post(.volume, duration: 1.5, now: 1) == .shown && e.compactPresentation == .notification(.volume),
              "notifications still show in full screen")
    }

    // MARK: Idle activity, Most Recent, cycling
    do {
        var e = ActivityEngine()
        e.shelfEnabled = false // the cycle with the Shelf page is checked in ShelfChecks
        e.idleContent = .nothing
        check(e.expandedContent == .nothing, "idle content honoured")
        e.setLive(.calendar, active: true, identity: "c", now: 0)
        e.setLive(.calendar, active: false, now: 1)
        check(e.expandedContent == .nothing, "without Most Recent the idle choice applies")
        e.followMostRecent = true
        check(e.expandedContent == .calendar, "Most Recent follows the last activity")
        e.setExpanded(true)
        e.cycleExpanded()
        check(e.expandedContent == .both, "cycle from Calendar goes to Both")
        e.cycleExpanded()
        check(e.expandedContent == .media, "cycle wraps to Media")
        e.setExpanded(false)
        check(e.expandedContent == .media, "cycle choice becomes the most recent")
    }

    // MARK: Presentation metrics (body widths measured, 185 × 33.5 pt notch)
    do {
        let base = CGSize(width: 185, height: 33.5)
        let ears = 2 * IslandMetrics.earRadius
        check(PresentationMetrics.compactSize(for: .live([.media]), base: base) == CGSize(width: 276, height: 34.5), "live 276 × 34.5 drawn")
        check(PresentationMetrics.compactSize(for: .live([.media]), base: base).width - ears == 260, "live body 260")
        check(PresentationMetrics.compactSize(for: .notification(.volume), base: base).width - ears == 369, "HUD body 369")
        check(PresentationMetrics.compactSize(for: .notification(.focus), base: base).width - ears == 260, "alert body 260")
        check(PresentationMetrics.compactSize(for: .idle, base: base) == base, "idle = notch")
        check(PresentationMetrics.expandedBodySize(for: .both).width == 345, "expanded body 345")
        check(PresentationMetrics.expandedSize(for: .calendar) == CGSize(width: 385, height: 175.5), "expanded calendar 385 × 175.5 with ears")
        check(PresentationMetrics.expandedSize(for: .media, withEars: false) == CGSize(width: 345, height: 175), "pill card has no ears")
    }

    // MARK: Swipes
    do {
        let compact = SwipeRecognizer.State(expanded: false, hasLiveActivity: true, hasMedia: true)
        let expanded = SwipeRecognizer.State(expanded: true, hasLiveActivity: true, hasMedia: true)
        var r = SwipeRecognizer()
        _ = r.began(state: compact)
        check(r.changed(dx: 0, dy: 30, state: compact).action == nil, "below 40 pt nothing fires")
        let open = r.changed(dx: 0, dy: 12, state: compact)
        check(open.action == .open && open.feedback == .thresholdCrossed, "swipe down 40 pt opens")
        check(r.changed(dx: 0, dy: 80, state: compact).action == nil, "one action per swipe")
        check(r.changed(dx: 0, dy: 0, state: compact).stretch.height == 12, "rubber band capped at 12 pt")
        _ = r.ended(state: compact)

        _ = r.began(state: compact)
        check(r.changed(dx: 0, dy: -45, state: compact).action == .dismiss, "swipe up on a live activity dismisses")
        _ = r.ended(state: compact)
        _ = r.began(state: SwipeRecognizer.State(expanded: false, hasLiveActivity: false, hasMedia: false))
        check(r.changed(dx: 0, dy: -45, state: SwipeRecognizer.State(expanded: false, hasLiveActivity: false, hasMedia: false)).action == nil,
              "nothing to dismiss")
        _ = r.cancelled()

        _ = r.began(state: expanded)
        check(r.changed(dx: 0, dy: -41, state: expanded).action == .close, "swipe up while expanded closes")
        _ = r.ended(state: expanded)

        _ = r.began(state: expanded)
        let armed = r.changed(dx: 0, dy: 55, state: expanded)
        check(armed.action == nil && armed.feedback == .thresholdCrossed, "cycle arms at 50 pt")
        check(r.ended(state: expanded).action == .cycle, "cycle fires on release")
        _ = r.began(state: expanded)
        _ = r.changed(dx: 0, dy: 55, state: expanded)
        _ = r.changed(dx: 0, dy: -20, state: expanded)
        check(r.ended(state: expanded).action == nil, "pulling back below the threshold disarms the cycle")

        _ = r.began(state: compact)
        check(r.changed(dx: 65, dy: 3, state: compact).action == .skipNext, "finger right → next")
        _ = r.ended(state: compact)
        r.config.naturalDirection = true
        _ = r.began(state: compact)
        check(r.changed(dx: 65, dy: 0, state: compact).action == .skipPrevious, "natural movement reverses skip")
        _ = r.ended(state: compact)
        _ = r.began(state: SwipeRecognizer.State(expanded: false, hasLiveActivity: false, hasMedia: false))
        check(r.changed(dx: 70, dy: 0, state: SwipeRecognizer.State(expanded: false, hasLiveActivity: false, hasMedia: false)).action == nil,
              "no skip without media")
        _ = r.cancelled()
        r.config.toggleEnabled = false
        _ = r.began(state: compact)
        check(r.changed(dx: 0, dy: 60, state: compact).action == nil, "toggle disabled by setting")
        _ = r.cancelled()

        check(SwipeRecognizer.fingerDelta(scrollingDeltaX: 3, scrollingDeltaY: 5, invertedFromDevice: true) == CGSize(width: 3, height: 5),
              "natural scrolling deltas already follow the finger")
        check(SwipeRecognizer.fingerDelta(scrollingDeltaX: 3, scrollingDeltaY: 5, invertedFromDevice: false) == CGSize(width: -3, height: -5),
              "classic scrolling deltas are inverted")
    }

    // MARK: Window environment (Mission Control, full screen)
    do {
        let display = DisplayRecord(id: 1, bounds: CGRect(x: 0, y: 0, width: 1710, height: 1107), menuBarHeight: 33.5)
        let menu = WindowRecord(ownerName: "Window Server", ownerPID: 10, layer: 24, bounds: CGRect(x: 0, y: 0, width: 1710, height: 34))
        let dock = WindowRecord(ownerName: "Dock", ownerPID: 20, layer: 20, bounds: display.bounds)
        let app = WindowRecord(ownerName: "Probe", ownerPID: 30, layer: 0, bounds: CGRect(x: 0, y: 34, width: 1710, height: 1073))
        let shield = WindowRecord(ownerName: "WindowManager", ownerPID: 40, layer: 19, bounds: display.bounds)
        check(WindowEnvironment.missionControlActive(windows: [menu, dock, shield], displays: [display]), "WindowManager shield → Mission Control")
        check(!WindowEnvironment.missionControlActive(windows: [menu, dock, app], displays: [display]), "no shield → no Mission Control")
        check(WindowEnvironment.fullScreenDisplays(windows: [menu, app], displays: [display], frontmostPID: 30) == [1],
              "no Dock layer + covering window → full screen")
        check(WindowEnvironment.fullScreenDisplays(windows: [menu, dock, app], displays: [display], frontmostPID: 30).isEmpty,
              "a zoomed window in a normal space is not full screen")
        check(WindowEnvironment.fullScreenDisplays(windows: [menu], displays: [display], frontmostPID: 30).isEmpty,
              "transition without a covering window is not full screen")
    }

    // MARK: Games, visibility, luminance
    check(GameClassifier.isGame(bundleID: "x", category: "public.app-category.games", bundlePath: nil), "games category")
    check(GameClassifier.isGame(bundleID: "x", category: "public.app-category.action-games", bundlePath: nil), "game sub-category")
    check(!GameClassifier.isGame(bundleID: "x", category: "public.app-category.productivity", bundlePath: "/Applications/X.app"), "not a game")
    check(GameClassifier.isGame(bundleID: "com.nvidia.gfnpc.mall", category: nil, bundlePath: nil), "known streaming client")
    check(GameClassifier.isGame(bundleID: nil, category: nil, bundlePath: "/Users/u/Library/Application Support/Steam/steamapps/common/G/G.app"),
          "Steam install path")
    check(IslandVisibility.resolve(fullScreen: true, missionControl: false, gaming: false,
                                   hideInFullScreen: true, hideInMissionControl: true, hideWhileGaming: false) == .liveActivitiesSuppressed,
          "full screen suppresses live activities")
    check(IslandVisibility.resolve(fullScreen: true, missionControl: true, gaming: false,
                                   hideInFullScreen: true, hideInMissionControl: true, hideWhileGaming: false) == .hidden,
          "Mission Control hides everything")
    check(IslandVisibility.resolve(fullScreen: false, missionControl: false, gaming: true,
                                   hideInFullScreen: true, hideInMissionControl: true, hideWhileGaming: false) == .visible,
          "gaming ignored when the setting is off")
    check(IslandVisibility.resolve(fullScreen: true, missionControl: true, gaming: true,
                                   hideInFullScreen: false, hideInMissionControl: false, hideWhileGaming: false) == .visible,
          "all rules off → visible")
    check(near(Luminance.relative(r: 1, g: 1, b: 1), 1) && Luminance.relative(r: 0, g: 0, b: 0) == 0, "luminance extremes")
    check(near(Luminance.relative(r: 0.5, g: 0.5, b: 0.5), 0.214, 0.001), "sRGB mid-grey ≈ 0.214")
    check(Luminance.shouldOutline(luminance: 0.2) && !Luminance.shouldOutline(luminance: 0.3), "outline below 0.25")
    check(near(Luminance.mean(rgba: [0, 0, 0, 255, 255, 255, 255, 255]), 0.5), "mean of black and white")
}
