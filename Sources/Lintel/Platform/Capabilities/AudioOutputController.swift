import CoreAudio
import Foundation
import LintelCore

/// Output devices for the player's output button (CoreAudio
/// device names for local outputs). Public CoreAudio only; no permission involved.
@MainActor
protocol AudioOutputController: AnyObject {
    var devices: [AudioOutputDevice] { get }
    var defaultDeviceID: UInt32? { get }
    var onChange: (() -> Void)? { get set }
    @discardableResult func select(_ device: AudioOutputDevice) -> Bool
}

@MainActor
final class CoreAudioOutputController: AudioOutputController {
    private(set) var devices: [AudioOutputDevice] = []
    private(set) var defaultDeviceID: UInt32?
    var onChange: (() -> Void)?
    private var listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    /// MacBooks show a laptop glyph for the built-in speakers.
    let builtInIsLaptop: Bool = {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: max(1, size))
        sysctlbyname("hw.model", &model, &size, nil, 0)
        let name = String(decoding: model.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return name.contains("MacBook") || name.hasPrefix("Mac14,") || name.hasPrefix("Mac15,") || name.hasPrefix("Mac16,")
            || name.hasPrefix("Mac17,")
    }()

    init() {
        refresh()
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice] {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block) == noErr {
                listeners.append((address, block))
            }
        }
    }

    func invalidate() {
        for (address, block) in listeners {
            var address = address
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
        }
        listeners.removeAll()
    }

    func refresh() {
        let ids: [AudioObjectID] = Self.array(of: AudioObjectID.self, object: AudioObjectID(kAudioObjectSystemObject),
                                              selector: kAudioHardwarePropertyDevices)
        devices = ids.compactMap { id in
            guard Self.hasOutputStreams(id) else { return nil }
            let transport = Self.scalar(UInt32.self, object: id, selector: kAudioDevicePropertyTransportType) ?? 0
            return AudioOutputDevice(id: id,
                                     uid: Self.string(object: id, selector: kAudioDevicePropertyDeviceUID) ?? "\(id)",
                                     name: Self.string(object: id, selector: kAudioObjectPropertyName) ?? "Output",
                                     transport: AudioTransport(fourCC: transport))
        }
        defaultDeviceID = Self.scalar(AudioObjectID.self, object: AudioObjectID(kAudioObjectSystemObject),
                                      selector: kAudioHardwarePropertyDefaultOutputDevice)
        onChange?()
    }

    var defaultDevice: AudioOutputDevice? { devices.first { $0.id == defaultDeviceID } }

    @discardableResult
    func select(_ device: AudioOutputDevice) -> Bool {
        var id = AudioObjectID(device.id)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                                UInt32(MemoryLayout<AudioObjectID>.size), &id)
        return status == noErr
    }

    // MARK: CoreAudio helpers

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func hasOutputStreams(_ id: AudioObjectID) -> Bool {
        var address = address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func scalar<T>(_ type: T.Type, object: AudioObjectID, selector: AudioObjectPropertySelector) -> T? {
        var address = address(selector)
        var size = UInt32(MemoryLayout<T>.size)
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
        defer { pointer.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer) == noErr else { return nil }
        return pointer.load(as: T.self)
    }

    private static func array<T>(of type: T.Type, object: AudioObjectID, selector: AudioObjectPropertySelector) -> [T] {
        var address = address(selector)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<T>.stride
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
        defer { pointer.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer) == noErr else { return [] }
        let typed = pointer.bindMemory(to: T.self, capacity: count)
        return Array(UnsafeBufferPointer(start: typed, count: count))
    }

    private static func string(object: AudioObjectID, selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
