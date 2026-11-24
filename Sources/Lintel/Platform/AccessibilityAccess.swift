import AppKit
import ApplicationServices
import LintelCore
import Observation

/// Accessibility access, which the event tap needs to take over the volume and brightness keys.
/// Checking never prompts; only `requestAccess()` — behind the
/// onboarding and settings buttons — asks macOS, once, and later opens System Settings instead
/// (`AccessibilityRequestPlan`).
@MainActor
@Observable
final class AccessibilityAccess {
    /// Silent check (`AXIsProcessTrusted`, no prompt).
    nonisolated static var isTrusted: Bool { AXIsProcessTrusted() }

    private(set) var isTrusted = AccessibilityAccess.isTrusted

    @ObservationIgnored var onChange: ((Bool) -> Void)?
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var observer: NSObjectProtocol?

    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!

    init(settings: SettingsStore) {
        self.settings = settings
        if isTrusted, settings[Keys.signatureChangedFrom] != nil { settings[Keys.signatureChangedFrom] = nil }
        // Posted by the system when the list of trusted apps changes.
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.accessibility.api"), object: nil, queue: .main
        ) { [weak self] _ in
            // The trust database updates slightly after the notification.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(300))
                self?.refresh()
            }
        }
    }

    /// Whether the HUD settings rows are shown (hidden without access).
    var showsHUDSettings: Bool {
        return isTrusted
    }

    /// Whether Lintel already showed the system prompt (afterwards it opens System Settings).
    var wasPrompted: Bool { settings[Keys.accessibilityPrompted] }

    /// The earlier copy's signature when it changed since the last launch and Accessibility isn't
    /// granted to this copy yet (`SignatureTracker`); a switch that looks on belongs to that copy.
    var signatureChange: SignatureIdentity? {
        settings[Keys.signatureChangedFrom].map(SignatureIdentity.init(requirement:))
    }

    func refresh() {
        let trusted = Self.isTrusted
        if trusted, settings[Keys.signatureChangedFrom] != nil { settings[Keys.signatureChangedFrom] = nil }
        guard trusted != isTrusted else { return }
        isTrusted = trusted
        onChange?(trusted)
    }

    /// Polls while access is wanted but missing (the notification isn't guaranteed).
    func watch(_ wanted: Bool) {
        if wanted && !isTrusted {
            guard timer == nil else { return }
            let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            timer.tolerance = 0.5
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else {
            timer?.invalidate()
            timer = nil
        }
    }

    /// The first press shows the system prompt (which leads to System Settings), later presses open
    /// the Accessibility list directly (`AccessibilityRequestPlan`).
    func requestAccess() {
        let steps = AccessibilityRequestPlan.steps(trusted: Self.isTrusted, prompted: settings[Keys.accessibilityPrompted])
        settings[Keys.accessibilityPrompted] = true
        for step in steps {
            switch step {
            case .askSystem:
                let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(options)
            case .openSettings:
                openSystemSettings()
            }
        }
        Log.hud.notice("Accessibility requested (\(steps.map { "\($0)" }.joined(separator: ", "), privacy: .public))")
        watch(true)
    }

    func openSystemSettings() {
        NSWorkspace.shared.open(Self.settingsURL)
    }
}
