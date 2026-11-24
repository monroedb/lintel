import Foundation

/// Core Audio transport types of output devices (`kAudioDeviceTransportType…` four-char codes).
public enum AudioTransport: String, Sendable, CaseIterable {
    case builtIn, bluetooth, bluetoothLE, airPlay, usb, hdmi, displayPort, thunderbolt, virtual, aggregate, other

    public init(fourCC: UInt32) {
        switch fourCC {
        case Self.code("bltn"): self = .builtIn
        case Self.code("blue"): self = .bluetooth
        case Self.code("blea"): self = .bluetoothLE
        case Self.code("airp"): self = .airPlay
        case Self.code("usb "): self = .usb
        case Self.code("hdmi"): self = .hdmi
        case Self.code("dprt"): self = .displayPort
        case Self.code("thun"): self = .thunderbolt
        case Self.code("virt"): self = .virtual
        case Self.code("grup"): self = .aggregate
        default: self = .other
        }
    }

    public static func code(_ text: String) -> UInt32 {
        text.utf8.prefix(4).reduce(0) { $0 << 8 | UInt32($1) }
    }
}

/// An output device as shown by the player's output button (a laptop
/// glyph for the built-in speakers; switches between AirPlay and Bluetooth outputs).
public struct AudioOutputDevice: Equatable, Sendable, Identifiable {
    public var id: UInt32
    public var uid: String
    public var name: String
    public var transport: AudioTransport

    public init(id: UInt32, uid: String, name: String, transport: AudioTransport) {
        self.id = id
        self.uid = uid
        self.name = name
        self.transport = transport
    }

    /// Virtual and aggregate devices (recording tools, meeting apps) aren't offered as outputs.
    public var isSelectable: Bool { transport != .virtual && transport != .aggregate }

    /// SF Symbol candidates, most specific first.
    public func symbolNames(builtInIsLaptop: Bool = true) -> [String] {
        let lower = name.lowercased()
        switch transport {
        case .builtIn:
            if lower.contains("headphone") { return ["headphones"] }
            return builtInIsLaptop ? ["laptopcomputer"] : ["desktopcomputer", "speaker.wave.2.fill"]
        case .bluetooth, .bluetoothLE:
            if lower.contains("airpods max") { return ["airpods.max", "airpodsmax", "headphones"] }
            if lower.contains("airpods pro") { return ["airpods.pro", "airpodspro", "airpods", "headphones"] }
            if lower.contains("airpods") { return ["airpods", "headphones"] }
            if lower.contains("beats") { return ["beats.headphones", "headphones"] }
            if lower.contains("homepod") { return ["homepod.fill", "hifispeaker.fill"] }
            if lower.contains("speaker") || lower.contains("boom") || lower.contains("soundlink") {
                return ["hifispeaker.fill", "speaker.wave.2.fill"]
            }
            return ["headphones"]
        case .airPlay:
            if lower.contains("homepod") { return ["homepod.fill", "airplay.audio", "airplayaudio"] }
            if lower.contains("tv") { return ["appletv.fill", "airplay.audio", "airplayaudio"] }
            return ["airplay.audio", "airplayaudio"]
        case .hdmi, .displayPort, .thunderbolt:
            return ["tv", "display"]
        case .usb:
            return ["hifispeaker.fill", "speaker.wave.2.fill"]
        case .virtual, .aggregate, .other:
            return ["speaker.wave.2.fill"]
        }
    }
}

/// Orders the output menu: built-in first, then Bluetooth, AirPlay and the rest, by name.
public func orderedOutputs(_ devices: [AudioOutputDevice]) -> [AudioOutputDevice] {
    func rank(_ t: AudioTransport) -> Int {
        switch t {
        case .builtIn: return 0
        case .bluetooth, .bluetoothLE: return 1
        case .airPlay: return 2
        default: return 3
        }
    }
    return devices.filter(\.isSelectable).sorted {
        rank($0.transport) != rank($1.transport) ? rank($0.transport) < rank($1.transport)
            : $0.name.localizedStandardCompare($1.name) == .orderedAscending
    }
}
