import AppKit
import CoreAudio
import Foundation
import LintelCore

/// Levels for the live waveform (Core Audio process taps + vDSP, public API). Without a
/// running source the waveform is simulated.
@MainActor
protocol SpectrumSource: AnyObject {
    var isRunning: Bool { get }
    /// A start is in flight (the tap is being set up off the main thread).
    var isStarting: Bool { get }
    /// Band levels 0…1, about 30 times a second, on the main actor.
    var onLevels: (([Float]) -> Void)? { get set }
    var onStarted: (() -> Void)? { get set }
    var onFailure: ((String) -> Void)? { get set }
    /// Taps the given processes (and their audio helper processes with the same bundle prefix).
    /// Returns at once; a repeated request for the same processes is ignored while it runs or starts.
    func start(processIDs: [pid_t], bundlePrefix: String?)
    func stop()
}

/// A private process tap (`CATapDescription` + `AudioHardwareCreateProcessTap`, macOS 14.2+) inside
/// a private aggregate device; an IO block mixes the tap to mono and feeds `SpectrumAnalyzer`.
/// The first tap makes macOS ask for audio-capture permission (`NSAudioCaptureUsageDescription`);
/// without it the tap delivers silence and Lintel switches to the simulated waveform.
///
/// Setup and teardown run on their own queue: creating the IO proc waits for the audio server,
/// which waits for the user to answer the audio-capture prompt. On the main thread that froze the
/// whole island (no HUDs or animations) until the prompt was answered.
@MainActor
final class ProcessTapSpectrumSource: SpectrumSource {
    var onLevels: (([Float]) -> Void)?
    var onStarted: (() -> Void)?
    var onFailure: ((String) -> Void)?
    private(set) var isRunning = false
    private(set) var isStarting = false
    private(set) var tappedProcesses: [AudioObjectID] = []
    private var request: TapRequest?
    private var session: TapSession?
    /// Bumped by every stop; a setup that finishes for an older generation is discarded.
    private var generation = 0
    private let setupQueue = DispatchQueue(label: "com.sashagilliard.lintel.spectrum-setup", qos: .userInitiated)
    private let ioQueue = DispatchQueue(label: "com.sashagilliard.lintel.spectrum", qos: .userInteractive)

    func start(processIDs: [pid_t], bundlePrefix: String?) {
        let request = TapRequest(processIDs: processIDs, bundlePrefix: bundlePrefix)
        if request == self.request, isRunning || isStarting { return }
        stop()
        self.request = request
        isStarting = true
        let token = generation
        // Weak in both closures: the processor holding this closure belongs to this source.
        let deliver: @Sendable ([Float]) -> Void = { [weak self] levels in
            guard let self else { return }
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.isRunning, self.generation == token else { return }
                    self.onLevels?(levels)
                }
            }
        }
        let ioQueue = self.ioQueue
        setupQueue.async { [self] in
            let result = TapSession.create(request, ioQueue: ioQueue, deliver: deliver)
            DispatchQueue.main.async { [self] in
                MainActor.assumeIsolated { self.finishStart(result, token: token) }
            }
        }
    }

    private func finishStart(_ result: TapSession.Result, token: Int) {
        guard token == generation else {
            // Stopped (or restarted) while the tap was being set up.
            if case .started(let session) = result { setupQueue.async { session.destroy() } }
            return
        }
        isStarting = false
        switch result {
        case .started(let session):
            self.session = session
            tappedProcesses = session.processes
            isRunning = true
            onStarted?()
        case .failed(let reason):
            request = nil
            onFailure?(reason)
        }
    }

    func stop() {
        generation &+= 1
        request = nil
        isStarting = false
        isRunning = false
        tappedProcesses = []
        if let session {
            self.session = nil
            setupQueue.async { session.destroy() }
        }
    }
}

/// What a tap is for: the processes to tap and the bundle prefix of their helper processes.
private struct TapRequest: Equatable, Sendable {
    var processIDs: [pid_t]
    var bundlePrefix: String?
}

/// The CoreAudio objects of one running tap, created and destroyed on the setup queue.
private final class TapSession: @unchecked Sendable {
    enum Result: Sendable {
        case started(TapSession)
        case failed(String)
    }

    let tapID: AudioObjectID
    let aggregateID: AudioObjectID
    let procID: AudioDeviceIOProcID
    let processor: TapProcessor
    let processes: [AudioObjectID]

    private init(tapID: AudioObjectID, aggregateID: AudioObjectID, procID: AudioDeviceIOProcID,
                 processor: TapProcessor, processes: [AudioObjectID]) {
        self.tapID = tapID
        self.aggregateID = aggregateID
        self.procID = procID
        self.processor = processor
        self.processes = processes
    }

    static func create(_ request: TapRequest, ioQueue: DispatchQueue,
                       deliver: @escaping @Sendable ([Float]) -> Void) -> Result {
        let objects = processObjects(for: request.processIDs, bundlePrefix: request.bundlePrefix)
        guard !objects.isEmpty else { return .failed("no audio process for the source") }
        let description = CATapDescription(stereoMixdownOfProcesses: objects)
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .unmuted
        var tap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr else { return .failed("tap creation failed (\(status))") }
        let aggregateUID = "com.sashagilliard.lintel.spectrum.\(UUID().uuidString)"
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Lintel Waveform",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString,
                                               kAudioSubTapDriftCompensationKey: true]],
        ]
        var device = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device)
        guard status == noErr else {
            AudioHardwareDestroyProcessTap(tap)
            return .failed("aggregate device failed (\(status))")
        }
        let format = tapFormat(tap)
        let processor = TapProcessor(sampleRate: format?.mSampleRate ?? 48_000,
                                     channels: Int(max(1, format?.mChannelsPerFrame ?? 2)))
        processor.deliver = deliver
        var proc: AudioDeviceIOProcID?
        // @Sendable: CoreAudio calls this on its IO thread. Written in main-actor code without it,
        // the block inherited main-actor isolation and Swift 6's runtime check trapped (the 15:11
        // crashes).
        status = AudioDeviceCreateIOProcIDWithBlock(&proc, device, ioQueue) { @Sendable _, input, _, _, _ in
            processor.consume(input)
        }
        guard status == noErr, let proc else {
            AudioHardwareDestroyAggregateDevice(device)
            AudioHardwareDestroyProcessTap(tap)
            return .failed("IO proc failed (\(status))")
        }
        status = AudioDeviceStart(device, proc)
        guard status == noErr else {
            AudioDeviceDestroyIOProcID(device, proc)
            AudioHardwareDestroyAggregateDevice(device)
            AudioHardwareDestroyProcessTap(tap)
            return .failed("start failed (\(status))")
        }
        return .started(TapSession(tapID: tap, aggregateID: device, procID: proc, processor: processor, processes: objects))
    }

    func destroy() {
        AudioDeviceStop(aggregateID, procID)
        AudioDeviceDestroyIOProcID(aggregateID, procID)
        AudioHardwareDestroyAggregateDevice(aggregateID)
        AudioHardwareDestroyProcessTap(tapID)
        processor.deliver = nil
    }

    /// Audio process objects for the PIDs plus helper processes whose bundle ID shares the prefix
    /// (e.g. a player's separate audio process, TIDAL's player process).
    static func processObjects(for pids: [pid_t], bundlePrefix: String?) -> [AudioObjectID] {
        var result: [AudioObjectID] = []
        for pid in pids {
            var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                                     mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            var qualifier = pid
            var object = AudioObjectID(kAudioObjectUnknown)
            var size = UInt32(MemoryLayout<AudioObjectID>.size)
            if AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                          UInt32(MemoryLayout<pid_t>.size), &qualifier, &size, &object) == noErr,
               object != AudioObjectID(kAudioObjectUnknown) {
                result.append(object)
            }
        }
        if let bundlePrefix, !bundlePrefix.isEmpty {
            var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                     mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            var size: UInt32 = 0
            if AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr, size > 0 {
                var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
                if AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &objects) == noErr {
                    for object in objects where !result.contains(object) {
                        if let bundle = bundleID(of: object), bundle == bundlePrefix || bundle.hasPrefix(bundlePrefix + ".") {
                            result.append(object)
                        }
                    }
                }
            }
        }
        return result
    }

    private static func bundleID(of process: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(process, &address, 0, nil, &size, $0) }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func tapFormat(_ tap: AudioObjectID) -> AudioStreamBasicDescription? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &format) == noErr else { return nil }
        return format
    }
}

/// Runs on the tap's IO queue: mixes float samples to mono, keeps the last FFT window and analyses
/// it about 30 times a second.
private final class TapProcessor: @unchecked Sendable {
    /// Called on the audio IO thread; @Sendable so the closure (set from main-actor code) carries
    /// no main-actor isolation of its own.
    var deliver: (@Sendable ([Float]) -> Void)?
    private let analyzer: SpectrumAnalyzer
    private let channels: Int
    private var window: [Float]
    private var framesSinceAnalysis = 0
    private let framesPerAnalysis: Int

    init(sampleRate: Double, channels: Int) {
        analyzer = SpectrumAnalyzer(fftSize: 1024, bands: 6, sampleRate: sampleRate)
        self.channels = channels
        window = []
        window.reserveCapacity(analyzer.fftSize * 2)
        framesPerAnalysis = max(256, Int(sampleRate / 30))
    }

    func consume(_ list: UnsafePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        guard let first = buffers.first, let data = first.mData else { return }
        let interleavedChannels = Int(max(1, first.mNumberChannels))
        let samples = data.assumingMemoryBound(to: Float.self)
        let count = Int(first.mDataByteSize) / MemoryLayout<Float>.size
        let frames = count / interleavedChannels
        let planar = buffers.count > 1 && interleavedChannels == 1
        for frame in 0..<frames {
            var sum: Float = 0
            if planar {
                for buffer in buffers {
                    if let channel = buffer.mData?.assumingMemoryBound(to: Float.self) { sum += channel[frame] }
                }
                sum /= Float(buffers.count)
            } else {
                for channel in 0..<interleavedChannels { sum += samples[frame * interleavedChannels + channel] }
                sum /= Float(interleavedChannels)
            }
            window.append(sum)
        }
        if window.count > analyzer.fftSize { window.removeFirst(window.count - analyzer.fftSize) }
        framesSinceAnalysis += frames
        guard framesSinceAnalysis >= framesPerAnalysis else { return }
        framesSinceAnalysis = 0
        let levels = window.withUnsafeBufferPointer { analyzer.process($0) }
        deliver?(levels)
    }
}
