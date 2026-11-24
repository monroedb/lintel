import Foundation
import IOKit.ps
import LintelCore

/// The Mac's battery and Low Power Mode (public IOKit power sources and
/// `ProcessInfo.isLowPowerModeEnabled`). Event-driven: no polling.
@MainActor
protocol PowerSource: AnyObject {
    var snapshot: PowerSnapshot { get }
    var onChange: ((PowerSnapshot) -> Void)? { get set }
    func start()
}

@MainActor
final class IOKitPowerSource: PowerSource {
    private(set) var snapshot: PowerSnapshot
    var onChange: ((PowerSnapshot) -> Void)?
    private var runLoopSource: CFRunLoopSource?
    private var observer: NSObjectProtocol?

    init() {
        snapshot = Self.read()
    }

    func start() {
        guard runLoopSource == nil else { return }
        // Called on the main run loop whenever any power source's information changes.
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let source = Unmanaged<IOKitPowerSource>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { source.refresh() }
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = source
        }
        observer = NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil,
                                                          queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    func refresh() {
        let new = Self.read()
        guard new != snapshot else { return }
        snapshot = new
        onChange?(new)
    }

    /// Reads every power source's description; `PowerSnapshot.parse` picks the internal battery.
    static func read() -> PowerSnapshot {
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
            return .noBattery(lowPowerMode: lowPower)
        }
        let descriptions = list.compactMap { IOPSGetPowerSourceDescription(info, $0)?.takeUnretainedValue() as? [String: Any] }
        return PowerSnapshot.parse(descriptions: descriptions, lowPowerMode: lowPower)
    }
}
