import AppKit
import LintelCore
import Observation

/// Optional integration with BetterDisplay for external displays (request values).
///
/// - BetterDisplay starting or quitting is noticed through its launched / terminated distributed
///   notifications (and a running-app check at start-up).
/// - While it runs and a Lintel HUD is on, Lintel sends a "set" request that turns BetterDisplay's
///   OSD-integration notifications on and its own OSDs off; on quit (or when both HUDs are switched
///   off) the opposite request gives BetterDisplay its OSDs back. Lintel has no helper process, so a
///   crash can't send that restore (noted).
/// - BetterDisplay's OSD notifications are shown as Lintel's Display or Sound HUD.
@MainActor
@Observable
final class BetterDisplayBridge {
    private(set) var isRunning = false
    private(set) var integrationRequested = false
    /// Last request body sent.
    private(set) var lastRequest: String?
    private(set) var requestsSent = 0
    private(set) var eventsReceived = 0
    @ObservationIgnored var onOSD: ((BetterDisplayProtocol.OSDEvent) -> Void)?
    @ObservationIgnored var onActiveChange: (() -> Void)?

    @ObservationIgnored private var wantsIntegration = false
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    /// BetterDisplay manages displays and Lintel asked it for OSD events.
    var isActive: Bool { isRunning && integrationRequested }

    func start() {
        let center = DistributedNotificationCenter.default()
        observers.append(center.addObserver(forName: Notification.Name(BetterDisplayProtocol.launchedNotification), object: nil,
                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setRunning(true) }
        })
        observers.append(center.addObserver(forName: Notification.Name(BetterDisplayProtocol.terminatedNotification), object: nil,
                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setRunning(false) }
        })
        observers.append(center.addObserver(forName: Notification.Name(BetterDisplayProtocol.osdNotification), object: nil,
                                            queue: .main) { [weak self] note in
            let object = note.object as? String
            var info: [String: Any] = [:]
            for (key, value) in note.userInfo ?? [:] { info["\(key)"] = value }
            let event = BetterDisplayProtocol.parseOSD(object: object, userInfo: info.isEmpty ? nil : info)
            MainActor.assumeIsolated { self?.received(event) }
        })
        setRunning(!NSRunningApplication.runningApplications(withBundleIdentifier: BetterDisplayProtocol.bundleID).isEmpty)
    }

    func stop() {
        if integrationRequested { send(integrate: false) }
        observers.forEach { DistributedNotificationCenter.default().removeObserver($0) }
        observers.removeAll()
    }

    /// Whether Lintel wants BetterDisplay's OSD events (a HUD is switched on).
    func setIntegration(_ wanted: Bool) {
        wantsIntegration = wanted
        sync()
    }

    private func setRunning(_ running: Bool) {
        guard running != isRunning else { return }
        isRunning = running
        if !running { integrationRequested = false }
        sync()
        onActiveChange?()
    }

    private func sync() {
        guard isRunning else { return }
        if wantsIntegration != integrationRequested {
            send(integrate: wantsIntegration)
            onActiveChange?()
        }
    }

    private func send(integrate: Bool) {
        let body = BetterDisplayProtocol.requestJSON(integrate: integrate, requestID: UUID().uuidString)
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(BetterDisplayProtocol.requestNotification), object: body, userInfo: nil, deliverImmediately: true)
        integrationRequested = integrate
        lastRequest = body
        requestsSent += 1
    }

    private func received(_ event: BetterDisplayProtocol.OSDEvent?) {
        guard let event else { return }
        eventsReceived += 1
        onOSD?(event)
    }
}
