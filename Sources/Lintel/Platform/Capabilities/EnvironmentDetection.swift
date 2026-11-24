import AppKit
import CoreGraphics
import LintelCore
import Observation

/// Detects native full-screen spaces per display (public window-list heuristic).
@MainActor
protocol FullScreenDetector: AnyObject {
    /// CoreGraphics IDs of displays currently showing a full-screen space.
    func fullScreenDisplays(on displays: [DisplayRecord]) -> Set<UInt32>
}

/// Detects Mission Control from its own windows (public window list; no log streaming):
/// whether its overlay and its Spaces bar are on screen.
@MainActor
protocol MissionControlDetector: AnyObject {
    var overlay: Bool { get }
    var bar: Bool { get }
    /// Called on every look (≈ 30 Hz while running).
    var onLook: ((_ overlay: Bool, _ bar: Bool) -> Void)? { get set }
    func setRunning(_ running: Bool)
}

/// Decides whether the frontmost app is a game (public app metadata).
@MainActor
protocol GameDetector: AnyObject {
    var frontmostIsGame: Bool { get }
    var frontmostBundleID: String? { get }
    var onChange: (() -> Void)? { get set }
}

/// One `CGWindowListCopyWindowInfo` snapshot per poll for the full-screen heuristic. Only owner,
/// PID, layer and bounds are read, so no Screen Recording permission is involved.
@MainActor
final class WindowListDetector: FullScreenDetector {
    private var windows: [WindowRecord] = []
    /// The frontmost app's PID, kept from activation notifications: asking `NSWorkspace` on every
    /// poll cost a synchronous round trip to Launch Services on the main thread.
    var frontmostPID: Int32? = NSWorkspace.shared.frontmostApplication?.processIdentifier

    func refresh() {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let ownPID = ProcessInfo.processInfo.processIdentifier
        windows = list.compactMap { info in
            guard let pid = info[kCGWindowOwnerPID as String] as? Int32, pid != ownPID,
                  let boundsInfo = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsInfo) else { return nil }
            return WindowRecord(ownerName: info[kCGWindowOwnerName as String] as? String ?? "",
                                ownerPID: pid,
                                layer: info[kCGWindowLayer as String] as? Int ?? 0,
                                bounds: bounds)
        }
    }

    func fullScreenDisplays(on displays: [DisplayRecord]) -> Set<UInt32> {
        WindowEnvironment.fullScreenDisplays(windows: windows, displays: displays, frontmostPID: frontmostPID)
    }
}

/// Classifies the frontmost app when it changes (`LSApplicationCategoryType`, known clients, paths).
@MainActor
final class WorkspaceGameDetector: GameDetector {
    private(set) var frontmostIsGame = false
    private(set) var frontmostBundleID: String?
    var onChange: (() -> Void)?
    private var cache: [String: Bool] = [:]
    private var observer: NSObjectProtocol?

    init() {
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { self?.evaluate(app) }
        }
        evaluate(NSWorkspace.shared.frontmostApplication)
    }

    private func evaluate(_ app: NSRunningApplication?) {
        let bundleID = app?.bundleIdentifier
        let path = app?.bundleURL?.path
        let key = path ?? bundleID ?? ""
        let isGame: Bool
        if let cached = cache[key] {
            isGame = cached
        } else {
            let category = app?.bundleURL.flatMap { Bundle(url: $0) }?.object(forInfoDictionaryKey: "LSApplicationCategoryType") as? String
            isGame = GameClassifier.isGame(bundleID: bundleID, category: category, bundlePath: path)
            cache[key] = isGame
        }
        let changed = isGame != frontmostIsGame || bundleID != frontmostBundleID
        frontmostIsGame = isGame
        frontmostBundleID = bundleID
        if changed { onChange?() }
    }
}

/// Combines the detectors. Full screen is looked for in bursts: from a trigger (a space change, an
/// app activation or quit, a display change, Mission Control leaving, wake or unlock) the window
/// list is polled at 4 Hz (one call costs ≈ 0.4–0.7 ms) until full screen has been seen the same on
/// two consecutive polls (space switches animate) and at least `settleWindow` has passed. A
/// full-screen space only comes or goes with a space change or an activation, so between bursts
/// nothing runs; the former steady 4 Hz poll woke Lintel four times a second for nothing.
/// Mission Control is watched separately at 30 Hz through window ids while the user is active
/// (`MissionControlWatcher`): hidden from its first frame until its Spaces bar has left.
@MainActor
@Observable
final class EnvironmentMonitor {
    private(set) var fullScreenDisplays: Set<UInt32> = []
    private(set) var missionControl = false
    private(set) var gaming = false
    private(set) var frontmostBundleID: String?
    private(set) var polls = 0
    /// Bursts started.
    private(set) var bursts = 0

    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored var displays: () -> [DisplayRecord] = { [] }

    @ObservationIgnored private let fullScreenDetector: FullScreenDetector
    @ObservationIgnored private let missionControlDetector: MissionControlDetector
    @ObservationIgnored private(set) var missionControlTracker = MissionControlTracker()
    @ObservationIgnored private let gameDetector: GameDetector
    @ObservationIgnored private let windowList: WindowListDetector?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var watching = false
    /// While true (displays asleep, session locked) no burst starts; one runs when it ends.
    @ObservationIgnored private var paused = false
    @ObservationIgnored private var burst = FullScreenBurst()
    @ObservationIgnored private var candidate: Set<UInt32> = []
    @ObservationIgnored private var candidateCount = 0
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init(windowList: WindowListDetector = WindowListDetector(), gameDetector: GameDetector = WorkspaceGameDetector(),
         missionControl: MissionControlDetector = MissionControlWatcher()) {
        self.windowList = windowList
        fullScreenDetector = windowList
        missionControlDetector = missionControl
        self.gameDetector = gameDetector
        gameDetector.onChange = { [weak self] in self?.gameChanged() }
        gaming = gameDetector.frontmostIsGame
        frontmostBundleID = gameDetector.frontmostBundleID
        missionControl.onLook = { [weak self] overlay, bar in self?.missionControlLooked(overlay: overlay, bar: bar) }
    }

    /// Watches Mission Control while "Hide during Mission Control" is on.
    func setMissionControlWatching(_ enabled: Bool) {
        missionControlDetector.setRunning(enabled)
        if !enabled, missionControlTracker.hidesIsland || missionControl {
            missionControlTracker = MissionControlTracker()
            missionControl = false
            onChange?()
        }
    }

    private func missionControlLooked(overlay: Bool, bar: Bool) {
        let seen = (overlay: overlay, bar: bar)
        missionControlTracker.update(overlay: seen.overlay, bar: seen.bar, at: ProcessInfo.processInfo.systemUptime)
        let hides = missionControlTracker.hidesIsland
        guard hides != missionControl else { return }
        missionControl = hides
        // Full screen is re-learned after Mission Control (its overlay hides the full-screen app).
        candidateCount = 0
        if !hides { startBurst() }
        onChange?()
    }

    /// Watches for full screen (in bursts, see the type's comment) while "Hide in full screen" is on.
    func setPolling(_ enabled: Bool) {
        if enabled, !watching {
            watching = true
            let center = NSWorkspace.shared.notificationCenter
            observers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil,
                                                queue: .main) { [weak self] note in
                let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
                MainActor.assumeIsolated {
                    if let pid { self?.windowList?.frontmostPID = pid }
                    self?.startBurst()
                }
            })
            for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didTerminateApplicationNotification] {
                observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.startBurst() }
                })
            }
            observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                    object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.startBurst() }
            })
            windowList?.frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
            startBurst()
        } else if !enabled, watching {
            watching = false
            stopBurst()
            for observer in observers {
                NSWorkspace.shared.notificationCenter.removeObserver(observer)
                NotificationCenter.default.removeObserver(observer)
            }
            observers.removeAll()
            let changed = !fullScreenDisplays.isEmpty
            fullScreenDisplays = []
            if changed { onChange?() }
        }
    }

    /// Displays asleep or session locked: nothing can go full screen unseen meanwhile, so no burst
    /// runs; one starts when they wake or unlock.
    func setPaused(_ paused: Bool) {
        guard paused != self.paused else { return }
        self.paused = paused
        if paused { stopBurst() } else { startBurst() }
    }

    /// Looks now and keeps looking at 4 Hz until the result has settled (`settleWindow` after the
    /// last trigger, and the same on two consecutive polls).
    func startBurst() {
        guard watching, !paused else { return }
        burst.trigger(now: ProcessInfo.processInfo.systemUptime)
        if timer == nil {
            bursts += 1
            let timer = Timer(timeInterval: FullScreenBurst.pollInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.burstTick() }
            }
            timer.tolerance = 0.05
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
        poll()
    }

    private func burstTick() {
        poll()
        let settled = candidateCount >= 2 && candidate == fullScreenDisplays
        if burst.ends(now: ProcessInfo.processInfo.systemUptime, settled: settled, missionControl: missionControl) { stopBurst() }
    }

    private func stopBurst() {
        timer?.invalidate()
        timer = nil
    }

    func poll() {
        polls += 1
        guard !missionControl else { return }
        windowList?.refresh()
        let full = fullScreenDetector.fullScreenDisplays(on: displays())
        if full == candidate {
            candidateCount += 1
        } else {
            candidate = full
            candidateCount = 1
        }
        if candidateCount >= 2, full != fullScreenDisplays {
            fullScreenDisplays = full
            onChange?()
        }
    }

    private func gameChanged() {
        gaming = gameDetector.frontmostIsGame
        frontmostBundleID = gameDetector.frontmostBundleID
        onChange?()
    }
}

/// Watches for Mission Control's own windows at 30 Hz, cheaply and off the main thread:
/// each look lists only the on-screen window ids
/// (`CGWindowListCreate`, resolved with `dlsym` because Swift doesn't import it) and asks for owner,
/// layer and bounds only of windows it hasn't seen before (`CGWindowListCreateDescriptionFromArray`).
/// Public API, no permission needed; measured ≈ 0.5 % of one core, the window server's load
/// unchanged. It runs on a utility-priority queue and wakes the main thread only while Mission
/// Control's windows are on screen or when they come or go, so detection lags Mission Control by at
/// most one look (≈ 33 ms) instead of the former 4 Hz poll's 250 ms.
///
/// Mission Control opens on the user's input (its keys, a trackpad swipe, a hot corner, its Dock
/// icon), so once nothing has been typed, pointed or touched for `MissionControlRest.restAfter`
/// seconds and its windows aren't up, the looks rest at one a second: an `InputWakeTap` brings back
/// 30 Hz on the next input event, before the window server acts on it, and the first look follows
/// at once — Mission Control is still seen from its first frame. Opened by a script without any
/// input (`open -a "Mission Control"`), it's seen by the next resting look, within a second.
/// Without the tap (no Accessibility) the looks never rest, as before.
@MainActor
final class MissionControlWatcher: MissionControlDetector {
    nonisolated static let interval = 1.0 / 30
    /// Mission Control's app (`open -a "Mission Control"`, Shortcuts, scripts).
    nonisolated static let missionControlLauncher = "com.apple.exposelauncher"

    private let poller: MissionControlPoller?
    private let wakeTap = InputWakeTap()
    private(set) var overlay = false
    private(set) var bar = false
    var onLook: ((_ overlay: Bool, _ bar: Bool) -> Void)?
    private var running = false
    /// Bumped whenever the watcher starts or stops: a look already on its way to the main thread
    /// when the watcher stopped (or restarted) is dropped, so it can't mark Mission Control shown
    /// after the pause reset it (the island would stay hidden after unlocking).
    private var generation = 0
    private var launchObservation: NSKeyValueObservation?
    private var launchObserver: NSObjectProtocol?

    init() {
        poller = MissionControlPoller()
        poller?.onState = { [weak self] generation, overlay, bar in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.running, generation == self.generation else { return }
                    self.overlay = overlay
                    self.bar = bar
                    self.onLook?(overlay, bar)
                }
            }
        }
        if let poller {
            let tap = wakeTap
            poller.restGate = { tap.arm() }
            tap.onInput = { [weak poller] in poller?.wake() }
        }
        // Mission Control's launcher (`open -a "Mission Control"`, Shortcuts, scripts) opens it without
        // any input. It's a background app that quits at once: both the launch notification and the
        // running-applications list are watched (a list change's new values aren't delivered through
        // Swift's key paths for insertions, so the list is looked through).
        launchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: nil
        ) { [weak poller] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            if app?.bundleIdentifier == Self.missionControlLauncher { poller?.wake() }
        }
        launchObservation = NSWorkspace.shared.observe(\.runningApplications, options: []) { [weak poller] workspace, _ in
            if workspace.runningApplications.contains(where: { $0.bundleIdentifier == Self.missionControlLauncher }) {
                poller?.wake()
            }
        }
    }

    var isAvailable: Bool { poller != nil }

    func setRunning(_ running: Bool) {
        guard running != self.running else { return }
        self.running = running
        generation += 1
        poller?.setRunning(running, interval: Self.interval, generation: generation)
        if !running {
            wakeTap.disarm()
            overlay = false; bar = false
        }
    }
}

/// An event tap that reports the next input event (keys, pointer, scroll, trackpad gestures; from
/// the hardware, or deliberate input a program posts: `MissionControlRest.wakes`) once, then
/// switches itself off: armed only while the Mission Control watcher rests, so
/// it sees no events while the user is active (it's off) and gets none while they're away. It sits
/// at the session level, where the Mission Control shortcuts and swipes pass before the system acts
/// on them, on its own thread (a busy main thread never holds input back), and passes every event
/// on unchanged. It needs Accessibility, checked without prompting; without it `arm()` fails and
/// the watcher keeps looking.
final class InputWakeTap: @unchecked Sendable {
    /// Called on the tap's thread for the first event after `arm()`.
    var onInput: (@Sendable () -> Void)?
    private let lock = NSLock()
    private var port: CFMachPort?
    private var armed = false
    private var arms = 0
    private var fires = 0
    private var failed = false
    private var lastFire = ""

    /// Switches the tap on (creating it the first time); false when it can't exist or can't see
    /// input (Accessibility revoked since: a tap would stay silent, so the watcher must keep looking).
    func arm() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard AccessibilityAccess.isTrusted else { return false }
        if port == nil, !failed { create() }
        guard let port, CFMachPortIsValid(port) else { return false }
        armed = true
        arms += 1
        CGEvent.tapEnable(tap: port, enable: true)
        return true
    }

    func disarm() {
        lock.lock()
        defer { lock.unlock() }
        armed = false
        if let port { CGEvent.tapEnable(tap: port, enable: false) }
    }

    var state: [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        return ["exists": port != nil, "armed": armed, "arms": arms, "fires": fires, "failed": failed, "lastFire": lastFire]
    }

    /// Called with the lock held.
    private func create() {
        // Checked without prompting; creating a tap without access could raise a system prompt.
        guard AccessibilityAccess.isTrusted else { return }
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: ~CGEventMask(0), callback: inputWakeTapCallback,
                                           userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            failed = true
            return
        }
        CGEvent.tapEnable(tap: port, enable: false)
        self.port = port
        let ready = DispatchSemaphore(value: 0)
        let handle = PortHandle(port: port)
        let thread = Thread {
            if let source = CFMachPortCreateRunLoopSource(nil, handle.port, 0) {
                CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            }
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "Lintel input wake tap"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
    }

    /// On the tap's thread: the first waking event switches the tap off (once: switching it off
    /// sends the callback a notice of its own) and wakes the watcher.
    fileprivate func fired(type: UInt32, source: Int64) {
        lock.lock()
        guard armed else {
            lock.unlock()
            return
        }
        armed = false
        if let port { CGEvent.tapEnable(tap: port, enable: false) }
        fires += 1
        lastFire = "type \(type) from \(source == 0 ? "hardware" : "pid \(source)")"
        lock.unlock()
        onInput?()
    }
}

/// The tap's port, handed to its thread (a CFMachPort is thread-safe).
private struct PortHandle: @unchecked Sendable {
    let port: CFMachPort
}

private let inputWakeTapCallback: CGEventTapCallBack = { _, type, event, refcon in
    let source = event.getIntegerValueField(.eventSourceUnixProcessID)
    if let refcon, MissionControlRest.wakes(eventType: type.rawValue, sourcePID: source) {
        Unmanaged<InputWakeTap>.fromOpaque(refcon).takeUnretainedValue().fired(type: type.rawValue, source: source)
    }
    return Unmanaged.passUnretained(event)
}

/// The watcher's looks, on their own queue.
final class MissionControlPoller: @unchecked Sendable {
    private typealias ListCreate = @convention(c) (UInt32, UInt32) -> Unmanaged<CFArray>?
    private let listCreate: ListCreate
    private let queue = DispatchQueue(label: "com.sashagilliard.lintel.missioncontrol", qos: .utility)
    private let lock = NSLock()
    // Touched only on `queue`.
    private var timer: DispatchSourceTimer?
    private var known: [CGWindowID: MissionControlWindow] = [:]
    private var ignored: Set<CGWindowID> = []
    private var onScreen: Set<CGWindowID> = []
    /// What the last look reported; nil after a start, so the first look always reports.
    private var last: (overlay: Bool, bar: Bool)?
    private var generation = 0
    private var interval = MissionControlWatcher.interval
    /// Running but not looking: no input for `restAfter` seconds (see `MissionControlWatcher`).
    private var resting = false
    private var looksSinceIdleCheck = 0
    // Read from the main thread under `lock`.
    private var looks = 0
    private var descriptions = 0
    private var spent = 0.0
    private var running = false
    private var rests = 0
    private var wakes = 0
    private var restingNow = false
    /// Called on the poller's queue when the state changes, and on every look while Mission Control's
    /// windows are on screen (the tracker's timeout needs time to pass).
    var onState: (@Sendable (_ generation: Int, _ overlay: Bool, _ bar: Bool) -> Void)?
    /// Asked on the poller's queue before resting: arms whatever wakes the looks on the next input
    /// and returns false when nothing can (then the looks go on).
    var restGate: (@Sendable () -> Bool)?

    init?() {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreate") else { return nil }
        listCreate = unsafeBitCast(symbol, to: ListCreate.self)
    }

    func setRunning(_ run: Bool, interval: Double, generation: Int) {
        queue.async { [self] in
            if run, timer == nil {
                known.removeAll(); ignored.removeAll(); onScreen.removeAll(); last = nil
                self.generation = generation
                self.interval = interval
                resting = false
                looksSinceIdleCheck = 0
                startTimer()
            } else if !run, timer != nil {
                timer?.cancel()
                timer = nil
                resting = false
                known.removeAll(); ignored.removeAll(); onScreen.removeAll(); last = nil
            }
            lock.lock(); running = timer != nil; restingNow = false; lock.unlock()
        }
    }

    /// The next input event (or Mission Control's launcher): look again at once, then at 30 Hz.
    func wake() {
        queue.async { [self] in wakeOnQueue() }
    }

    /// On `queue`.
    private func wakeOnQueue() {
        guard resting, let timer else { return }
        resting = false
        looksSinceIdleCheck = 0
        lock.lock(); wakes += 1; restingNow = false; lock.unlock()
        timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(4))
    }

    /// On `queue`.
    private func startTimer() {
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(4))
        source.setEventHandler { [weak self] in self?.look() }
        source.resume()
        timer = source
    }

    /// Seconds since the last keyboard, pointer or trackpad input (any event type).
    private static func secondsSinceInput() -> Double {
        guard let any = CGEventType(rawValue: ~0) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: any)
    }

    /// On `queue`, once a second: rests (one look a second) when the user has been away long enough
    /// and Mission Control's windows aren't up, provided something can wake the looks again. A
    /// resting look that finds them goes back to 30 Hz.
    private func restIfIdle(state: (overlay: Bool, bar: Bool)) {
        if resting {
            if state.overlay || state.bar || !known.isEmpty { wakeOnQueue() }
            return
        }
        looksSinceIdleCheck += 1
        guard looksSinceIdleCheck >= MissionControlRest.looksPerCheck else { return }
        looksSinceIdleCheck = 0
        guard let timer, MissionControlRest.shouldRest(secondsSinceInput: Self.secondsSinceInput(), overlay: state.overlay,
                                                       bar: state.bar, knownWindows: known.count),
              restGate?() == true else { return }
        let rest = MissionControlRest.restingInterval
        timer.schedule(deadline: .now() + rest, repeating: rest, leeway: .milliseconds(200))
        resting = true
        lock.lock(); rests += 1; restingNow = true; lock.unlock()
    }

    private func look() {
        let start = ProcessInfo.processInfo.systemUptime
        let options = CGWindowListOption([.optionOnScreenOnly, .excludeDesktopElements]).rawValue
        var current = Set<CGWindowID>()
        if let list = listCreate(options, 0)?.takeRetainedValue() {
            for index in 0..<CFArrayGetCount(list) {
                current.insert(CGWindowID(UInt(bitPattern: CFArrayGetValueAtIndex(list, index))))
            }
        }
        let new = current.subtracting(onScreen)
        var described = false
        if !new.isEmpty { described = describe(Array(new)) }
        onScreen = current
        if !known.isEmpty { known = known.filter { current.contains($0.key) } }
        ignored.formIntersection(current)
        let state = (overlay: known.values.contains(.overlay), bar: known.values.contains(.bar))
        lock.lock()
        looks += 1
        if described { descriptions += 1 }
        spent += ProcessInfo.processInfo.systemUptime - start
        lock.unlock()
        if last.map({ $0 != state }) ?? true || state.overlay || state.bar {
            last = state
            onState?(generation, state.overlay, state.bar)
        }
        restIfIdle(state: state)
    }

    /// Owner, layer and bounds of windows not seen before; true when any were asked for.
    private func describe(_ ids: [CGWindowID]) -> Bool {
        let fresh = ids.filter { !ignored.contains($0) && known[$0] == nil }
        guard !fresh.isEmpty else { return false }
        var values = fresh.map { UnsafeRawPointer(bitPattern: UInt($0)) }
        guard let array = CFArrayCreate(nil, &values, values.count, nil),
              let infos = CGWindowListCreateDescriptionFromArray(array) as? [[String: Any]] else { return true }
        let screens = Self.displays()
        for info in infos {
            guard let number = info[kCGWindowNumber as String] as? Int else { continue }
            let id = CGWindowID(number)
            let bounds = (info[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) } ?? .zero
            if let kind = MissionControlWindow.classify(owner: info[kCGWindowOwnerName as String] as? String ?? "",
                                                        layer: info[kCGWindowLayer as String] as? Int ?? 0,
                                                        bounds: bounds, displays: screens) {
                known[id] = kind
            } else {
                ignored.insert(id)
            }
        }
        return true
    }

    /// Display bounds in CoreGraphics global coordinates (CoreGraphics is safe off the main thread).
    private static func displays() -> [CGRect] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).map { CGDisplayBounds($0) }
    }

    var stats: [String: Any] {
        lock.lock(); defer { lock.unlock() }
        return ["running": running, "available": true, "looks": looks, "descriptions": descriptions,
                "meanLookMs": looks > 0 ? spent / Double(looks) * 1000 : 0, "thread": "utility queue",
                "rests": rests, "wakes": wakes, "resting": restingNow]
    }
}
