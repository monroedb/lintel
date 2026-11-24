import Foundation

/// How an output device is connected (CoreAudio transport types).
public enum OutputTransport: String, Sendable, Codable {
    case builtIn, bluetooth, bluetoothLE, airPlay, hdmi, displayPort, usb, thunderbolt, virtual, aggregate, unknown

    /// Maps a CoreAudio `kAudioDevicePropertyTransportType` four-char code.
    public init(fourCC: UInt32) {
        switch fourCC {
        case 0x626C_746E: self = .builtIn      // 'bltn'
        case 0x626C_7565: self = .bluetooth    // 'blue'
        case 0x626C_6561: self = .bluetoothLE  // 'blea'
        case 0x6169_7270: self = .airPlay      // 'airp'
        case 0x6864_6D69: self = .hdmi         // 'hdmi'
        case 0x6470_7274: self = .displayPort  // 'dprt'
        case 0x7573_6220: self = .usb          // 'usb '
        case 0x7468_756E: self = .thunderbolt  // 'thun'
        case 0x7669_7274: self = .virtual      // 'virt'
        case 0x6772_7570: self = .aggregate    // 'grup'
        default: self = .unknown
        }
    }
}

/// The default output device as the volume HUD sees it.
public struct OutputDeviceInfo: Equatable, Sendable {
    public var name: String
    public var transport: OutputTransport
    /// Built-in data source four-char code as text ("ispk" speakers, "hdpn" headphones), if any.
    public var dataSource: String?

    public init(name: String, transport: OutputTransport, dataSource: String? = nil) {
        self.name = name
        self.transport = transport
        self.dataSource = dataSource
    }

    public var isBuiltInSpeakers: Bool { transport == .builtIn && dataSource != "hdpn" }
}

/// SF Symbol names and labels for the HUDs. Every symbol used here exists on macOS 15 (checked by
/// lintel-checks).
public enum HUDGlyphs {
    public static let muted = "speaker.slash.fill"
    public static let sun = "sun.max.fill"
    public static let externalDisplay = "display"

    /// Speaker by level (the reference shows the bare speaker at 1/16 and the slashed speaker
    /// when muted): 0 or muted → slashed; below ¼ → no waves; then one, two, three waves.
    public static func speaker(level: Double, muted: Bool) -> String {
        if muted || level <= 0.0001 { return Self.muted }
        switch level {
        case ..<0.25: return "speaker.fill"
        case ..<0.5: return "speaker.wave.1.fill"
        case ..<0.75: return "speaker.wave.2.fill"
        default: return "speaker.wave.3.fill"
        }
    }

    /// Glyph and label of the volume HUD ("Show device" reflects the current output — built-in
    /// speakers, AirPods models, HomePod, displays, AirPlay; "Show symbol" a generic speaker; the
    /// built-in speakers read "Sound").
    public static func volume(device: OutputDeviceInfo?, mode: VolumeLabelMode, level: Double, muted: Bool) -> (symbol: String, label: String) {
        let speaker = speaker(level: level, muted: muted)
        guard mode == .device, let device, !device.isBuiltInSpeakers else { return (speaker, HUDKind.volume.defaultLabel) }
        let label = shortName(device.name)
        if muted { return (Self.muted, label) }
        return (deviceSymbol(device), label)
    }

    /// Device glyph from its connection and name.
    public static func deviceSymbol(_ device: OutputDeviceInfo) -> String {
        let name = device.name.lowercased()
        switch device.transport {
        case .builtIn:
            return device.dataSource == "hdpn" ? "headphones" : "speaker.wave.2.fill"
        case .bluetooth, .bluetoothLE, .airPlay:
            if name.contains("airpods max") { return "airpodsmax" }
            if name.contains("airpods pro") { return "airpodspro" }
            if name.contains("airpods") { return "airpods" }
            if name.contains("homepod mini") { return "homepodmini.fill" }
            if name.contains("homepod") { return "homepod.fill" }
            if name.contains("beats") { return "beats.headphones" }
            if device.transport == .airPlay { return "airplayaudio" }
            if name.contains("speaker") || name.contains("soundbar") { return "hifispeaker.fill" }
            return "headphones"
        case .hdmi, .displayPort, .thunderbolt:
            return name.contains("tv") ? "tv" : "display"
        case .usb, .virtual, .aggregate, .unknown:
            if name.contains("headphone") || name.contains("headset") { return "headphones" }
            return "hifispeaker.fill"
        }
    }

    /// Drops an owner prefix ("Sam’s AirPods Pro" → "AirPods Pro"); the HUD has room for a short name.
    public static func shortName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        for marker in ["’s ", "'s "] {
            if let range = trimmed.range(of: marker) {
                let rest = trimmed[range.upperBound...].trimmingCharacters(in: .whitespaces)
                if !rest.isEmpty { return rest }
            }
        }
        return trimmed.isEmpty ? HUDKind.volume.defaultLabel : trimmed
    }

    /// Every symbol name this file can return (for the availability check).
    public static let allSymbols: [String] = [
        muted, sun, externalDisplay, "speaker.fill", "speaker.wave.1.fill", "speaker.wave.2.fill", "speaker.wave.3.fill",
        "headphones", "airpodsmax", "airpodspro", "airpods", "homepodmini.fill", "homepod.fill", "beats.headphones",
        "airplayaudio", "hifispeaker.fill", "tv",
    ]
}
