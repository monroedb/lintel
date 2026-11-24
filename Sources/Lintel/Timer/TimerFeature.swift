import AppKit
import AVFoundation
import LintelCore
import os

extension Log {
    static let timer = Logger(subsystem: subsystem, category: "timer")
}

/// Lintel's timer: runs `TimerMachine`, keeps it in `timer.state`,
/// rings, opens the island for the alert, and handles `lintel://timer…` links. One per app; menus
/// and Settings reach it through `shared`, island views through `hub.timer`.
@MainActor
final class TimerFeature {
    private(set) static var shared: TimerFeature?
    /// Links that arrive before the timer is restored (a link that launched Lintel).
    private static var pendingURLs: [URL] = []

    let settings: SettingsStore
    let hub: ActivityHub
    var center: TimerCenter { hub.timer }
    private(set) var machine = TimerMachine()
    private(set) weak var coordinator: DisplayCoordinator?
    let sound = TimerSoundPlayer()
    let entry = TimerEntryWindow()
    private var deadlineTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    /// Keyboard for the Ruler picker.
    private(set) var keyboard: TimerRulerKeyboard?
    /// Island (screen UUID) that Lintel opened for the alert; closed again when the alert ends.
    private(set) var autoOpenedScreen: String?
    private(set) var started = false
    /// Recent links, actions and events (uptime-stamped).
    private(set) var log: [String] = []
    private(set) var haptics = 0

    init(settings: SettingsStore, hub: ActivityHub) {
        self.settings = settings
        self.hub = hub
        Self.shared = self
    }

    /// Call after the display coordinator has started (the islands exist).
    func start(coordinator: DisplayCoordinator) {
        guard !started else { return }
        self.coordinator = coordinator
        center.onAction = { [weak self] action in self?.perform(action) }
        center.onLiveChange = { [weak self] identity in
            self?.hub.onEvent?(.live(.timer, active: identity != nil, identity: identity ?? ""))
        }
        entry.onStart = { [weak self] seconds in self?.startCustom(seconds) }
        observe()
        publishPicker()
        machine.repeats = settings[Keys.timerRepeatAlert]
        restore(now: Date())
        if !settings[Keys.timerEnabled], machine.state != nil { mutate { $0.cancel() } }
        started = true
        applyEnabled()
        let keyboard = TimerRulerKeyboard(feature: self)
        keyboard.start()
        self.keyboard = keyboard
        let pending = Self.pendingURLs
        Self.pendingURLs = []
        pending.forEach(handle)
    }

    // MARK: Actions

    func perform(_ action: TimerCenter.Action) {
        guard settings[Keys.timerEnabled] || action == .cancel else {
            record("ignored \(action): Timers are off")
            return
        }
        record("action \(action)")
        let wasEnded = machine.state?.isFinished == true
        let now = Date()
        switch action {
        case .start(let seconds): mutate { $0.start(seconds: seconds, now: now) }
        case .pause: mutate { $0.pause(now: now) }
        case .resume: mutate { $0.resume(now: now) }
        case .togglePause: mutate { $0.togglePause(now: now) }
        case .add(let seconds): mutate { $0.add(seconds: seconds, now: now) }
        case .restart: mutate { $0.restart(now: now) }
        case .cancel: mutate { $0.cancel() }
        case .custom: showEntry()
        case .pick(let minutes):
            // The picker opens here next time; presets above 2 h don't move it.
            if TimerRulerScale().contains(minutes) {
                settings[Keys.timerRulerLastMinutes] = minutes
                publishPicker()
            }
            mutate { $0.start(seconds: Double(minutes) * 60, now: now) }
        }
        if wasEnded, machine.state?.isFinished != true {
            // Stop, +1 min, Restart or a new timer ended the alert.
            sound.stop()
            closeAutoOpenedIsland()
        }
        keyboard?.update()
    }

    /// Picker style, quick presets and the ruler's last used minutes for the views and menus.
    private func publishPicker() {
        let scale = TimerRulerScale()
        center.publishPicker(style: settings[Keys.timerPickerStyle], presets: settings[Keys.timerPresets].minutes,
                             rulerMinutes: scale.clamp(settings[Keys.timerRulerLastMinutes]))
    }

    private func startCustom(_ seconds: Double) {
        settings[Keys.timerLastCustomSeconds] = seconds
        perform(.start(seconds: seconds))
    }

    // MARK: Links

    /// Entry point for `application(_:open:)`; links wait until the timer is restored.
    static func open(_ urls: [URL]) {
        guard let shared, shared.started else {
            pendingURLs += urls
            return
        }
        urls.forEach(shared.handle)
    }

    func handle(_ url: URL) {
        let text = url.absoluteString
        switch TimerURLCommand.parse(url) {
        case .failure(let failure):
            Log.timer.notice("Ignored link \(text, privacy: .public): \(failure.description, privacy: .public)")
            record("link ignored (\(failure.description)): \(text)")
        case .success(let command):
            guard settings[Keys.timerEnabled] else {
                Log.timer.notice("Ignored link \(text, privacy: .public): Timers are switched off")
                record("link ignored (Timers are off): \(text)")
                return
            }
            Log.timer.info("Link \(text, privacy: .public)")
            record("link \(text)")
            switch command {
            case .start(let seconds): perform(.start(seconds: seconds))
            case .pause: perform(.pause)
            case .resume: perform(.resume)
            case .restart: perform(.restart)
            case .add(let seconds): perform(.add(seconds: seconds))
            case .cancel: perform(.cancel)
            }
        }
    }

    // MARK: Machine

    private func mutate(_ body: (inout TimerMachine) -> Void) {
        let previous = machine.state
        body(&machine)
        commit(machine.advance(now: Date()), previous: previous)
    }

    /// Stores and publishes the new state, then acts on the events (the islands already know about
    /// the change when the alert opens one).
    private func commit(_ events: [TimerEvent], previous: TimerState?) {
        if machine.state != previous { persist() }
        if previous != nil, machine.state == nil { keepTimerPageOpen() }
        center.publish(state: machine.state, alert: machine.alert, enabled: settings[Keys.timerEnabled])
        events.forEach(apply)
        schedule()
    }

    private func apply(_ event: TimerEvent) {
        record("event \(event)")
        switch event {
        case .alertStarted(let late):
            Log.timer.info("Timer ended (\(late, format: .fixed(precision: 1)) s late); alert starts")
            openIslandForAlert()
        case .missed(let late):
            Log.timer.info("Timer ended \(late, format: .fixed(precision: 0)) s ago; shown as done without a sound")
        case .ring:
            if settings[Keys.timerSound] { sound.play() }
            haptics += 1
            coordinator?.haptics.perform(.generic)
            center.rang()
            forgetAutoOpenedIslandIfClosed()
        case .silenced, .cleared:
            closeAutoOpenedIsland()
        case .forgotten:
            break
        }
    }

    /// One task to the next deadline; nothing polls. The continuous clock keeps counting through
    /// sleep; wake and clock changes re-check.
    private func schedule() {
        deadlineTask?.cancel()
        guard let deadline = machine.nextDeadline() else { return }
        let delay = max(0, deadline.timeIntervalSinceNow)
        deadlineTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay), tolerance: .milliseconds(10))
            guard !Task.isCancelled else { return }
            self?.tick()
        }
    }

    func tick() { mutate { _ in } }

    // MARK: Persistence

    private func persist() {
        if let json = machine.snapshot?.json {
            settings[Keys.timerState] = json
        } else if settings.hasValue(for: Keys.timerState) {
            settings.reset(Keys.timerState)
        }
    }

    /// Restores `timer.state` through the launch rules.
    func restore(now: Date) {
        let stored = settings[Keys.timerState]
        let snapshot = stored.flatMap(TimerSnapshot.decode)
        if stored != nil, snapshot?.state == nil {
            Log.timer.notice("Dropped an unreadable stored timer")
            settings.reset(Keys.timerState)
        }
        let previous = snapshot?.state
        let events = machine.restore(snapshot, now: now)
        if let state = machine.state { record("restored \(state.phase)") }
        commit(events, previous: previous)
    }

    // MARK: Settings and system events

    private func observe() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .lintelSettingDidChange, object: nil, queue: .main) { [weak self] note in
            let key = note.userInfo?["key"] as? String ?? "*"
            MainActor.assumeIsolated { self?.settingDidChange(key) }
        })
        observers.append(center.addObserver(forName: .NSSystemClockDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        })
        workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        })
    }

    private func settingDidChange(_ key: String) {
        let all = key == "*"
        guard all || key.hasPrefix(Keys.timerKeyPrefix), key != Keys.timerState.name,
              key != Keys.timerLastCustomSeconds.name else { return }
        if all || [Keys.timerPickerStyle.name, Keys.timerPresets.name, Keys.timerRulerLastMinutes.name].contains(key) {
            publishPicker()
            keyboard?.update()
            if !all { return }
        }
        machine.repeats = settings[Keys.timerRepeatAlert]
        if all || key == Keys.timerEnabled.name {
            if !settings[Keys.timerEnabled], machine.state != nil {
                record("Timers switched off: timer cancelled")
                sound.stop()
                closeAutoOpenedIsland()
                mutate { $0.cancel() }
            }
            applyEnabled()
        }
    }

    /// The timer page in the cycle, the idle-choice fallback, the menu-bar item and the views.
    private func applyEnabled() {
        let enabled = settings[Keys.timerEnabled]
        coordinator?.controllers.values.forEach { $0.applyActivitySettings() }
        TimerMenu.setStatusItemsVisible(enabled)
        center.publish(state: machine.state, alert: machine.alert, enabled: enabled)
        if !enabled { entry.close() }
    }

    // MARK: Opening the island for the alert

    private func openIslandForAlert() {
        guard settings[Keys.timerOpenOnFinish], let island = islandUnderPointer() else { return }
        guard island.visibility != .hidden else {
            record("alert: island hidden, not opened")
            return
        }
        guard island.model.phase != .expanded else {
            // Already open (perhaps on a page the user cycled to): show the alert there.
            island.activity.mutate { $0.keepExpanded(.timer) }
            return
        }
        island.performOpen()
        autoOpenedScreen = island.plan.screenUUID
    }

    /// The island on the display under the pointer, else the main display's, else any.
    func islandUnderPointer() -> IslandController? {
        guard let coordinator else { return nil }
        let pointer = NSEvent.mouseLocation
        let islands = coordinator.controllers.values.sorted { $0.plan.screenUUID < $1.plan.screenUUID }
        func screen(_ island: IslandController) -> NSScreen? { NSScreen.screens.first { $0.displayUUID == island.plan.screenUUID } }
        return islands.first { screen($0)?.frame.insetBy(dx: -1, dy: -1).contains(pointer) == true }
            ?? islands.first { screen($0) == NSScreen.main }
            ?? islands.first
    }

    private func closeAutoOpenedIsland() {
        guard let uuid = autoOpenedScreen else { return }
        autoOpenedScreen = nil
        guard let island = coordinator?.controllers[uuid], island.model.phase == .expanded, !island.pointerInside else { return }
        island.performClose()
    }

    /// An open card showing the timer page keeps it (with the presets) when the timer goes away,
    /// instead of jumping to the idle choice under the pointer.
    private func keepTimerPageOpen() {
        guard let islands = coordinator?.controllers.values else { return }
        for island in islands where island.model.phase == .expanded && island.model.expandedContent == .timer {
            island.activity.mutate { $0.keepExpanded(.timer) }
        }
    }

    /// Once the user has let the card close, a later close must not shut a card they opened again.
    private func forgetAutoOpenedIslandIfClosed() {
        guard let uuid = autoOpenedScreen else { return }
        if coordinator?.controllers[uuid]?.model.phase != .expanded { autoOpenedScreen = nil }
    }

    // MARK: Custom duration

    func showEntry() {
        let screen = islandUnderPointer().flatMap { island in NSScreen.screens.first { $0.displayUUID == island.plan.screenUUID } }
            ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        entry.show(on: screen, prefill: TimerFormat.entryText(settings[Keys.timerLastCustomSeconds]))
    }

    // MARK: Log

    func record(_ line: String) {
        log.append(String(format: "%.3f ", ProcessInfo.processInfo.systemUptime) + line)
        if log.count > 40 { log.removeFirst(log.count - 40) }
    }
}

/// Plays the timer cue: rendered once off the main thread, played on a serial queue so a ring never
/// delays the island's animations; several can overlap. `stop()` cuts a ring short (Stop pressed).
@MainActor
final class TimerSoundPlayer {
    private let rendering: Task<Data, Never>
    private let output = TimerSoundOutput()
    /// Rings played, with uptime.
    private(set) var log: [String] = []

    init() {
        rendering = Task.detached(priority: .utility) { TimerSound.wav() }
    }

    func play() {
        log.append(String(format: "%.3f ring", ProcessInfo.processInfo.systemUptime))
        if log.count > 50 { log.removeFirst(log.count - 50) }
        let rendering = self.rendering
        let output = self.output
        Task.detached(priority: .userInitiated) { @Sendable in
            output.play(await rendering.value)
        }
    }

    func stop() { output.stop() }
}

/// Owns the active players on its own queue (no delegate: `AVAudioPlayerDelegate` is main-actor
/// isolated in the macOS 27 SDK; see `TonePlayer`).
private final class TimerSoundOutput: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.sashagilliard.lintel.timer-sound")
    private var active: [AVAudioPlayer] = []

    func play(_ data: Data) {
        queue.async { @Sendable in
            self.active.removeAll { !$0.isPlaying }
            guard let player = try? AVAudioPlayer(data: data, fileTypeHint: AVFileType.wav.rawValue) else { return }
            player.volume = 0.8
            self.active.append(player)
            player.play()
        }
    }

    func stop() {
        queue.async { @Sendable in
            self.active.forEach { $0.stop() }
            self.active.removeAll()
        }
    }
}
