import AudioToolbox
import CoreAudio
import Foundation
import LintelCore
import Synchronization

/// Output volume and mute of the default output device (public CoreAudio).
@MainActor
protocol VolumeController: AnyObject {
    var device: OutputDeviceInfo? { get }
    var volume: Double { get }
    var isMuted: Bool { get }
    /// The device has a volume Lintel can set (otherwise the keys stay with macOS).
    var canSetVolume: Bool { get }
    /// Volume or mute changed by something other than Lintel (Control Center, AppleScript, …).
    var onExternalChange: (() -> Void)? { get set }
    /// The default output device (or its data source) changed.
    var onDeviceChange: (() -> Void)? { get set }
    func start()
    func stop()
    /// Re-reads the device's values (before each key press, so changes made elsewhere count).
    func refresh()
    func setVolume(_ value: Double)
    func setMuted(_ muted: Bool)
}

/// CoreAudio implementation: the virtual main volume and mute of the default output device, with
/// property listeners for the device, its volume, mute and data source. Writes are coalesced on a
/// serial queue (only the latest pending value is written), and Lintel's own writes are recognised
/// when they come back through the listeners (`EchoFilter`, 0.45 s).
@MainActor
final class CoreAudioVolumeController: VolumeController {
    private(set) var device: OutputDeviceInfo?
    private(set) var volume: Double = 0
    private(set) var isMuted = false
    private(set) var canSetVolume = false
    var onExternalChange: (() -> Void)?
    var onDeviceChange: (() -> Void)?

    /// Counters.
    private(set) var externalChanges = 0
    private(set) var echoesIgnored = 0
    private(set) var writesRequested = 0
    var writesPerformed: Int { writes.performed }

    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private var echo = EchoFilter()
    private var muteEcho = EchoFilter()
    private var running = false
    private var deviceListeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var systemListener: AudioObjectPropertyListenerBlock?
    private let writeQueue = DispatchQueue(label: "com.sashagilliard.lintel.volume-writes", qos: .userInitiated)

    private let writes = CoreAudioWriteCoalescer()

    private static var now: Double { ProcessInfo.processInfo.systemUptime }

    func start() {
        guard !running else { return }
        running = true
        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.defaultDeviceChanged() }
        }
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
        systemListener = block
        attach(to: Self.defaultOutputDevice())
    }

    func stop() {
        guard running else { return }
        running = false
        detach()
        if let systemListener {
            var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, systemListener)
        }
        systemListener = nil
    }

    /// Re-reads everything from the device (used before each key press so changes made elsewhere count).
    func refresh() {
        if !running { attach(to: Self.defaultOutputDevice(), listen: false) }
        readValues()
    }

    func setVolume(_ value: Double) {
        let clamped = Float32(min(1, max(0, value)))
        guard deviceID != kAudioObjectUnknown else { return }
        volume = Double(clamped)
        echo.recordWrite(Double(clamped), now: Self.now)
        writesRequested += 1
        writes.enqueueVolume(clamped, device: deviceID)
        writeQueue.async { [writes] in writes.flush() }
    }

    func setMuted(_ muted: Bool) {
        guard deviceID != kAudioObjectUnknown else { return }
        isMuted = muted
        muteEcho.recordWrite(muted ? 1 : 0, now: Self.now)
        writesRequested += 1
        writes.enqueueMute(muted, device: deviceID)
        writeQueue.async { [writes] in writes.flush() }
    }

    // MARK: Device and listeners

    private func defaultDeviceChanged() {
        attach(to: Self.defaultOutputDevice())
        onDeviceChange?()
    }

    private func attach(to newDevice: AudioObjectID, listen: Bool = true) {
        detach()
        if newDevice != deviceID {
            // Writes to the previous device say nothing about the new one.
            echo = EchoFilter()
            muteEcho = EchoFilter()
        }
        deviceID = newDevice
        guard newDevice != kAudioObjectUnknown else {
            device = nil
            canSetVolume = false
            return
        }
        readValues()
        guard listen else { return }
        var selectors: [AudioObjectPropertyAddress] = [
            Self.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioDevicePropertyScopeOutput),
            Self.address(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput),
            Self.address(kAudioDevicePropertyDataSource, scope: kAudioDevicePropertyScopeOutput),
            Self.address(kAudioObjectPropertyName),
        ]
        // Per-channel volumes too, for devices whose virtual main volume doesn't notify.
        for element: AudioObjectPropertyElement in [kAudioObjectPropertyElementMain, 1, 2] {
            var channel = Self.address(kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeOutput, element: element)
            if AudioObjectHasProperty(newDevice, &channel) { selectors.append(channel) }
        }
        for var address in selectors where AudioObjectHasProperty(newDevice, &address) {
            let selector = address.mSelector
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                MainActor.assumeIsolated { self?.propertyChanged(selector) }
            }
            if AudioObjectAddPropertyListenerBlock(newDevice, &address, .main, block) == noErr {
                deviceListeners.append((address, block))
            }
        }
    }

    private func detach() {
        for (address, block) in deviceListeners {
            var address = address
            AudioObjectRemovePropertyListenerBlock(deviceID, &address, .main, block)
        }
        deviceListeners.removeAll()
    }

    private func propertyChanged(_ selector: AudioObjectPropertySelector) {
        let oldVolume = volume, oldMuted = isMuted, oldDevice = device
        readValues()
        if selector == kAudioDevicePropertyDataSource || selector == kAudioObjectPropertyName {
            if device != oldDevice { onDeviceChange?() }
            return
        }
        let now = Self.now
        let volumeChanged = abs(volume - oldVolume) > 0.0005
        let muteChanged = isMuted != oldMuted
        guard volumeChanged || muteChanged else {
            // Unchanged (or held at the requested values while settling): Lintel's own write echoing back.
            if echo.isSettling(now: now) || muteEcho.isSettling(now: now) { echoesIgnored += 1 }
            return
        }
        let ownVolume = !volumeChanged || echo.isEcho(volume, now: now)
        let ownMute = !muteChanged || muteEcho.isEcho(isMuted ? 1 : 0, now: now)
        if ownVolume && ownMute {
            echoesIgnored += 1
            return
        }
        externalChanges += 1
        onExternalChange?()
    }

    /// Reads the device. While Lintel's own writes are settling (queued or younger than the echo
    /// window) the requested values stay authoritative: a read between a queued mute and volume
    /// write, or before a write lands, must not undo them (or lose steps on fast key repeats).
    private func readValues() {
        guard deviceID != kAudioObjectUnknown else { return }
        let now = Self.now
        var volumeAddress = Self.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioDevicePropertyScopeOutput)
        if !echo.isSettling(now: now), let value: Float32 = Self.read(deviceID, &volumeAddress) { volume = Double(value) }
        var muteAddress = Self.address(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput)
        if !muteEcho.isSettling(now: now) {
            isMuted = (Self.read(deviceID, &muteAddress) as UInt32?).map { $0 != 0 } ?? false
        }
        var settable: DarwinBoolean = false
        canSetVolume = AudioObjectHasProperty(deviceID, &volumeAddress)
            && AudioObjectIsPropertySettable(deviceID, &volumeAddress, &settable) == noErr && settable.boolValue
        device = Self.describe(deviceID)
    }

    // MARK: CoreAudio helpers

    nonisolated static func address(_ selector: AudioObjectPropertySelector,
                                            scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                                            element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    private static func read<T>(_ object: AudioObjectID, _ address: inout AudioObjectPropertyAddress) -> T? {
        guard AudioObjectHasProperty(object, &address) else { return nil }
        var size = UInt32(MemoryLayout<T>.size)
        let pointer = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { pointer.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer) == noErr else { return nil }
        return pointer.pointee
    }

    static func defaultOutputDevice() -> AudioObjectID {
        var address = address(kAudioHardwarePropertyDefaultOutputDevice)
        return read(AudioObjectID(kAudioObjectSystemObject), &address) ?? AudioObjectID(kAudioObjectUnknown)
    }

    static func describe(_ id: AudioObjectID) -> OutputDeviceInfo {
        var nameAddress = address(kAudioObjectPropertyName)
        var name = ""
        if AudioObjectHasProperty(id, &nameAddress) {
            var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            var value: Unmanaged<CFString>?
            if AudioObjectGetPropertyData(id, &nameAddress, 0, nil, &size, &value) == noErr, let value {
                name = value.takeRetainedValue() as String
            }
        }
        var transportAddress = address(kAudioDevicePropertyTransportType)
        let transport = OutputTransport(fourCC: read(id, &transportAddress) ?? 0)
        var sourceAddress = address(kAudioDevicePropertyDataSource, scope: kAudioDevicePropertyScopeOutput)
        let source: UInt32? = read(id, &sourceAddress)
        return OutputDeviceInfo(name: name, transport: transport, dataSource: source.map(fourCC))
    }

    private static func fourCC(_ value: UInt32) -> String {
        let bytes = [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
        return String(bytes: bytes, encoding: .ascii) ?? String(value)
    }
}

/// Pending CoreAudio writes: each write request replaces the pending value, and a flush on the write
/// queue performs only the latest one (so a burst of key presses costs one device write).
final class CoreAudioWriteCoalescer: Sendable {
    private struct Pending {
        var volume: (device: AudioObjectID, value: Float32)?
        var mute: (device: AudioObjectID, value: UInt32)?
        var performed = 0
    }
    private let state = Mutex(Pending())

    var performed: Int { state.withLock { $0.performed } }

    func enqueueVolume(_ value: Float32, device: AudioObjectID) {
        state.withLock { $0.volume = (device, value) }
    }

    func enqueueMute(_ muted: Bool, device: AudioObjectID) {
        state.withLock { $0.mute = (device, muted ? 1 : 0) }
    }

    func flush() {
        let pending = state.withLock { pending -> Pending in
            let copy = pending
            pending.volume = nil
            pending.mute = nil
            return copy
        }
        var performed = 0
        if let mute = pending.mute {
            var value = mute.value
            var address = CoreAudioVolumeController.address(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput)
            if AudioObjectSetPropertyData(mute.device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr {
                performed += 1
            }
        }
        if let volume = pending.volume {
            var value = volume.value
            var address = CoreAudioVolumeController.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                                            scope: kAudioDevicePropertyScopeOutput)
            if AudioObjectSetPropertyData(volume.device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value) == noErr {
                performed += 1
            }
        }
        if performed > 0 { state.withLock { $0.performed += performed } }
    }
}
