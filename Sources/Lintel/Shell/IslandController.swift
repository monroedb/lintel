import AppKit
import LintelCore
import SwiftUI

/// Actions offered by the island's context menu.
struct IslandMenuActions {
    var openSettings: () -> Void
    var quit: () -> Void
    /// Items for the region that was right-clicked (calendar events), built before the click
    /// expands the island.
    var regionItems: ((IslandController, NSEvent) -> [NSMenuItem])? = nil
}

/// Hosting view that forwards clicks to the controller and accepts the first click without
/// activating the app.
final class IslandHostingView: NSHostingView<IslandView> {
    var onPrimaryClick: (() -> Void)?
    var onSecondaryClick: ((NSEvent) -> Void)?
    var onOtherClick: ((NSEvent) -> Void)?

    required init(rootView: IslandView) { super.init(rootView: rootView) }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("not used") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        onPrimaryClick?()
        super.mouseDown(with: event)
    }

    override func rightMouseDown(with event: NSEvent) { onSecondaryClick?(event) }
    override func otherMouseDown(with event: NSEvent) { onOtherClick?(event) }
}

/// Owns one display's island: two panels, the view model, the interaction state machine and the
/// activity engine for this display.
@MainActor
final class IslandController {
    private(set) var plan: IslandPlan
    let model: IslandModel
    let activity: IslandActivity
    var menuActions: IslandMenuActions?
    private(set) var visibility: IslandVisibility = .visible
    /// Backdrop luminance in use (nil = unknown).
    private(set) var luminance: Double?

    let settings: SettingsStore
    let hub: ActivityHub
    let haptics: Haptics
    private let contentPanel: IslandPanel
    private let backdropPanel: IslandPanel
    private let hostingView: IslandHostingView
    private let backdrop: BackdropBlur
    private(set) var interaction = IslandInteraction()
    private var expandTask: Task<Void, Never>?
    private var collapseTask: Task<Void, Never>?
    private var contentTask: Task<Void, Never>?
    // Swaps: a debounce collapses bursts into one transition; the token drops stale steps.
    private var swapDebounce: Task<Void, Never>?
    private var swapTask: Task<Void, Never>?
    private(set) var swapToken = 0
    private(set) var swapLog: [String] = []
    // Gestures
    var swipe = SwipeRecognizer()
    private(set) var swipeInProgress = false

    init(plan: IslandPlan, settings: SettingsStore, hub: ActivityHub, haptics: Haptics) {
        self.plan = plan
        self.settings = settings
        self.hub = hub
        self.haptics = haptics
        model = IslandModel(plan: plan)
        model.forceVisibleWhenIdle = settings[Keys.debugShowIdlePill]
        activity = IslandActivity(settings: settings)
        contentPanel = IslandPanel(frame: plan.canvas, role: .content)
        backdropPanel = IslandPanel(frame: plan.canvas, role: .backdrop)
        hostingView = IslandHostingView(rootView: IslandView(model: model, hub: hub))
        hostingView.frame = NSRect(origin: .zero, size: plan.canvas.size)
        hostingView.wantsLayer = true // the Mission Control tuck masks its layer
        contentPanel.contentView = hostingView
        let backdropView = NSView(frame: NSRect(origin: .zero, size: plan.canvas.size))
        backdropPanel.contentView = backdropView
        backdrop = BackdropBlur(container: backdropView)

        hostingView.onPrimaryClick = { [weak self] in self?.handlePrimaryClick() }
        hostingView.onSecondaryClick = { [weak self] event in self?.handleSecondaryClick(event) }
        hostingView.onOtherClick = { [weak self] event in
            if event.buttonNumber == 2 { self?.handleMiddleClick() }
        }
        activity.onChange = { [weak self] in self?.activityChanged() }
        activity.seed(from: hub)
        wireTimerRuler()
        model.expandedContent = activity.engine.expandedContent

        applySharingType()
        backdropPanel.orderFrontRegardless()
        contentPanel.orderFrontRegardless()
        ShelfDropCatcher.install(in: contentPanel, hosting: hostingView, island: self) // Shelf: drops on the island
        trackMediaWaveform()
    }

    // MARK: On screen

    private var screensQuiet = false

    /// The displays sleep or the session is locked (DisplayCoordinator).
    func setScreensQuiet(_ quiet: Bool) {
        screensQuiet = quiet
        updateOnScreen()
    }

    /// Hidden only while Mission Control is shown (a few seconds): not "off screen", since pausing
    /// and resuming around each visit costs more than it saves (it doubled the island's renders in
    /// a run of 19 Mission Control visits).
    private var hiddenForMissionControl = false

    private func updateOnScreen() {
        let onScreen = (visibility != .hidden || hiddenForMissionControl) && !screensQuiet
        if model.onScreen != onScreen { model.onScreen = onScreen }
    }

    /// Whether this island shows a media waveform now: the compact one (Now Playing alone in the
    /// compact slots, or its Quick Peek) or the open player's. The live waveform's audio tap runs
    /// only while some island does.
    private var showsMediaWaveform: Bool {
        MediaWaveformDemand.shows(onScreen: model.onScreen, tucked: model.tucked, expanded: model.phase == .expanded,
                                  expandedContent: model.expandedContent, displayed: model.displayed,
                                  focusGlyphReplaces: hub.focusGlyphForWaveform != nil,
                                  compactWaveform: hub.nowPlaying.appearance.compactWaveform)
    }

    private var reportedWaveform: Bool?

    /// Reports `showsMediaWaveform` to Now Playing whenever what it reads changes.
    private func trackMediaWaveform() {
        let shown = withObservationTracking { showsMediaWaveform } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.trackMediaWaveform() }
        }
        guard shown != reportedWaveform else { return }
        reportedWaveform = shown
        hub.nowPlaying.setWaveformShown(shown, island: plan.screenUUID)
    }

    // MARK: Timer Ruler picker

    /// The open card shows the Ruler picker (timer page, no timer, Ruler style).
    var rulerShown: Bool {
        interaction.phase == .expanded && model.expandedContent == .timer && hub.timer.showsRuler
    }

    private func wireTimerRuler() {
        let ruler = model.timerRuler
        ruler.onTick = { [weak self] tick in self?.haptics.tick(strong: tick == .five) }
        ruler.onStart = { [weak self] minutes in self?.hub.timer.perform(.pick(minutes: minutes)) }
        ruler.screen = { [weak self] in
            guard let uuid = self?.plan.screenUUID else { return NSScreen.main }
            return NSScreen.screens.first { $0.displayUUID == uuid } ?? NSScreen.main
        }
        ruler.reset(to: hub.timer.rulerMinutes)
    }

    /// Scroll events while the ruler shows: wheels scrub; a trackpad gesture is the ruler's when its
    /// first 8 pt are mostly horizontal (with its momentum events), else the island's swipes get it.
    private func handleRulerScroll(_ event: NSEvent) -> Bool {
        let ruler = model.timerRuler
        if event.phase.isEmpty, event.momentumPhase.isEmpty {
            if event.hasPreciseScrollingDeltas {
                let delta = abs(event.scrollingDeltaX) >= abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
                ruler.smoothScroll(delta: delta)
            } else {
                ruler.wheel(steps: RulerInput.wheelSteps(deltaX: Double(event.scrollingDeltaX), deltaY: Double(event.scrollingDeltaY)))
            }
            return true
        }
        // The system's momentum after a gesture: the ruler runs its own, so it absorbs these.
        if !event.momentumPhase.isEmpty { return ruler.router.lastOwner == .ruler }
        let phase = event.phase
        if phase.contains(.mayBegin) {
            ruler.touch() // a finger rests: the ruler stops where it is
            return true
        }
        if phase.contains(.began) {
            ruler.router.began()
            ruler.touch()
        }
        switch ruler.router.changed(dx: event.scrollingDeltaX, dy: event.scrollingDeltaY) {
        case .wait:
            break
        case .ruler(let dx):
            ruler.scroll(deltaX: dx)
        case .island(let dx, let dy):
            let finger = SwipeRecognizer.fingerDelta(scrollingDeltaX: dx, scrollingDeltaY: dy,
                                                     invertedFromDevice: event.isDirectionInvertedFromDevice)
            if !swipeInProgress { feedSwipe(.began) }
            feedSwipe(.changed(finger))
        }
        if phase.contains(.ended) || phase.contains(.cancelled) {
            let cancelled = phase.contains(.cancelled)
            if ruler.router.ended() == .island { feedSwipe(cancelled ? .cancelled : .ended) }
            ruler.release(cancelled: cancelled || ruler.router.lastOwner != .ruler)
        }
        return true
    }

    // MARK: Plan and settings

    func update(plan newPlan: IslandPlan) {
        guard newPlan != plan else { return }
        plan = newPlan
        model.plan = newPlan
        contentPanel.setFrame(newPlan.canvas, display: true)
        backdropPanel.setFrame(newPlan.canvas, display: true)
        updateBackdrop()
    }

    /// Both panels, backdrop first (for the window-server space).
    var panels: [NSWindow] { [backdropPanel, contentPanel] }

    func applySharingType() {
        let sharing: NSWindow.SharingType = settings[Keys.hideFromScreenCapture] ? .none : .readOnly
        contentPanel.sharingType = sharing
        backdropPanel.sharingType = sharing
    }

    func refreshDebugFlags() {
        model.forceVisibleWhenIdle = settings[Keys.debugShowIdlePill]
    }

    func applyActivitySettings() {
        activity.applySettings()
    }

    /// Contrast outline: shown when the backdrop is dark, or always when it can't be measured.
    func applyOutline(luminance sampled: Double?) {
        luminance = sampled
        let show = settings[Keys.contrastOutline] && (luminance.map(Luminance.shouldOutline) ?? true)
        if model.showsOutline != show {
            withAnimation(.easeInOut(duration: 0.2)) { model.showsOutline = show }
        }
    }

    func close() {
        expandTask?.cancel(); collapseTask?.cancel(); contentTask?.cancel()
        swapDebounce?.cancel(); swapTask?.cancel()
        activity.cancel()
        hub.nowPlaying.setPlayerOpen(false, island: plan.screenUUID)
        hub.nowPlaying.setWaveformShown(false, island: plan.screenUUID)
        reportedWaveform = false
        contentPanel.orderOut(nil)
        backdropPanel.orderOut(nil)
        contentPanel.close()
        backdropPanel.close()
    }

    private var config: InteractionConfig {
        InteractionConfig(expandOnHover: settings[Keys.expandOnHover], hoverDelay: settings[Keys.hoverDelay])
    }

    // MARK: Visibility (hiding rules)

    /// Applies the hiding rules. `tuck`: hidden because Mission Control is shown and "Animate with
    /// Mission Control" is on — the island tucks into the notch instead of disappearing at once, and
    /// grows back out of it when it may show again.
    func apply(visibility newValue: IslandVisibility, tuck: Bool = false, byMissionControl: Bool = false) {
        let tuckNow = newValue == .hidden && tuck
        let wasForMissionControl = hiddenForMissionControl
        hiddenForMissionControl = newValue == .hidden && byMissionControl
        if wasForMissionControl != hiddenForMissionControl { updateOnScreen() }
        guard newValue != visibility || tuckNow != tuckedForMissionControl else { return }
        let wasHidden = visibility == .hidden
        let wasTucked = tuckedForMissionControl
        visibility = newValue
        tuckedForMissionControl = tuckNow
        updateOnScreen()
        activity.mutate { engine in
            engine.updateContext { $0.suppressLiveActivities = newValue == .liveActivitiesSuppressed }
        }
        if newValue == .hidden {
            let before = interaction.phase
            interaction.reset()
            expandTask?.cancel(); collapseTask?.cancel()
            if tuckNow, !wasHidden || wasTucked {
                tuckIntoNotch(from: before)
            } else if tuckNow {
                // Already hidden by another rule: tuck without showing anything.
                render(from: before)
                setTucked(true)
            } else {
                if wasTucked { setTucked(false) }
                render(from: before)
                fadePanels(to: 0, duration: 0.12)
            }
        } else if wasHidden {
            if model.tucked { growOutOfNotch() } else { fadePanels(to: 1, duration: 0.2) }
        }
        updateMouseInteractivity()
    }

    // MARK: Mission Control

    /// Tucked into the notch because of Mission Control (and the panels hidden once it got there).
    private(set) var tuckedForMissionControl = false
    /// Bumped by every tuck and grow, so a superseded step never runs.
    private(set) var tuckToken = 0
    private var tuckTask: Task<Void, Never>?
    /// Tuck and grow steps with their uptime.
    private(set) var tuckLog: [String] = []

    /// Shrinks the island into the notch's exact shape (or the pill) while its content fades, timed
    /// with Mission Control's zoom-out; once it is there the panels are hidden (no visible change
    /// behind the notch). From any state: compact, an activity, a notification or the open card.
    private func tuckIntoNotch(from before: IslandPhase) {
        tuckToken &+= 1
        let token = tuckToken
        tuckTask?.cancel()
        contentTask?.cancel()
        // The outline it starts from, read before anything changes (the open card, the hovered shape…).
        let from = silhouette(size: model.drawnSize, bottom: model.bottomCornerRadius, ear: model.earRadius,
                              top: model.topCornerRadius)
        logTuck("tuck from \(before.rawValue) \(model.drawnSize.width)x\(model.drawnSize.height)")
        render(from: before) // leaves the open card; the tuck below supersedes its spring
        withAnimation(.easeIn(duration: MissionControlTiming.contentFadeOut)) { model.contentTucked = true }
        withAnimation(MissionControlTiming.tuckAnimation) { model.tucked = true }
        // The same motion as a Core Animation mask the window server runs by itself, anchored to now:
        // when Mission Control's cold start holds back the app's frames, the island still shrinks (or,
        // if even this arrives late, it is already in the notch instead of shrinking late).
        animateTuckMask(from: from, to: tuckSilhouette, response: MissionControlTiming.tuckResponse,
                        damping: MissionControlTiming.tuckDamping) { [weak self] in
            guard let self, self.tuckToken == token, self.model.tucked else { return }
            self.fadePanels(to: 0, duration: 0)
            self.logTuck("tucked, panels hidden")
        }
        if plan.tuckHiddenByHardware {
            // The window fades late (see windowFadeDelay): unseen normally, smooth if drawing is frozen.
            tuckTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(MissionControlTiming.windowFadeDelay))
                guard !Task.isCancelled, let self, self.tuckToken == token else { return }
                self.fadePanels(to: 0, duration: MissionControlTiming.windowFadeDuration)
            }
        } else {
            // Nothing hides a tucked pill: the window fades out with the tuck.
            fadePanels(to: 0, duration: MissionControlTiming.tuckDuration)
        }
        updateBackdrop()
    }

    /// Grows the island back out of the notch to whatever it should show now, with the expand
    /// spring; the content fades in once the shape has mostly grown (as when the card opens).
    private func growOutOfNotch() {
        tuckToken &+= 1
        let token = tuckToken
        tuckTask?.cancel()
        // Show what is current now, without the swap animation (it changed while hidden).
        cancelSwap()
        let target = activity.engine.compactPresentation
        model.displayed = target
        model.shapePresentation = target
        model.compactContentVisible = true
        fadePanels(to: 1, duration: plan.tuckHiddenByHardware ? 0 : MissionControlTiming.untuckFadeIn)
        logTuck("grow to \(String(describing: target))")
        if let mask = tuckMask, mask.animation(forKey: "tuck") != nil {
            // Mission Control left while the island was still tucking in: the mask turns round too.
            let size = model.size(for: .idle)
            let to = silhouette(size: size, bottom: plan.shape == .pill ? min(size.height / 2, IslandMetrics.expandedCornerRadius)
                                    : IslandMetrics.compactCornerRadius,
                                ear: plan.shape == .pill ? 0 : IslandMetrics.earRadius,
                                top: plan.shape == .pill ? min(size.height / 2, IslandMetrics.expandedCornerRadius) : 0)
            animateTuckMask(from: to, to: to, response: IslandTiming.expandResponse, damping: IslandTiming.expandDamping) { [weak self] in
                guard let self, self.tuckToken == token else { return }
                self.removeTuckMask()
            }
        } else {
            removeTuckMask()
        }
        withAnimation(.spring(response: IslandTiming.expandResponse, dampingFraction: IslandTiming.expandDamping)) {
            model.tucked = false
        }
        tuckTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(MissionControlTiming.contentFadeInDelay))
            guard !Task.isCancelled, let self, self.tuckToken == token else { return }
            withAnimation(.easeOut(duration: IslandTiming.contentFadeDuration)) { self.model.contentTucked = false }
        }
        updateMouseInteractivity()
    }

    /// Tucked or not at once (no animation), for the instant paths.
    private func setTucked(_ tucked: Bool) {
        tuckToken &+= 1
        tuckTask?.cancel()
        removeTuckMask()
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            model.tucked = tucked
            model.contentTucked = tucked
        }
    }

    // MARK: Tuck mask (Core Animation, run by the window server)

    private var tuckMask: CAShapeLayer?

    /// The notch's exact shape (or the pill), where the island tucks in.
    private var tuckSilhouette: CGPath {
        let size = plan.tuckSize
        if plan.shape == .pill { return silhouette(size: size, bottom: size.height / 2, ear: 0, top: size.height / 2) }
        return silhouette(size: size, bottom: IslandMetrics.compactCornerRadius, ear: IslandMetrics.earRadius, top: 0)
    }

    /// The island's outline at the top centre of the canvas, in the hosting layer's coordinates.
    private func silhouette(size: CGSize, bottom: CGFloat, ear: CGFloat, top: CGFloat) -> CGPath {
        let local = IslandOutline(bottomRadius: bottom, earRadius: ear, topRadius: top)
            .path(in: CGRect(origin: .zero, size: size)).cgPath
        let canvas = hostingView.bounds
        // Top-down canvas points → view points → layer points (both maps are affine).
        func layerPoint(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            hostingView.convertToLayer(NSPoint(x: x, y: hostingView.isFlipped ? y : canvas.height - y))
        }
        let o = layerPoint(0, 0), ux = layerPoint(1, 0), uy = layerPoint(0, 1)
        let toLayer = CGAffineTransform(a: ux.x - o.x, b: ux.y - o.y, c: uy.x - o.x, d: uy.y - o.y, tx: o.x, ty: o.y)
        var place = CGAffineTransform(translationX: (canvas.width - size.width) / 2, y: plan.topInset).concatenating(toLayer)
        return local.copy(using: &place) ?? local
    }

    /// Animates the mask over the island from one outline to another with a spring that starts now
    /// (from wherever a running one is), calling `completion` when it has settled.
    private func animateTuckMask(from: CGPath, to: CGPath, response: Double, damping: Double,
                                 completion: @escaping @MainActor () -> Void) {
        guard let layer = hostingView.layer else { completion(); return }
        let mask: CAShapeLayer
        if let existing = tuckMask {
            mask = existing
        } else {
            mask = CAShapeLayer()
            mask.frame = layer.bounds
            mask.fillColor = NSColor.black.cgColor
            mask.path = from
            layer.mask = mask
            tuckMask = mask
        }
        let start = mask.animation(forKey: "tuck") != nil ? (mask.presentation()?.path ?? mask.path ?? from) : from
        let now = layer.convertTime(CACurrentMediaTime(), from: nil)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { completion() } }
        mask.path = to
        let spring = CASpringAnimation(keyPath: "path")
        spring.mass = 1
        spring.stiffness = pow(2 * .pi / response, 2)
        spring.damping = 4 * .pi * damping / response
        spring.fromValue = start
        spring.toValue = to
        spring.duration = spring.settlingDuration
        spring.beginTime = now
        spring.fillMode = .backwards
        mask.add(spring, forKey: "tuck")
        CATransaction.commit()
    }

    private func removeTuckMask() {
        guard tuckMask != nil else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hostingView.layer?.mask = nil
        CATransaction.commit()
        tuckMask = nil
    }

    private func logTuck(_ line: String) {
        let visible = contentPanel.occlusionState.contains(.visible) ? "" : " (panel occluded)"
        tuckLog.append(String(format: "%.3f ", ProcessInfo.processInfo.systemUptime) + line + visible)
        if tuckLog.count > 30 { tuckLog.removeFirst(tuckLog.count - 30) }
    }

    private func fadePanels(to alpha: CGFloat, duration: Double) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            contentPanel.animator().alphaValue = alpha
            backdropPanel.animator().alphaValue = alpha
        }
    }

    // MARK: Pointer

    /// Hit-tests the pointer (AppKit global coordinates) against the island and drives enter/exit.
    func pointerMoved(to point: CGPoint) {
        guard visibility != .hidden else { return }
        let inside: Bool
        if interaction.pointerInside {
            let active = plan.islandRect(size: model.size(for: model.phase == .expanded ? .expanded : .elevated))
            inside = active.insetBy(dx: -IslandMetrics.exitTolerance, dy: -IslandMetrics.exitTolerance)
                .union(topEdgeStrip(for: active)).contains(point)
        } else {
            let zone = model.phase == .expanded ? plan.islandRect(size: model.drawnSize) : restingHoverZone
            inside = zone.union(topEdgeStrip(for: zone)).contains(point)
        }
        guard inside != interaction.pointerInside else { return }
        let before = interaction.phase
        let effects = inside ? interaction.pointerEntered(config) : interaction.pointerExited(config)
        perform(effects)
        render(from: before)
    }

    /// The compact shape, or the pill's hover zone while nothing is shown.
    private var restingHoverZone: CGRect {
        plan.hoverZone.union(plan.islandRect(size: model.size(for: .idle)))
    }

    /// The pointer can rest exactly on the screen's top edge; include a thin strip above the rect.
    private func topEdgeStrip(for rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: rect.maxY, width: rect.width, height: 2)
    }

    var pointerInside: Bool { interaction.pointerInside }

    // MARK: Clicks

    private func handlePrimaryClick(onArtwork: Bool = true) {
        // Clicking the compact artwork focuses the source app instead of expanding;
        // expand-on-hover disables it.
        if onArtwork, interaction.phase != .expanded, !settings[Keys.expandOnHover], compactArtworkContains(NSEvent.mouseLocation) {
            hub.nowPlaying.focusSource()
            hub.lastAction = "click→focusSource"
            return
        }
        let before = interaction.phase
        perform(interaction.clicked())
        render(from: before)
    }

    private func handleSecondaryClick(_ event: NSEvent) {
        let regionItems = menuActions?.regionItems?(self, event) ?? []
        handlePrimaryClick(onArtwork: false)
        let menu = NSMenu()
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        let header = NSMenuItem(title: "Lintel \(version)", action: nil, keyEquivalent: "")
        header.isEnabled = false
        let mediaItems = mediaMenuApplies(event) ? NowPlayingMenu.items(center: hub.nowPlaying, settings: settings) : []
        mediaItems.forEach(menu.addItem)
        if !mediaItems.isEmpty { menu.addItem(.separator()) }
        menu.addItem(header)
        if !regionItems.isEmpty {
            menu.addItem(.separator())
            regionItems.forEach { menu.addItem($0) }
            menu.addItem(.separator())
        }
        TimerMenu.append(to: menu, island: self)
        menu.addItem(ClosureMenuItem(title: "Settings…", key: ",") { [weak self] in self?.menuActions?.openSettings() })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Quit Lintel", key: "q") { [weak self] in self?.menuActions?.quit() })
        NSMenu.popUpContextMenu(menu, with: event, for: hostingView)
    }

    /// Media entries belong to the media half of the card.
    private func mediaMenuApplies(_ event: NSEvent) -> Bool {
        switch model.expandedContent {
        case .media: return true
        case .both: return hostingView.convert(event.locationInWindow, from: nil).x < hostingView.bounds.midX
        default: return false
        }
    }

    /// Whether a screen point lies on the compact island's leading artwork.
    private func compactArtworkContains(_ point: CGPoint) -> Bool {
        let showsArtwork: Bool
        switch model.displayed {
        case .live(let kinds): showsArtwork = kinds.contains(.media)
        case .peek(let kind): showsArtwork = kind == .media
        default: showsArtwork = false
        }
        guard showsArtwork, hub.nowPlaying.track != nil else { return false }
        let rect = plan.islandRect(size: model.drawnSize)
        let slot = max(0, (model.drawnSize.width - model.baseSize.width) / 2)
        let band = CGRect(x: rect.minX, y: rect.maxY - model.bandHeight - 2, width: slot, height: model.bandHeight + 2)
        return band.contains(point)
    }

    /// Middle click cycles the expanded activity; on the compact island it opens the card first so
    /// the change is visible.
    func handleMiddleClick() {
        guard visibility != .hidden else { return }
        if interaction.phase != .expanded { performOpen() }
        cycleExpanded()
        hub.lastAction = "middleClick→cycle"
    }

    // MARK: Programmatic actions (gestures)

    func performOpen() {
        let before = interaction.phase
        perform(interaction.open())
        render(from: before)
    }

    func performClose() {
        let before = interaction.phase
        perform(interaction.close())
        render(from: before)
    }

    func cycleExpanded() {
        activity.mutate { $0.cycleExpanded() }
        haptics.perform()
    }

    func dismissTop() {
        var dismissed: LiveActivityKind?
        activity.mutate { engine in
            if !engine.dismissPeek() { dismissed = engine.dismissTopLiveActivity() }
        }
        if dismissed == .timer { hub.timer.dismissedFromIsland() } // an ended timer stops
    }

    // MARK: State machine plumbing

    private func perform(_ effects: [InteractionEffect]) {
        for effect in effects {
            switch effect {
            case .scheduleExpand(let delay):
                expandTask?.cancel()
                expandTask = Task { [weak self] in
                    if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
                    guard !Task.isCancelled, let self else { return }
                    let before = self.interaction.phase
                    self.perform(self.interaction.expandTimerFired())
                    self.render(from: before)
                }
            case .cancelExpand:
                expandTask?.cancel()
                expandTask = nil
            case .scheduleCollapse(let delay):
                collapseTask?.cancel()
                collapseTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(delay))
                    guard !Task.isCancelled, let self else { return }
                    let before = self.interaction.phase
                    self.perform(self.interaction.collapseTimerFired())
                    self.render(from: before)
                }
            case .cancelCollapse:
                collapseTask?.cancel()
                collapseTask = nil
            }
        }
    }

    /// Animates the model from the previous phase to the state machine's current phase.
    private func render(from before: IslandPhase) {
        let after = interaction.phase
        defer { updateMouseInteractivity() }
        guard after != before else { return }
        if after == .expanded {
            enterExpanded()
        } else if before == .expanded {
            leaveExpanded(to: after)
        } else {
            withAnimation(.spring(response: IslandTiming.elevateResponse, dampingFraction: IslandTiming.elevateDamping)) {
                model.phase = after
            }
        }
    }

    private func enterExpanded() {
        contentTask?.cancel()
        // The ruler opens at the last used duration; the content is still hidden.
        model.timerRuler.reset(to: hub.timer.rulerMinutes)
        activity.mutate { $0.setExpanded(true) }
        cancelSwap() // compact swaps don't run behind the card
        model.displayed = activity.engine.compactPresentation
        syncExpanded(animated: false)
        withAnimation(.easeOut(duration: SwapTiming.contentFadeOut)) { model.compactContentVisible = false }
        withAnimation(.spring(response: IslandTiming.expandResponse, dampingFraction: IslandTiming.expandDamping)) {
            model.phase = .expanded
        }
        haptics.perform(.levelChange)
        updateBackdrop()
        hub.nowPlaying.setPlayerOpen(true, island: plan.screenUUID)
        // Expanded content blurs in once the shape has mostly grown (content blur-in).
        contentTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(160))
            guard !Task.isCancelled, let self, self.model.phase == .expanded else { return }
            withAnimation(.easeOut(duration: IslandTiming.contentFadeDuration)) { self.model.contentVisible = true }
            // The compact content has faded out behind the card (0.12 s): its animations pause.
            self.model.compactSuspended = true
        }
    }

    private func leaveExpanded(to phase: IslandPhase) {
        contentTask?.cancel()
        model.compactSuspended = false
        model.timerRuler.cardClosed()
        activity.mutate { $0.setExpanded(false) }
        cancelSwap() // the collapse below shows the current presentation directly
        // The compact island returns showing whatever is current now.
        let target = activity.engine.compactPresentation
        withAnimation(.easeIn(duration: 0.08)) { model.contentVisible = false }
        model.displayed = target
        withAnimation(.spring(response: IslandTiming.collapseResponse, dampingFraction: IslandTiming.collapseDamping)) {
            model.phase = phase
            model.shapePresentation = target
            model.expandedNotification = nil
        }
        updateBackdrop()
        hub.nowPlaying.setPlayerOpen(false, island: plan.screenUUID)
        // The compact activity fades back in after the main collapse motion (≈ 0.35–0.55 s).
        let token = swapToken
        contentTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self, self.swapToken == token, self.model.phase != .expanded else { return }
            withAnimation(.easeOut(duration: SwapTiming.contentFadeIn)) { self.model.compactContentVisible = true }
        }
    }

    /// The panel only takes mouse events while the pointer is over the visible island;
    /// everywhere else clicks pass through to the windows below.
    private func updateMouseInteractivity() {
        contentPanel.ignoresMouseEvents = !(interaction.pointerInside && model.isVisible && visibility != .hidden)
    }

    // MARK: Activity → presentation

    private func activityChanged() {
        if model.phase == .expanded { syncExpanded(animated: true) }
        scheduleSwap()
    }

    private func syncExpanded(animated: Bool) {
        let content = activity.engine.expandedContent
        var notification: NotificationKind?
        if model.phase == .expanded || activity.engine.context.expanded,
           case .notification(let kind) = activity.engine.compactPresentation {
            notification = kind
        }
        guard content != model.expandedContent || notification != model.expandedNotification else { return }
        if animated {
            withAnimation(.spring(response: IslandTiming.expandResponse, dampingFraction: IslandTiming.expandDamping)) {
                model.expandedContent = content
                model.expandedNotification = notification
            }
            updateBackdrop()
        } else {
            model.expandedContent = content
            model.expandedNotification = notification
        }
    }

    private func scheduleSwap() {
        swapDebounce?.cancel()
        swapDebounce = Task { [weak self] in
            try? await Task.sleep(for: .seconds(SwapTiming.debounce))
            guard !Task.isCancelled, let self else { return }
            self.applyTargetPresentation()
        }
    }

    private func cancelSwap() {
        swapToken &+= 1
        swapDebounce?.cancel()
        swapTask?.cancel()
    }

    private func applyTargetPresentation() {
        let target = activity.engine.compactPresentation
        guard model.phase != .expanded else {
            // Hidden behind the card: switch without animation; shown on collapse.
            model.displayed = target
            model.shapePresentation = target
            return
        }
        let plan = SwapPlan.between(model.displayed, target)
        swapToken &+= 1
        let token = swapToken
        swapTask?.cancel()
        log("\(plan) \(model.displayed) → \(target)")
        switch plan {
        case .none:
            // A contraction may be under way towards something that was superseded: grow back.
            if model.shapePresentation != target || !model.compactContentVisible { grow(to: target, token: token) }
        case .grow:
            grow(to: target, token: token)
        case .morph:
            withAnimation(.spring(response: SwapTiming.growResponse, dampingFraction: SwapTiming.growDamping)) {
                model.displayed = target
                model.shapePresentation = target
                model.compactContentVisible = true
            }
        case .contract:
            contract(then: nil, token: token)
        case .contractThenGrow:
            contract(then: target, token: token)
        }
        updateMouseInteractivity()
    }

    private func grow(to target: CompactPresentation, token: Int) {
        model.displayed = target
        model.compactContentVisible = false
        withAnimation(.spring(response: SwapTiming.growResponse, dampingFraction: SwapTiming.growDamping)) {
            model.shapePresentation = target
        }
        swapTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(SwapTiming.contentFadeInDelay))
            guard !Task.isCancelled, let self, self.swapToken == token else { return }
            withAnimation(.easeOut(duration: SwapTiming.contentFadeIn)) { self.model.compactContentVisible = true }
        }
        updateMouseInteractivity()
    }

    private func contract(then next: CompactPresentation?, token: Int) {
        withAnimation(.easeIn(duration: SwapTiming.contentFadeOut)) { model.compactContentVisible = false }
        withAnimation(.spring(response: SwapTiming.contractResponse, dampingFraction: SwapTiming.contractDamping)) {
            model.shapePresentation = .idle
        }
        swapTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(SwapTiming.growDelay))
            guard !Task.isCancelled, let self, self.swapToken == token else { return }
            if let next {
                self.grow(to: next, token: token)
            } else {
                self.model.displayed = .idle
                self.updateMouseInteractivity()
            }
        }
    }

    private func log(_ line: String) {
        swapLog.append(String(format: "%.3f ", ProcessInfo.processInfo.systemUptime) + line)
        if swapLog.count > 40 { swapLog.removeFirst(swapLog.count - 40) }
    }

    // MARK: Backdrop blur

    func updateBackdrop() {
        let size = model.expandedSize
        let canvas = plan.canvas.size
        let card = CGRect(x: (canvas.width - size.width) / 2, y: canvas.height - plan.topInset - size.height,
                          width: size.width, height: size.height)
        let show = settings[Keys.progressiveBlur] && model.phase == .expanded && visibility != .hidden
        backdrop.update(cardRect: card, show: show, canvasHeight: canvas.height)
    }

    // MARK: Gestures

    enum SwipeInput {
        case began
        case changed(CGSize)
        case ended
        case cancelled
    }

    /// Phased trackpad scroll events only; mouse wheels and momentum are ignored.
    /// Returns true when the event belonged to a swipe on this island.
    @discardableResult
    func handleScroll(_ event: NSEvent) -> Bool {
        guard visibility != .hidden, !hub.locked else { return false }
        if rulerShown, !swipeInProgress || model.timerRuler.router.owner != .undecided { return handleRulerScroll(event) }
        guard event.hasPreciseScrollingDeltas, !event.phase.isEmpty else { return false }
        let delta = SwipeRecognizer.fingerDelta(scrollingDeltaX: event.scrollingDeltaX, scrollingDeltaY: event.scrollingDeltaY,
                                                invertedFromDevice: event.isDirectionInvertedFromDevice)
        let phase = event.phase
        if phase.contains(.began) {
            feedSwipe(.began)
            feedSwipe(.changed(delta))
        } else if phase.contains(.changed) {
            if !swipeInProgress { feedSwipe(.began) }
            feedSwipe(.changed(delta))
        } else if phase.contains(.ended) {
            feedSwipe(.changed(delta))
            feedSwipe(.ended)
        } else if phase.contains(.cancelled) {
            feedSwipe(.cancelled)
        }
        return true
    }

    func feedSwipe(_ input: SwipeInput) {
        var config = SwipeRecognizer.Config()
        config.toggleEnabled = settings[Keys.gestureToggle]
        config.cycleEnabled = settings[Keys.gestureCycle]
        config.dismissEnabled = settings[Keys.gestureDismiss]
        config.skipEnabled = settings[Keys.gestureSkip]
        config.naturalDirection = settings[Keys.gestureNaturalDirection]
        swipe.config = config
        let state = SwipeRecognizer.State(expanded: interaction.phase == .expanded,
                                          hasLiveActivity: activity.engine.hasDismissible,
                                          hasMedia: hub.media != nil)
        let output: SwipeRecognizer.Output
        switch input {
        case .began:
            swipeInProgress = true
            output = swipe.began(state: state)
        case .changed(let delta):
            output = swipe.changed(dx: delta.width, dy: delta.height, state: state)
        case .ended:
            swipeInProgress = false
            output = swipe.ended(state: state)
        case .cancelled:
            swipeInProgress = false
            output = swipe.cancelled()
        }
        switch input {
        case .ended, .cancelled:
            withAnimation(.spring(response: 0.32, dampingFraction: 0.68)) { model.stretch = .zero }
        default:
            withAnimation(.interactiveSpring(response: 0.15, dampingFraction: 0.86)) { model.stretch = output.stretch }
        }
        if output.feedback != nil { haptics.perform() }
        if let action = output.action { performSwipeAction(action) }
    }

    private func performSwipeAction(_ action: SwipeRecognizer.Action) {
        hub.lastAction = "swipe→\(action)"
        switch action {
        case .open: performOpen()
        case .close: performClose()
        case .cycle: cycleExpanded()
        case .dismiss: dismissTop()
        case .skipNext:
            hub.nowPlaying.perform(.next)
        case .skipPrevious:
            hub.nowPlaying.perform(.previous)
        }
    }
}

/// NSMenuItem with a closure action.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, key: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: key)
        target = self
    }

    @available(*, unavailable) required init(coder: NSCoder) { fatalError("not used") }

    @objc private func run() { handler() }
}
