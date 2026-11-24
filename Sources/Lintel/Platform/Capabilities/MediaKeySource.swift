import AppKit
import ApplicationServices
import CoreGraphics
import LintelCore
import Synchronization

/// Delivers the volume, mute and brightness keys Lintel takes over (`CGEventTap`, needs
/// Accessibility). Implementations decide synchronously whether to remove a key from the event
/// stream (so macOS shows no OSD of its own) and hand the work to the main thread.
@MainActor
protocol MediaKeySource: AnyObject {
    var status: MediaKeyTapStatus { get }
    /// Called on the main thread for every taken key-down (or auto-repeat).
    var onAction: ((MediaKeyEvent, MediaKeyAction) -> Void)? { get set }
    /// Updates what the tap may take (read on the tap's thread).
    func updateRouting(_ state: MediaKeyRoutingState)
    /// Starts the tap when Accessibility access is granted; returns the resulting status.
    @discardableResult func start() -> MediaKeyTapStatus
    func stop()
}

enum MediaKeyTapStatus: String {
    case off
    case running
    /// Accessibility access isn't granted, so macOS keeps its own HUDs.
    case notAuthorized
    /// The tap couldn't be created although access is granted.
    case failed
}

/// Counters and the last decision.
struct MediaKeyTapStats: Sendable {
    var seen = 0
    var taken = 0
    var passed = 0
    var reenabled = 0
    var lastEvent = ""
    var lastDecision = ""
}

/// `CGEventTap` on system-defined events (NX_SYSDEFINED), session level, inserted at the head, on its
/// own thread and run loop. A tap that the system disables (timeout, user input) is re-enabled.
final class EventTapMediaKeySource: @unchecked Sendable {
    // Main-actor state.
    @MainActor private(set) var status: MediaKeyTapStatus = .off
    @MainActor var onAction: ((MediaKeyEvent, MediaKeyAction) -> Void)?

    // Shared with the tap thread.
    private let routing = Mutex(MediaKeyRoutingState())
    private let stats = Mutex(MediaKeyTapStats())
    private let tapState = Mutex<TapHandles?>(nil)

    private struct TapHandles: @unchecked Sendable {
        var port: CFMachPort
        var runLoop: CFRunLoop?
    }

    @MainActor init() {}

    @MainActor func updateRouting(_ state: MediaKeyRoutingState) {
        routing.withLock { $0 = state }
    }

    @MainActor @discardableResult
    func start() -> MediaKeyTapStatus {
        if status == .running { return status }
        // Checked without prompting; creating a tap without access could raise a system prompt.
        guard AccessibilityAccess.isTrusted else {
            status = .notAuthorized
            return status
        }
        let mask = CGEventMask(1) << CGEventMask(MediaKeyDecoder.systemDefinedEventType)
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: mask, callback: mediaKeyTapCallback,
                                           userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            status = .failed
            return status
        }
        tapState.withLock { $0 = TapHandles(port: port, runLoop: nil) }
        let thread = Thread { [weak self] in self?.runTapLoop() }
        thread.name = "Lintel media-key tap"
        thread.qualityOfService = .userInteractive
        thread.start()
        status = .running
        return status
    }

    @MainActor func stop() {
        let handles = tapState.withLock { state -> TapHandles? in
            let current = state
            state = nil
            return current
        }
        if let handles {
            CGEvent.tapEnable(tap: handles.port, enable: false)
            CFMachPortInvalidate(handles.port)
            if let runLoop = handles.runLoop { CFRunLoopStop(runLoop) }
        }
        if status == .running { status = .off }
    }

    @MainActor func markNotAuthorized() { if status != .running { status = .notAuthorized } }

    private func runTapLoop() {
        guard let port = tapState.withLock({ $0?.port }),
              let source = CFMachPortCreateRunLoopSource(nil, port, 0) else { return }
        let runLoop = CFRunLoopGetCurrent()
        tapState.withLock { $0?.runLoop = runLoop }
        CFRunLoopAddSource(runLoop, source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        CFRunLoopRun()
    }

    fileprivate func reenable() {
        stats.withLock { $0.reenabled += 1 }
        if let port = tapState.withLock({ $0?.port }) { CGEvent.tapEnable(tap: port, enable: true) }
    }

    /// Decides whether to take the event; runs on the tap thread. Returns true when the event must be
    /// removed from the stream.
    func handle(_ event: CGEvent) -> Bool {
        guard let nsEvent = NSEvent(cgEvent: event), nsEvent.type == .systemDefined,
              let key = MediaKeyDecoder.decode(eventType: MediaKeyDecoder.systemDefinedEventType,
                                               subtype: Int16(nsEvent.subtype.rawValue), data1: nsEvent.data1,
                                               flags: event.flags.rawValue) else { return false }
        return handle(key)
    }

    func handle(_ key: MediaKeyEvent) -> Bool {
        let state = routing.withLock { $0 }
        let decision = MediaKeyRouter.route(key, state: state, pointerDisplay: Self.pointerDisplay())
        stats.withLock { stats in
            stats.seen += 1
            if decision.consume { stats.taken += 1 } else { stats.passed += 1 }
            stats.lastEvent = "\(key.key.name) \(key.isDown ? "down" : "up")\(key.isRepeat ? " repeat" : "") mods=\(key.modifiers.rawValue)"
            stats.lastDecision = decision.consume ? "take \(decision.action.map { "\($0)" } ?? "-")" : "pass"
        }
        if let action = decision.action {
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.onAction?(key, action) }
            }
        }
        return decision.consume
    }

    /// Display under the pointer (CoreGraphics global coordinates; safe off the main thread).
    static func pointerDisplay() -> UInt32? {
        guard let location = CGEvent(source: nil)?.location else { return nil }
        var display: CGDirectDisplayID = 0
        var count: UInt32 = 0
        guard CGGetDisplaysWithPoint(location, 1, &display, &count) == .success, count > 0 else { return nil }
        return display
    }
}

// Declared in an extension so the main-actor protocol doesn't make the whole class main-actor
// isolated: `handle(_:)` runs on the tap's thread.
extension EventTapMediaKeySource: MediaKeySource {}

/// C callback of the tap: re-enables a disabled tap, otherwise asks the source.
private let mediaKeyTapCallback: CGEventTapCallBack = { _, type, event, refcon in
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let source = Unmanaged<EventTapMediaKeySource>.fromOpaque(refcon).takeUnretainedValue()
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        source.reenable()
        return Unmanaged.passUnretained(event)
    }
    return source.handle(event) ? nil : Unmanaged.passUnretained(event)
}
