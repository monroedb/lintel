import Foundation

/// Audio device families the connectivity alert recognises.
/// Symbols are public SF Symbols, newest name first with older fallbacks.
public enum AudioDeviceModel: String, CaseIterable, Sendable, Codable {
    case airpods, airpods3, airpods4, airpodsPro, airpodsPro2, airpodsPro3, airpodsMax
    case powerbeats, beatsHeadphones, beatsEarbuds
    case homepod, homepodMini
    case headphones, earbuds, speaker

    public var displayName: String {
        switch self {
        case .airpods: return "AirPods"
        case .airpods3: return "AirPods (3rd generation)"
        case .airpods4: return "AirPods 4"
        case .airpodsPro: return "AirPods Pro"
        case .airpodsPro2: return "AirPods Pro 2"
        case .airpodsPro3: return "AirPods Pro 3"
        case .airpodsMax: return "AirPods Max"
        case .powerbeats: return "Powerbeats"
        case .beatsHeadphones: return "Beats"
        case .beatsEarbuds: return "Beats"
        case .homepod: return "HomePod"
        case .homepodMini: return "HomePod mini"
        case .headphones: return "Headphones"
        case .earbuds: return "Earbuds"
        case .speaker: return "Speaker"
        }
    }

    /// SF Symbol names to try in order (availability differs between macOS versions).
    public var symbolCandidates: [String] {
        switch self {
        case .airpods: return ["airpods"]
        case .airpods3: return ["airpods.gen3", "airpods"]
        case .airpods4: return ["airpods.gen4", "airpods.gen3", "airpods"]
        case .airpodsPro, .airpodsPro2, .airpodsPro3: return ["airpodspro", "airpods.pro", "airpods"]
        case .airpodsMax: return ["airpodsmax", "airpods.max", "headphones"]
        case .powerbeats: return ["beats.powerbeats.pro", "beats.earphones", "earbuds"]
        case .beatsHeadphones: return ["beats.headphones", "headphones"]
        case .beatsEarbuds: return ["beats.fit.pro", "beats.earphones", "earbuds"]
        case .homepod: return ["homepod.fill", "homepod"]
        case .homepodMini: return ["homepod.mini.fill", "homepod.mini"]
        case .headphones: return ["headphones"]
        case .earbuds: return ["earbuds", "earpods", "headphones"]
        case .speaker: return ["hifispeaker.fill", "speaker.wave.2.fill"]
        }
    }

    /// Symbols for the charging case chip.
    public var caseSymbolCandidates: [String] {
        switch self {
        case .airpodsPro, .airpodsPro2, .airpodsPro3: return ["airpodspro.chargingcase.wireless.fill", "airpods.chargingcase.fill"]
        case .airpods4: return ["airpods.gen4.chargingcase.wireless.fill", "airpods.chargingcase.wireless.fill", "airpods.chargingcase.fill"]
        default: return ["airpods.chargingcase.fill", "rectangle.fill"]
        }
    }

    /// Two buds in a case, reported as left / right / case.
    public var isBudPair: Bool {
        switch self {
        case .airpods, .airpods3, .airpods4, .airpodsPro, .airpodsPro2, .airpodsPro3, .powerbeats, .beatsEarbuds, .earbuds:
            return true
        default:
            return false
        }
    }
}

/// Identifies a device from what is known without special access: its Apple product ID when the
/// audio system exposes one, else its name, else the output's terminal type.
public enum AudioDeviceClassifier {
    /// Apple's Bluetooth product IDs (vendor 0x004C) for the families above.
    static let appleProducts: [Int: AudioDeviceModel] = [
        0x2002: .airpods, 0x200F: .airpods, 0x2013: .airpods3, 0x2019: .airpods4, 0x201B: .airpods4,
        0x200E: .airpodsPro, 0x2014: .airpodsPro2, 0x2024: .airpodsPro2, 0x2027: .airpodsPro3,
        0x200A: .airpodsMax, 0x201F: .airpodsMax,
        0x200B: .powerbeats, 0x200D: .powerbeats, 0x2003: .powerbeats,
        0x2006: .beatsHeadphones, 0x2009: .beatsHeadphones, 0x200C: .beatsHeadphones, 0x2017: .beatsHeadphones,
        0x2010: .beatsEarbuds, 0x2011: .beatsEarbuds, 0x2012: .beatsEarbuds, 0x2016: .beatsEarbuds,
    ]

    public enum Terminal: Sendable { case headphones, headset, speaker, unknown }

    public static func model(name: String, productID: Int? = nil, vendorID: Int? = nil,
                             terminal: Terminal = .unknown) -> AudioDeviceModel {
        if let productID, vendorID == nil || vendorID == 0x004C, let model = appleProducts[productID] { return model }
        let lower = name.lowercased()
        if lower.contains("airpods max") { return .airpodsMax }
        if lower.contains("airpods pro") {
            if lower.contains("pro 3") { return .airpodsPro3 }
            if lower.contains("pro 2") { return .airpodsPro2 }
            return .airpodsPro
        }
        if lower.contains("airpods") {
            if lower.contains("airpods 4") { return .airpods4 }
            return .airpods
        }
        if lower.contains("powerbeats") { return .powerbeats }
        if lower.contains("beats") {
            let headphones = ["studio pro", "studio3", "solo", "studio 3"]
            return headphones.contains { lower.contains($0) } ? .beatsHeadphones : .beatsEarbuds
        }
        if lower.contains("homepod") { return lower.contains("mini") ? .homepodMini : .homepod }
        if ["buds", "earbud", "earphone", "in-ear"].contains(where: lower.contains) { return .earbuds }
        if ["speaker", "soundlink", "boom", "flip", "charge", "soundbar", "sonos"].contains(where: lower.contains) { return .speaker }
        switch terminal {
        case .speaker: return .speaker
        case .headphones, .headset, .unknown: return .headphones
        }
    }

    /// Parses an audio model identifier of the form "<product hex> <vendor hex>" (as Bluetooth
    /// devices report it, e.g. "2014 4c"); nil for anything else.
    public static func productAndVendor(fromModelUID uid: String?) -> (product: Int, vendor: Int)? {
        guard let parts = uid?.split(separator: " ").map(String.init), parts.count == 2,
              parts[0].count == 4, (1...4).contains(parts[1].count),
              let product = Int(parts[0], radix: 16), let vendor = Int(parts[1], radix: 16) else { return nil }
        return (product, vendor)
    }
}

/// Battery levels of a connected audio device in percent (left and right buds plus case,
/// or a single level for headphones).
public struct DeviceBatteryLevels: Equatable, Sendable, Codable {
    public var left: Int?
    public var right: Int?
    public var chargingCase: Int?
    public var single: Int?

    public init(left: Int? = nil, right: Int? = nil, chargingCase: Int? = nil, single: Int? = nil) {
        self.left = left.flatMap(Self.valid)
        self.right = right.flatMap(Self.valid)
        self.chargingCase = chargingCase.flatMap(Self.valid)
        self.single = single.flatMap(Self.valid)
    }

    /// 0 means "not reported" for these properties.
    private static func valid(_ value: Int) -> Int? { (1...100).contains(value) ? value : nil }

    public var isEmpty: Bool { left == nil && right == nil && chargingCase == nil && single == nil }

    /// The level that decides "low battery": the lowest bud, or the single battery. The case is
    /// left out, because it doesn't stop the device from playing.
    public var listeningLevel: Int? {
        let values = [left, right, single].compactMap { $0 }
        return values.min()
    }
}

/// A connected Bluetooth audio device.
public struct ConnectedAudioDevice: Equatable, Sendable {
    /// Stable identifier (the audio device UID, or the Bluetooth address).
    public var id: String
    public var name: String
    public var model: AudioDeviceModel
    /// Bluetooth address ("aa-bb-cc-dd-ee-ff") when known, to match battery readings.
    public var address: String?
    public var batteries: DeviceBatteryLevels?

    public init(id: String, name: String, model: AudioDeviceModel, address: String? = nil, batteries: DeviceBatteryLevels? = nil) {
        self.id = id
        self.name = name
        self.model = model
        self.address = address
        self.batteries = batteries
    }

    /// Bluetooth audio device UIDs start with the device address ("AA-BB-CC-DD-EE-FF:output").
    public static func address(fromUID uid: String) -> String? {
        let candidate = uid.prefix(17).lowercased()
        let parts = candidate.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 6, parts.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isHexDigit) }) else { return nil }
        return String(candidate)
    }
}

public enum DeviceAlert: Equatable, Sendable {
    case connected(ConnectedAudioDevice)
    case lowBattery(ConnectedAudioDevice)
}

public struct DeviceAlertConfig: Equatable, Sendable {
    /// Master switch ("Connectivity").
    public var enabled = true
    /// "Warn on low battery" (off by default).
    public var lowWarning = false
    /// Percent; the warning fires at or below it.
    public var lowThreshold: Double = 20

    /// Same hysteresis as the Mac's battery.
    public static let hysteresis: Double = 2

    public init() {}
}

/// Turns successive lists of connected devices into alerts: one "connected" alert per device that
/// appears (devices present at the first reading are the baseline), and one low-battery warning per
/// crossing of the threshold.
public struct DeviceAlertMonitor: Sendable {
    public struct Entry: Equatable, Sendable {
        public var device: ConnectedAudioDevice
        public var lowArmed: Bool
    }

    public private(set) var config = DeviceAlertConfig()
    public private(set) var entries: [String: Entry] = [:]
    private var hasBaseline = false

    public init() {}

    public mutating func setConfig(_ newValue: DeviceAlertConfig) {
        let thresholdChanged = newValue.lowThreshold != config.lowThreshold
        config = newValue
        guard thresholdChanged else { return }
        for (id, entry) in entries {
            entries[id]?.lowArmed = Self.armed(entry.device.batteries?.listeningLevel, threshold: newValue.lowThreshold)
        }
    }

    @discardableResult
    public mutating func update(_ devices: [ConnectedAudioDevice]) -> [DeviceAlert] {
        var alerts: [DeviceAlert] = []
        let ids = Set(devices.map(\.id))
        for id in entries.keys where !ids.contains(id) { entries[id] = nil }
        for device in devices {
            let level = device.batteries?.listeningLevel
            guard var entry = entries[device.id] else {
                entries[device.id] = Entry(device: device, lowArmed: Self.armed(level, threshold: config.lowThreshold))
                if hasBaseline && config.enabled { alerts.append(.connected(device)) }
                continue
            }
            entry.device = device
            if let level {
                let value = Double(level)
                if value >= config.lowThreshold + DeviceAlertConfig.hysteresis { entry.lowArmed = true }
                if entry.lowArmed && value <= config.lowThreshold {
                    entry.lowArmed = false
                    if config.enabled && config.lowWarning { alerts.append(.lowBattery(device)) }
                }
            }
            entries[device.id] = entry
        }
        hasBaseline = true
        return alerts
    }

    /// Unknown levels arm the warning, so the first reading at or below the threshold warns.
    private static func armed(_ level: Int?, threshold: Double) -> Bool {
        guard let level else { return true }
        return Double(level) > threshold
    }
}
