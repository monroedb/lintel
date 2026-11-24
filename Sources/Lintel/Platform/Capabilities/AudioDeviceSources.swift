import CoreAudio
import CoreBluetooth
import Foundation
import LintelCore
import ObjectiveC

/// Connected Bluetooth audio devices, without battery levels (public CoreAudio: the device list,
/// transport type, name, model and terminal type; no permission needed).
@MainActor
protocol AudioDeviceConnectionSource: AnyObject {
    var devices: [ConnectedAudioDevice] { get }
    var onChange: (() -> Void)? { get set }
    func start()
}

@MainActor
final class CoreAudioDeviceSource: AudioDeviceConnectionSource {
    private(set) var devices: [ConnectedAudioDevice] = []
    var onChange: (() -> Void)?
    private var listener: AudioObjectPropertyListenerBlock?

    func start() {
        guard listener == nil else { return }
        devices = Self.read()
        var address = Self.address(kAudioHardwarePropertyDevices)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block) == noErr {
            listener = block
        }
    }

    func refresh() {
        let new = Self.read()
        guard new != devices else { return }
        devices = new
        onChange?()
    }

    /// Bluetooth (Classic or LE) devices with output streams, one entry per physical device.
    static func read() -> [ConnectedAudioDevice] {
        var result: [ConnectedAudioDevice] = []
        for id in deviceIDs() {
            let transport = uint32(id, kAudioDevicePropertyTransportType)
            guard transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE,
                  hasOutput(id) else { continue }
            let uid = string(id, kAudioDevicePropertyDeviceUID) ?? "audio-\(id)"
            let address = ConnectedAudioDevice.address(fromUID: uid)
            let key = address ?? uid
            guard !result.contains(where: { $0.id == key }) else { continue }
            let name = string(id, kAudioObjectPropertyName) ?? "Audio device"
            let ids = AudioDeviceClassifier.productAndVendor(fromModelUID: string(id, kAudioDevicePropertyModelUID))
            let model = AudioDeviceClassifier.model(name: name, productID: ids?.product, vendorID: ids?.vendor,
                                                    terminal: terminal(id))
            result.append(ConnectedAudioDevice(id: key, name: name, model: model, address: address))
        }
        return result
    }

    // MARK: CoreAudio helpers

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func deviceIDs() -> [AudioObjectID] {
        var address = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func uint32(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32 {
        var address = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr ? value : 0
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0) }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func outputStreams(_ id: AudioObjectID) -> [AudioObjectID] {
        var address = address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var streams = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &streams) == noErr else { return [] }
        return streams
    }

    private static func hasOutput(_ id: AudioObjectID) -> Bool { !outputStreams(id).isEmpty }

    private static func terminal(_ id: AudioObjectID) -> AudioDeviceClassifier.Terminal {
        guard let stream = outputStreams(id).first else { return .unknown }
        switch uint32(stream, kAudioStreamPropertyTerminalType) {
        case kAudioStreamTerminalTypeHeadphones: return .headphones
        case kAudioStreamTerminalTypeHeadsetMicrophone: return .headset
        case kAudioStreamTerminalTypeSpeaker: return .speaker
        default: return .unknown
        }
    }
}

/// Whether Lintel may use Bluetooth (read without prompting through `CBManager.authorization`).
enum BluetoothAccess: String {
    case notDetermined, denied, restricted, allowed

    static var current: BluetoothAccess {
        switch CBManager.authorization {
        case .allowedAlways: return .allowed
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }
}

/// Battery levels of connected Bluetooth audio devices (undocumented IOBluetooth device
/// properties read by key-value coding; private and optional).
@MainActor
protocol AudioDeviceBattery: AnyObject {
    /// Why levels are or aren't available ("available", "needs Bluetooth access", …).
    var status: String { get }
    var isAvailable: Bool { get }
    func levels(for device: ConnectedAudioDevice) -> DeviceBatteryLevels?
    /// Shows the system's Bluetooth prompt (only ever called from a button in Settings).
    func requestAccess()
    var onAccessChange: (() -> Void)? { get set }
}

/// Reads `batteryPercentLeft/Right/Case/Single` from IOBluetooth's paired-device objects. The
/// framework is loaded with `dlopen` and only touched once Bluetooth access is granted, so Lintel
/// never triggers the Bluetooth prompt on its own; every selector is checked before use, and a
/// missing one degrades to "no levels".
@MainActor
final class BluetoothDeviceBattery: NSObject, AudioDeviceBattery, CBCentralManagerDelegate {
    /// Settings switch (`capability.audioDeviceBattery`).
    var enabled = true { didSet { reportToRegistry() } }
    var onAccessChange: (() -> Void)?
    private var central: CBCentralManager?
    private var deviceClass: AnyClass?
    private var loadAttempted = false
    private var reportedStatus: PrivateCapabilityRegistry.Status?

    static let capabilityID = "audioDeviceBattery"

    /// Reports availability to the private-capability registry. Follows `status`, so the
    /// framework is only loaded once Bluetooth access is granted.
    func reportToRegistry(_ registry: PrivateCapabilityRegistry = .shared) {
        let current: PrivateCapabilityRegistry.Status
        if !enabled {
            current = .switchedOff
        } else if BluetoothAccess.current != .allowed {
            current = .unavailable(status)
        } else {
            current = loadClass() == nil ? .unavailable("IOBluetoothDevice not found") : .available
        }
        guard current != reportedStatus else { return }
        reportedStatus = current
        registry.report(id: Self.capabilityID, title: "Bluetooth device batteries (IOBluetooth)",
                        setting: Keys.capabilityDeviceBattery, status: current)
    }

    private static let batteryKeys = ["batteryPercentLeft", "batteryPercentRight", "batteryPercentCase", "batteryPercentSingle"]

    var isAvailable: Bool { enabled && BluetoothAccess.current == .allowed && loadClass() != nil }

    var status: String {
        if !enabled { return "switched off" }
        switch BluetoothAccess.current {
        case .allowed: return loadClass() == nil ? "unavailable on this macOS" : "available"
        case .notDetermined: return "needs Bluetooth access"
        case .denied: return "Bluetooth access denied"
        case .restricted: return "Bluetooth access restricted"
        }
    }

    func levels(for device: ConnectedAudioDevice) -> DeviceBatteryLevels? {
        guard isAvailable, let cls = loadClass() else { return nil }
        for candidate in pairedDevices(cls) where bool(candidate, "isConnected") {
            let address = string(candidate, "addressString")?.lowercased().replacingOccurrences(of: ":", with: "-")
            let matches = (device.address != nil && address == device.address) || string(candidate, "name") == device.name
            guard matches else { continue }
            var values: [String: Int] = [:]
            for key in Self.batteryKeys where candidate.responds(to: NSSelectorFromString(key)) {
                values[key] = (candidate.value(forKey: key) as? NSNumber)?.intValue
            }
            let levels = DeviceBatteryLevels(left: values["batteryPercentLeft"], right: values["batteryPercentRight"],
                                             chargingCase: values["batteryPercentCase"], single: values["batteryPercentSingle"])
            return levels.isEmpty ? nil : levels
        }
        return nil
    }

    func requestAccess() {
        guard central == nil else { return }
        central = CBCentralManager(delegate: self, queue: .main)
    }

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            reportToRegistry()
            onAccessChange?()
        }
    }

    // MARK: Runtime resolution

    private func loadClass() -> AnyClass? {
        if !loadAttempted {
            loadAttempted = true
            _ = dlopen("/System/Library/Frameworks/IOBluetooth.framework/IOBluetooth", RTLD_LAZY)
            deviceClass = NSClassFromString("IOBluetoothDevice")
        }
        return deviceClass
    }

    private func pairedDevices(_ cls: AnyClass) -> [NSObject] {
        let selector = NSSelectorFromString("pairedDevices")
        guard let meta = object_getClass(cls), class_respondsToSelector(meta, selector),
              let implementation = class_getMethodImplementation(meta, selector) else { return [] }
        typealias Getter = @convention(c) (AnyClass, Selector) -> Unmanaged<NSArray>?
        let getter = unsafeBitCast(implementation, to: Getter.self)
        return getter(cls, selector)?.takeUnretainedValue() as? [NSObject] ?? []
    }

    private func bool(_ object: NSObject, _ method: String) -> Bool {
        let selector = NSSelectorFromString(method)
        guard object.responds(to: selector), let implementation = object.method(for: selector) else { return false }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(implementation, to: Getter.self)(object, selector)
    }

    private func string(_ object: NSObject, _ method: String) -> String? {
        guard object.responds(to: NSSelectorFromString(method)) else { return nil }
        return object.value(forKey: method) as? String
    }
}
