import AppKit
import LintelCore
import SwiftUI

/// Small window shown when a HUD is switched on without Accessibility access (Accessibility step — "needs your permission to hide and replace the system HUDs", Grant
/// Permission).
/// Nothing is requested until the user presses the button.
@MainActor
final class AccessibilityOnboardingWindow: NSObject, NSWindowDelegate {
    private let access: AccessibilityAccess
    private var window: NSWindow?

    init(access: AccessibilityAccess) {
        self.access = access
    }

    func present(for kind: HUDKind) {
        let view = AccessibilityOnboardingView(kind: kind, access: access,
                                               close: { [weak self] in self?.window?.close() })
        if let window {
            window.contentViewController = NSHostingController(rootView: view)
        } else {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                                  styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: view)
            window.delegate = self
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {}
}

struct AccessibilityOnboardingView: View {
    let kind: HUDKind
    let access: AccessibilityAccess
    let close: () -> Void

    /// Asked before (or the signature changed) and still untrusted: explain the stale switch.
    private var reAdd: Bool {
        HUDAccessGuidance.evaluate(hudEnabled: true, trusted: access.isTrusted, prompted: access.wasPrompted,
                                   signatureChanged: access.signatureChange != nil) == .reAdd
    }

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.black)
                    .frame(width: 120, height: 30)
                HStack(spacing: 8) {
                    Image(systemName: kind == .volume ? "speaker.wave.2.fill" : "sun.max.fill")
                        .font(.system(size: 11, weight: .semibold))
                    Capsule().fill(Color.white).frame(width: 40, height: 3.5)
                }
                .foregroundStyle(.white)
            }
            .padding(.top, 8)
            Text(reAdd ? "macOS doesn’t trust this copy of Lintel yet"
                       : "Let Lintel show \(kind == .volume ? "volume" : "brightness") changes")
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            Text("To take over the volume and brightness keys and hide the system’s own indicator, Lintel needs Accessibility access. macOS asks you to confirm it in System Settings › Privacy & Security › Accessibility.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if reAdd {
                // An entry that looks on was recorded for another signature (fixes record, 2026-11-22 HUD).
                Text("\(access.signatureChange == nil ? "" : "Lintel was replaced since it last ran, so permissions given to the earlier copy don’t apply to this one. ")If Lintel is already switched on in that list, the switch belongs to an earlier copy, and switching it off and on doesn’t help: select Lintel, remove it with −, then click + and choose \(Bundle.main.bundlePath).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if access.isTrusted {
                Label("Access granted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            HStack(spacing: 10) {
                Button(access.isTrusted ? "Done" : "Not Now") { close() }
                    .keyboardShortcut(.cancelAction)
                if !access.isTrusted {
                    Button(access.wasPrompted ? "Open Accessibility Settings…" : "Allow in System Settings…") { access.requestAccess() }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.top, 4)
        }
        .padding(24)
        .frame(width: 400)
        .tint(Brand.copper)
    }
}
