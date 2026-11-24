import LintelCore
import SwiftUI

extension Brand {
    /// Lintel Ember #FF5A47: the timer's urgent colour (last 10 s, ringing).
    static let ember = Color(red: 0xFF / 255, green: 0x5A / 255, blue: 0x47 / 255)
}

/// Re-renders its content on the whole seconds before a running timer's end (1 Hz, aligned with the
/// end); anything else renders once. Off screen (`islandOnScreen`) it renders once too, and catches
/// up when it can be seen again.
struct TimerTicks<Content: View>: View {
    let state: TimerState?
    var active = true
    @ViewBuilder let content: (Date) -> Content
    @Environment(\.islandOnScreen) private var onScreen

    private var runningEnd: Date? {
        if case .running(let end)? = state?.phase { return end }
        return nil
    }

    var body: some View {
        if active, onScreen, let end = runningEnd {
            TimelineView(.periodic(from: TimerFormat.tickAnchor(end: end, now: Date()), by: 1)) { context in
                content(context.date)
            }
        } else {
            content(Date())
        }
    }
}

/// How the timer's text looks at a moment.
private struct TimerLook {
    var text: String
    var color: Color
    var opacity: Double = 1
    var urgent = false

    @MainActor
    init(timer: TimerCenter, now: Date) {
        guard let state = timer.state else {
            text = ""
            color = Brand.copper
            return
        }
        if timer.isRinging {
            text = "0:00"
            color = Brand.ember
            urgent = true
        } else if state.isFinished {
            text = "Done"
            color = Brand.copper
        } else {
            text = TimerFormat.clock(state.shownSeconds(at: now))
            urgent = state.isUrgent(at: now)
            color = urgent ? Brand.ember : Brand.copper
            if state.isPaused { opacity = 0.5 }
        }
    }
}

// MARK: - Compact island

/// Leading slot while a timer is live: the highest-priority other activity's leading element
/// (media artwork with the calendar badge, else the calendar glyph), else the timer glyph.
struct TimerCompactLeading: View {
    let kinds: Set<LiveActivityKind>
    let hub: ActivityHub
    let padding: CGFloat

    var body: some View {
        Group {
            if kinds.contains(.media) {
                NowPlayingArtwork(center: hub.nowPlaying, fallbackSeed: hub.media?.artworkSeed ?? 0, size: 20, corner: 5)
                    .overlay(alignment: .bottomTrailing) {
                        if kinds.contains(.calendar) { CalendarBadge(tint: hub.calendar?.tint).offset(x: 4, y: 4) }
                    }
            } else if kinds.contains(.calendar) {
                CalendarGlyph(size: 14, tint: hub.calendar?.tint)
            } else {
                TimerGlyph(timer: hub.timer, size: 14)
            }
        }
        .padding(.leading, padding)
    }
}

/// Trailing slot while a timer is live: the remaining time.
struct TimerCompactTrailing: View {
    let timer: TimerCenter
    /// Slot width (the island's extra width per side).
    let slot: CGFloat
    let padding: CGFloat

    var body: some View {
        TimerTicks(state: timer.state) { now in
            TimerCountdownText(timer: timer, now: now, size: 13)
        }
        // Keep clear of the notch; shrink rather than truncate from an hour on.
        .frame(maxWidth: max(0, slot - padding - 4), alignment: .trailing)
        .padding(.trailing, padding)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Timer")
    }
}

/// `timer` (copper, Ember in the last 10 s) or a ringing bell that shakes once per ring.
struct TimerGlyph: View {
    let timer: TimerCenter
    let size: CGFloat

    var body: some View {
        TimerTicks(state: timer.state) { now in
            let look = TimerLook(timer: timer, now: now)
            Image(systemName: timer.isRinging ? "bell.fill" : "timer")
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(look.urgent ? Brand.ember : Brand.copper)
                .modifier(BellShake(trigger: timer.ringCount))
        }
        .accessibilityHidden(true)
    }
}

/// The countdown (`4:59`, `0:00` while ringing, `Done`).
struct TimerCountdownText: View {
    let timer: TimerCenter
    let now: Date
    let size: CGFloat

    var body: some View {
        let look = TimerLook(timer: timer, now: now)
        Text(look.text)
            .font(.system(size: size, weight: .semibold, design: .rounded).monospacedDigit())
            .foregroundStyle(look.color)
            .opacity(look.opacity)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .modifier(RingPulse(trigger: timer.ringCount))
    }
}

/// One shake per ring.
private struct BellShake: ViewModifier {
    let trigger: Int

    func body(content: Content) -> some View {
        content.keyframeAnimator(initialValue: 0.0, trigger: trigger) { view, angle in
            view.rotationEffect(.degrees(angle), anchor: .top)
        } keyframes: { _ in
            KeyframeTrack {
                CubicKeyframe(16, duration: 0.07)
                CubicKeyframe(-14, duration: 0.09)
                CubicKeyframe(10, duration: 0.09)
                CubicKeyframe(-6, duration: 0.09)
                CubicKeyframe(0, duration: 0.12)
            }
        }
    }
}

/// One fade per ring.
private struct RingPulse: ViewModifier {
    let trigger: Int

    func body(content: Content) -> some View {
        content.keyframeAnimator(initialValue: 1.0, trigger: trigger) { view, value in
            view.opacity(value)
        } keyframes: { _ in
            KeyframeTrack {
                CubicKeyframe(0.3, duration: 0.15)
                CubicKeyframe(1, duration: 0.45)
            }
        }
    }
}

// MARK: - Open island: the timer page

enum TimerCardLayout {
    /// Content starts below the band beside the notch.
    static let contentTop: CGFloat = 38
    static let horizontalPadding: CGFloat = 18
    static let ring: CGFloat = 104
    static let ringStroke: CGFloat = 7
    static let tile = CGSize(width: 72, height: 46)
    static let tileGap: CGFloat = 8
    static let button = CGSize(width: 86, height: 32)
    static let buttonGap: CGFloat = 8
}

struct TimerCardView: View {
    let hub: ActivityHub
    let size: CGSize
    /// The island's Ruler picker.
    let ruler: TimerRulerModel

    private var timer: TimerCenter { hub.timer }
    /// A card is open on some island (the player's count covers every page), so the ring may animate.
    private var open: Bool { hub.nowPlaying.openPlayers > 0 }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Caption left of the notch, where the calendar card has its weekday.
            Text("Timer")
                .textCase(.uppercase)
                .font(.system(size: 10, weight: .heavy))
                .tracking(0.6)
                .foregroundStyle(timer.isRinging ? Brand.ember : Brand.copper)
                .padding(.leading, TimerCardLayout.horizontalPadding + 0.5)
                .padding(.top, 18.5)
            Group {
                if !timer.enabled {
                    TimerOffNote()
                } else if let state = timer.state {
                    TimerRunningPage(timer: timer, state: state, open: open)
                } else if timer.pickerStyle == .ruler {
                    TimerRulerPage(timer: timer, ruler: ruler, width: size.width)
                } else {
                    TimerPresetGrid(timer: timer)
                }
            }
            .frame(width: size.width, height: max(0, size.height - TimerCardLayout.contentTop), alignment: .top)
            .padding(.top, TimerCardLayout.contentTop)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Timer")
    }
}

/// Preset tiles and Custom (no timer).
struct TimerPresetGrid: View {
    let timer: TimerCenter

    var body: some View {
        let minutes = TimerPolicy.presetMinutes
        Grid(horizontalSpacing: TimerCardLayout.tileGap, verticalSpacing: TimerCardLayout.tileGap) {
            GridRow { ForEach(minutes.prefix(4), id: \.self) { TimerPresetTile(minutes: $0, timer: timer) } }
            GridRow {
                ForEach(minutes.dropFirst(4), id: \.self) { TimerPresetTile(minutes: $0, timer: timer) }
                TimerTile(label: "Custom", detail: nil, symbol: "ellipsis") { timer.perform(.custom) }
            }
        }
        .padding(.top, 6)
    }
}

private struct TimerPresetTile: View {
    let minutes: Int
    let timer: TimerCenter

    var body: some View {
        TimerTile(label: "\(minutes)", detail: "min", symbol: nil) { timer.perform(.start(seconds: Double(minutes * 60))) }
            .accessibilityLabel("Start a \(minutes) minute timer")
    }
}

private struct TimerTile: View {
    let label: String
    let detail: String?
    let symbol: String?
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: -1) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 16, weight: .bold)).frame(height: 21)
                    Text(label).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.55))
                } else {
                    Text(label).font(.system(size: 19, weight: .semibold, design: .rounded)).monospacedDigit()
                    if let detail {
                        Text(detail).font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.5))
                    }
                }
            }
            .foregroundStyle(.white)
            .frame(width: TimerCardLayout.tile.width, height: TimerCardLayout.tile.height)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(hovered ? 0.16 : 0.09)))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(PressScaleStyle())
        .onHover { hovered = $0 }
    }
}

/// Running, paused, ringing or done: the ring with the countdown, the title and the buttons.
struct TimerRunningPage: View {
    let timer: TimerCenter
    let state: TimerState
    let open: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            TimerRing(timer: timer, state: state, open: open)
                .frame(width: TimerCardLayout.ring, height: TimerCardLayout.ring)
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(subtitle ?? " ")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
                    .padding(.top, 1)
                TimerButtons(timer: timer, state: state)
                    .padding(.top, 12)
            }
            .padding(.top, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, TimerCardLayout.horizontalPadding)
    }

    private var title: String {
        if timer.isRinging { return "Time's up" }
        if state.isFinished { return "Timer done" }
        return TimerFormat.title(preset: state.preset)
    }

    private var subtitle: String? {
        if let alert = timer.alert {
            return TimerFormat.lateNote(alert.lateBy) ?? TimerFormat.title(preset: state.preset)
        }
        if case .finished(let at, _, _) = state.phase {
            return "Ended at " + at.formatted(date: .omitted, time: .shortened)
        }
        if state.isPaused { return "Paused" }
        return nil
    }
}

/// Ring Ø 104 pt, remaining part copper (Ember in the last 10 s and while ringing), emptying
/// clockwise from 12 o'clock; the large countdown and the end time inside.
struct TimerRing: View {
    let timer: TimerCenter
    let state: TimerState
    let open: Bool

    var body: some View {
        // Closed cards don't tick or animate.
        TimerTicks(state: state, active: open) { now in
            let ringing = timer.isRinging
            let look = TimerLook(timer: timer, now: now)
            // Animating towards the value one second ahead keeps the ring exact through the second.
            let animate = open && state.isRunning
            let fraction = ringing ? 1 : state.remainingFraction(at: animate ? now.addingTimeInterval(1) : now)
            ZStack {
                Circle()
                    .stroke(.white.opacity(0.12), lineWidth: TimerCardLayout.ringStroke)
                Circle()
                    .trim(from: 1 - fraction, to: 1)
                    .stroke(look.urgent ? Brand.ember : Brand.copper,
                            style: StrokeStyle(lineWidth: TimerCardLayout.ringStroke, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(animate ? .linear(duration: 1) : nil, value: fraction)
                VStack(spacing: 2) {
                    if ringing || state.isFinished {
                        Image(systemName: "bell.fill")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(ringing ? Brand.ember : Brand.copper)
                            .modifier(BellShake(trigger: timer.ringCount))
                    }
                    Text(look.text)
                        .font(.system(size: ringing || state.isFinished ? 17 : 26, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(look.urgent ? Brand.ember : .white)
                        .opacity(look.opacity)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .frame(maxWidth: TimerCardLayout.ring - 24)
                    caption
                }
            }
            .padding(TimerCardLayout.ringStroke / 2)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    @ViewBuilder private var caption: some View {
        switch state.phase {
        case .running(let end):
            HStack(spacing: 3) {
                Image(systemName: "bell.fill").font(.system(size: 8.5, weight: .semibold))
                Text(end, format: .dateTime.hour().minute())
            }
            .font(.system(size: 10.5, weight: .medium).monospacedDigit())
            .foregroundStyle(.white.opacity(0.5))
        case .paused:
            Text("Paused")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
        case .finished:
            EmptyView()
        }
    }

    private var accessibilityText: String {
        switch state.phase {
        case .running: return "\(TimerFormat.clock(state.shownSeconds(at: Date()))) left"
        case .paused: return "Paused, \(TimerFormat.clock(state.shownSeconds(at: Date()))) left"
        case .finished: return timer.isRinging ? "Time's up" : "Timer done"
        }
    }
}

/// 2 × 2 buttons: Pause/Resume, +1 min, Restart, Cancel — or Stop/Dismiss, +1 min, Restart.
struct TimerButtons: View {
    let timer: TimerCenter
    let state: TimerState

    var body: some View {
        let wide = TimerCardLayout.button.width * 2 + TimerCardLayout.buttonGap
        VStack(alignment: .leading, spacing: TimerCardLayout.buttonGap) {
            if state.isFinished {
                TimerButton(title: timer.isRinging ? "Stop" : "Dismiss", symbol: timer.isRinging ? "stop.fill" : "checkmark",
                            prominent: true, width: wide) { timer.perform(.cancel) }
                HStack(spacing: TimerCardLayout.buttonGap) {
                    TimerButton(title: "1 min", symbol: "plus", label: "Add 1 minute") { timer.perform(.addMinute) }
                    TimerButton(title: "Restart", symbol: "arrow.counterclockwise") { timer.perform(.restart) }
                }
            } else {
                HStack(spacing: TimerCardLayout.buttonGap) {
                    TimerButton(title: state.isPaused ? "Resume" : "Pause", symbol: state.isPaused ? "play.fill" : "pause.fill",
                                prominent: true) { timer.perform(.togglePause) }
                    TimerButton(title: "1 min", symbol: "plus", label: "Add 1 minute") { timer.perform(.addMinute) }
                }
                HStack(spacing: TimerCardLayout.buttonGap) {
                    TimerButton(title: "Restart", symbol: "arrow.counterclockwise") { timer.perform(.restart) }
                    TimerButton(title: "Cancel", symbol: "xmark") { timer.perform(.cancel) }
                }
            }
        }
    }
}

struct TimerButton: View {
    let title: String
    let symbol: String
    /// Spoken label when it differs from the title.
    var label: String?
    var prominent = false
    var width: CGFloat = TimerCardLayout.button.width
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 10.5, weight: .bold))
                Text(title).font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(prominent ? Color.black : Color.white)
            .frame(width: width, height: TimerCardLayout.button.height)
            .background(Capsule().fill(prominent ? Brand.copper.opacity(hovered ? 0.85 : 1) : Color.white.opacity(hovered ? 0.18 : 0.11)))
            .contentShape(Capsule())
        }
        .buttonStyle(PressScaleStyle())
        .onHover { hovered = $0 }
        .accessibilityLabel(label ?? title)
    }
}

/// Shown if the page is reached while Timers are switched off.
private struct TimerOffNote: View {
    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: "timer").font(.system(size: 22, weight: .semibold)).foregroundStyle(Brand.copper)
            Text("Timers are off").font(.system(size: 13, weight: .semibold))
            Text("Switch them on in Settings › Timer.").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 20)
    }
}
