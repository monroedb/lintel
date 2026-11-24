import AppKit
import LintelCore

/// The custom-duration window. The island panels never become key, so
/// typing goes to this small dark panel: borderless and non-activating, so it takes the keyboard
/// without activating Lintel or taking the active app's place (verified with real key events while
/// another app stayed frontmost). Return starts, Escape or a click elsewhere cancels.
@MainActor
final class TimerEntryWindow: NSObject, NSTextFieldDelegate, NSWindowDelegate {
    static let size = NSSize(width: 300, height: 132)

    /// Called with the parsed duration (seconds) when the user starts the timer.
    var onStart: ((Double) -> Void)?

    private var panel: TimerEntryPanel?
    private let field = NSTextField()
    private let hintLabel = NSTextField(labelWithString: "")
    private let startButton = NSButton(title: "Start", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)

    var isVisible: Bool { panel?.isVisible ?? false }
    var isKey: Bool { panel?.isKeyWindow ?? false }
    var frame: CGRect? { panel?.isVisible == true ? panel?.frame : nil }
    var text: String { field.stringValue }
    var hint: String { hintLabel.stringValue }

    /// Shows the window centred under the notch area of `screen`, below the open card's area.
    func show(on screen: NSScreen, prefill: String) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        field.stringValue = prefill
        validate()
        let cardHeight = PresentationMetrics.expandedSize(for: .timer).height
        let origin = NSPoint(x: (screen.frame.midX - Self.size.width / 2).rounded(),
                             y: screen.frame.maxY - cardHeight - 12 - Self.size.height)
        panel.setFrame(NSRect(origin: origin, size: Self.size), display: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
        panel.invalidateShadow()
    }

    func close() {
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
    }

    // MARK: Building

    private func makePanel() -> TimerEntryPanel {
        let panel = TimerEntryPanel(contentRect: NSRect(origin: .zero, size: Self.size))
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.close() }

        // Solid near-black like the island (a translucent material turns light grey over light
        // windows, and the dark controls then lose contrast).
        let background = NSView(frame: NSRect(origin: .zero, size: Self.size))
        background.wantsLayer = true
        background.layer?.backgroundColor = NSColor(white: 0.07, alpha: 0.97).cgColor
        background.layer?.cornerRadius = 16
        background.layer?.borderWidth = 1
        background.layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor

        let title = NSTextField(labelWithString: "New timer")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .labelColor

        field.font = .monospacedDigitSystemFont(ofSize: 17, weight: .medium)
        field.placeholderString = "25, 1:30 or 1h 30m"
        field.bezelStyle = .roundedBezel
        field.isBezeled = true
        field.focusRingType = .default
        field.delegate = self
        field.target = self
        field.action = #selector(startPressed)
        field.setAccessibilityLabel("Timer duration")

        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.lineBreakMode = .byTruncatingTail

        startButton.keyEquivalent = "\r"
        startButton.bezelColor = Brand.copperNS
        startButton.target = self
        startButton.action = #selector(startPressed)
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.target = self
        cancelButton.action = #selector(cancelPressed)

        let buttons = NSStackView(views: [NSView(), cancelButton, startButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        let stack = NSStackView(views: [title, field, hintLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
        stack.edgeInsets = NSEdgeInsets(top: 13, left: 16, bottom: 13, right: 16)
        stack.setCustomSpacing(5, after: field)
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        let width = Self.size.width - 32
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: background.bottomAnchor),
            field.widthAnchor.constraint(equalToConstant: width),
            hintLabel.widthAnchor.constraint(equalToConstant: width),
            buttons.widthAnchor.constraint(equalToConstant: width),
        ])
        panel.contentView = background
        return panel
    }

    // MARK: Input

    private var parsed: Double? { TimerDuration.parse(field.stringValue) }

    private func validate() {
        let seconds = parsed
        hintLabel.stringValue = TimerFormat.entryHint(for: seconds)
        hintLabel.textColor = seconds == nil && !field.stringValue.isEmpty
            ? NSColor(srgbRed: 0xFF / 255, green: 0x5A / 255, blue: 0x47 / 255, alpha: 1)
            : .secondaryLabelColor
        startButton.isEnabled = seconds != nil
    }

    func controlTextDidChange(_ obj: Notification) { validate() }

    @objc private func startPressed() {
        guard let seconds = parsed else {
            NSSound.beep()
            return
        }
        close()
        onStart?(seconds)
    }

    @objc private func cancelPressed() { close() }

    /// A click elsewhere cancels.
    func windowDidResignKey(_ notification: Notification) { close() }
}

/// Borderless, non-activating, key-capable; above full-screen spaces.
final class TimerEntryPanel: NSPanel {
    var onCancel: (() -> Void)?

    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.popUpMenuWindow)))
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = false
        isMovableByWindowBackground = true
        appearance = NSAppearance(named: .darkAqua)
        animationBehavior = .utilityWindow
        title = "New timer"
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) { onCancel?() }
}
