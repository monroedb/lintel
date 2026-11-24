import AppKit
import CoreGraphics
import LintelCore

/// Reads and writes display brightness (built-in brightness through DisplayServices — no
/// public API works on Apple-silicon panels).
@MainActor
protocol BrightnessController: AnyObject {
    /// Whether the backend can be used at all (framework present, switched on, behaving).
    var isAvailable: Bool { get }
    func canAdjust(_ display: CGDirectDisplayID) -> Bool
    func brightness(of display: CGDirectDisplayID) -> Double?
    /// Sets the brightness; with `ramp` > 0 the change is spread over that many seconds.
    func setBrightness(_ value: Double, of display: CGDirectDisplayID, ramp: Double)
    /// True while Lintel's own change is in progress or younger than the echo window (0.45 s), so a
    /// read isn't mistaken for a change made elsewhere.
    var isSettling: Bool { get }
    /// The level the next key press steps from: Lintel's last target while its change is settling
    /// (a Smooth ramp is still moving), otherwise the display's current brightness.
    func currentLevel(of display: CGDirectDisplayID) -> Double?
}

/// DisplayServices adapter, resolved with `dlopen`/`dlsym` (never linked). Only the get, set and
/// can-change functions are used; the smooth Smooth-speed change is Lintel's own short ramp of plain
/// sets, and changes made elsewhere are picked up by reading the value again (at each key press and
/// while the HUD is shown) instead of registering for the private change notifications.
@MainActor
final class DisplayServicesBrightnessController: BrightnessController {
    static let capabilityID = "displayServices"
    private static let frameworkPath = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"

    private typealias GetFunction = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFunction = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private typealias CanChangeFunction = @convention(c) (CGDirectDisplayID) -> Bool

    private var getFunction: GetFunction?
    private var setFunction: SetFunction?
    private var canChangeFunction: CanChangeFunction?
    private let settings: SettingsStore
    private let registry: PrivateCapabilityRegistry
    private var rampTask: Task<Void, Never>?
    private var verifiedWrite = false
    private(set) var status: PrivateCapabilityRegistry.Status = .unavailable("not loaded")
    /// Writes performed.
    private(set) var writes = 0
    private var echo = EchoFilter()

    init(settings: SettingsStore, registry: PrivateCapabilityRegistry = .shared) {
        self.settings = settings
        self.registry = registry
        reload()
    }

    var isAvailable: Bool { status.isUsable }

    /// Resolves the symbols (again) and reports the result; also applies the capability switch.
    func reload() {
        if !settings[Keys.displayServicesCapability] {
            setStatus(.switchedOff)
            return
        }
        if case .misbehaving = status { registry.report(id: Self.capabilityID, title: title, setting: Keys.displayServicesCapability, status: status); return }
        guard let handle = dlopen(Self.frameworkPath, RTLD_LAZY) else {
            setStatus(.unavailable("framework not found"))
            return
        }
        guard let get = dlsym(handle, "DisplayServicesGetBrightness"),
              let set = dlsym(handle, "DisplayServicesSetBrightness"),
              let can = dlsym(handle, "DisplayServicesCanChangeBrightness") else {
            setStatus(.unavailable("symbols missing"))
            return
        }
        getFunction = unsafeBitCast(get, to: GetFunction.self)
        setFunction = unsafeBitCast(set, to: SetFunction.self)
        canChangeFunction = unsafeBitCast(can, to: CanChangeFunction.self)
        setStatus(.available)
    }

    private var title: String { "Built-in display brightness (DisplayServices)" }

    private func setStatus(_ newValue: PrivateCapabilityRegistry.Status) {
        status = newValue
        registry.report(id: Self.capabilityID, title: title, setting: Keys.displayServicesCapability, status: newValue)
    }

    func canAdjust(_ display: CGDirectDisplayID) -> Bool {
        guard isAvailable, let canChangeFunction else { return false }
        return canChangeFunction(display) && brightness(of: display) != nil
    }

    func brightness(of display: CGDirectDisplayID) -> Double? {
        guard isAvailable, let getFunction else { return nil }
        var value: Float = -1
        guard getFunction(display, &value) == 0 else { return nil }
        guard value.isFinite, value >= -0.001, value <= 1.001 else {
            setStatus(.misbehaving("read \(value)"))
            return nil
        }
        return Double(min(1, max(0, value)))
    }

    func setBrightness(_ value: Double, of display: CGDirectDisplayID, ramp: Double) {
        guard isAvailable else { return }
        rampTask?.cancel()
        let target = min(1, max(0, value))
        targets[display] = target
        guard ramp > 0, let start = brightness(of: display), abs(start - target) > 0.001 else {
            write(target, display)
            return
        }
        // Smooth speed: about 60 small steps per second over the ramp.
        let steps = max(2, Int((ramp * 60).rounded()))
        rampTask = Task { [weak self] in
            for index in 1...steps {
                guard !Task.isCancelled, let self else { return }
                let t = Double(index) / Double(steps)
                let eased = 1 - pow(1 - t, 2)
                self.write(start + (target - start) * eased, display)
                if index < steps { try? await Task.sleep(for: .seconds(ramp / Double(steps))) }
            }
        }
    }

    var isSettling: Bool { echo.isSettling(now: ProcessInfo.processInfo.systemUptime) }

    private var targets: [CGDirectDisplayID: Double] = [:]

    func currentLevel(of display: CGDirectDisplayID) -> Double? {
        if isSettling, let target = targets[display] { return target }
        return brightness(of: display)
    }

    private func write(_ value: Double, _ display: CGDirectDisplayID) {
        guard let setFunction else { return }
        writes += 1
        echo.recordWrite(value, now: ProcessInfo.processInfo.systemUptime)
        _ = setFunction(display, Float(value))
        // The first write is read back once: if the value doesn't stick, the capability is treated as
        // misbehaving and brightness keys go back to macOS.
        if !verifiedWrite {
            verifiedWrite = true
            if let readBack = brightness(of: display), abs(readBack - value) > 0.02 {
                setStatus(.misbehaving(String(format: "wrote %.3f, read %.3f", value, readBack)))
            }
        }
    }
}
