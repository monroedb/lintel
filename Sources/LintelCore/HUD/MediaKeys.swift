import Foundation

/// Keys Lintel can take over (IOKit `ev_keymap.h` key types carried by system-defined events).
public enum MediaKey: Int, CaseIterable, Sendable, Codable {
    case volumeUp = 0      // NX_KEYTYPE_SOUND_UP
    case volumeDown = 1    // NX_KEYTYPE_SOUND_DOWN
    case brightnessUp = 2  // NX_KEYTYPE_BRIGHTNESS_UP
    case brightnessDown = 3 // NX_KEYTYPE_BRIGHTNESS_DOWN
    case mute = 7          // NX_KEYTYPE_MUTE

    public var hud: HUDKind {
        switch self {
        case .volumeUp, .volumeDown, .mute: return .volume
        case .brightnessUp, .brightnessDown: return .brightness
        }
    }

    public var name: String {
        switch self {
        case .volumeUp: return "volumeUp"
        case .volumeDown: return "volumeDown"
        case .brightnessUp: return "brightnessUp"
        case .brightnessDown: return "brightnessDown"
        case .mute: return "mute"
        }
    }

    public init?(name: String) {
        guard let key = MediaKey.allCases.first(where: { $0.name.lowercased() == name.lowercased() }) else { return nil }
        self = key
    }
}

/// Modifier keys held with a media key (from `CGEventFlags`).
public struct MediaKeyModifiers: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let shift = MediaKeyModifiers(rawValue: 1 << 0)
    public static let control = MediaKeyModifiers(rawValue: 1 << 1)
    public static let option = MediaKeyModifiers(rawValue: 1 << 2)
    public static let command = MediaKeyModifiers(rawValue: 1 << 3)

    /// `CGEventFlags` raw values (maskShift, maskControl, maskAlternate, maskCommand).
    public static let cgShift: UInt64 = 0x0002_0000
    public static let cgControl: UInt64 = 0x0004_0000
    public static let cgAlternate: UInt64 = 0x0008_0000
    public static let cgCommand: UInt64 = 0x0010_0000

    public init(cgFlags: UInt64) {
        var value: MediaKeyModifiers = []
        if cgFlags & Self.cgShift != 0 { value.insert(.shift) }
        if cgFlags & Self.cgControl != 0 { value.insert(.control) }
        if cgFlags & Self.cgAlternate != 0 { value.insert(.option) }
        if cgFlags & Self.cgCommand != 0 { value.insert(.command) }
        self = value
    }

    public var cgFlags: UInt64 {
        var flags: UInt64 = 0
        if contains(.shift) { flags |= Self.cgShift }
        if contains(.control) { flags |= Self.cgControl }
        if contains(.option) { flags |= Self.cgAlternate }
        if contains(.command) { flags |= Self.cgCommand }
        return flags
    }

    /// ⌥⇧: fine steps.
    public var isFineStep: Bool { contains(.option) && contains(.shift) }
    /// ⌥ alone: open Lintel's settings on the HUD's section.
    public var opensSettings: Bool { contains(.option) && !contains(.shift) }
}

public struct MediaKeyEvent: Equatable, Sendable {
    public var key: MediaKey
    public var isDown: Bool
    public var isRepeat: Bool
    public var modifiers: MediaKeyModifiers

    public init(key: MediaKey, isDown: Bool, isRepeat: Bool = false, modifiers: MediaKeyModifiers = []) {
        self.key = key
        self.isDown = isDown
        self.isRepeat = isRepeat
        self.modifiers = modifiers
    }
}

/// Decodes the system-defined events the event tap sees (IOKit `IOLLEvent.h`): type NX_SYSDEFINED
/// (14), subtype NX_SUBTYPE_AUX_CONTROL_BUTTONS (8); `data1` holds the key type in bits 16–31 and
/// the key flags in bits 0–15 (state 0xA down / 0xB up in bits 8–15, bit 0 = auto-repeat).
public enum MediaKeyDecoder {
    public static let systemDefinedEventType: UInt32 = 14
    public static let auxControlButtonsSubtype: Int16 = 8
    static let keyDownState = 0xA
    static let keyUpState = 0xB

    public static func decode(eventType: UInt32, subtype: Int16, data1: Int, flags: UInt64) -> MediaKeyEvent? {
        guard eventType == systemDefinedEventType, subtype == auxControlButtonsSubtype else { return nil }
        let keyCode = (data1 & 0xFFFF_0000) >> 16
        let keyFlags = data1 & 0xFFFF
        let state = (keyFlags & 0xFF00) >> 8
        guard let key = MediaKey(rawValue: keyCode), state == keyDownState || state == keyUpState else { return nil }
        return MediaKeyEvent(key: key, isDown: state == keyDownState, isRepeat: keyFlags & 0x1 == 1,
                             modifiers: MediaKeyModifiers(cgFlags: flags))
    }

    /// `data1` of a synthesized event (for the checks).
    public static func data1(for key: MediaKey, down: Bool, isRepeat: Bool = false) -> Int {
        (key.rawValue << 16) | ((down ? keyDownState : keyUpState) << 8) | (isRepeat ? 1 : 0)
    }
}

/// A display whose brightness a key could change.
public struct BrightnessDisplay: Equatable, Sendable {
    public var id: UInt32
    public var uuid: String
    public var isBuiltIn: Bool
    /// Lintel can change it itself (DisplayServices reports it adjustable).
    public var adjustable: Bool

    public init(id: UInt32, uuid: String, isBuiltIn: Bool, adjustable: Bool) {
        self.id = id
        self.uuid = uuid
        self.isBuiltIn = isBuiltIn
        self.adjustable = adjustable
    }
}

/// Picks the display a brightness key adjusts (the "managed" display — automatic, internal,
/// external; ctrl + key alternates the target; P3).
public enum BrightnessTargeting {
    /// - automatic: the display under the pointer when Lintel can adjust it (or BetterDisplay manages
    ///   it), otherwise the built-in display;
    /// - builtIn / external: that kind of display, falling back to the other;
    /// - `alternate` (ctrl held): the built-in display when the normal target is external, otherwise
    ///   an external display (nil when there is none).
    public static func target(mode: BrightnessTargetMode, displays: [BrightnessDisplay], pointerDisplay: UInt32?,
                              betterDisplayActive: Bool, alternate: Bool) -> BrightnessDisplay? {
        guard !displays.isEmpty else { return nil }
        let builtIn = displays.first { $0.isBuiltIn }
        let externals = displays.filter { !$0.isBuiltIn }
        let pointer = displays.first { $0.id == pointerDisplay }
        let usable: (BrightnessDisplay) -> Bool = { $0.adjustable || (!$0.isBuiltIn && betterDisplayActive) }
        let preferredExternal = (pointer.map { !$0.isBuiltIn } == true ? pointer : nil)
            ?? externals.first(where: usable) ?? externals.first

        let primary: BrightnessDisplay?
        switch mode {
        case .automatic:
            if let pointer, usable(pointer) { primary = pointer } else { primary = builtIn ?? pointer ?? displays.first }
        case .builtIn:
            primary = builtIn ?? preferredExternal
        case .external:
            primary = preferredExternal ?? builtIn
        }
        guard alternate else { return primary }
        if primary?.isBuiltIn == true { return preferredExternal }
        return builtIn
    }
}

/// State the event tap consults to decide whether to take a key (kept current by the HUD service and
/// read on the tap's thread).
public struct MediaKeyRoutingState: Equatable, Sendable {
    public var volumeEnabled = false
    public var brightnessEnabled = false
    /// The default output device's volume can be set (otherwise macOS keeps the key).
    public var volumeAdjustable = true
    public var brightnessMode: BrightnessTargetMode = .automatic
    public var displays: [BrightnessDisplay] = []
    public var betterDisplayActive = false

    public init() {}
}

/// What a consumed key does.
public enum MediaKeyAction: Equatable, Sendable {
    case adjustVolume(up: Bool, fine: Bool, isRepeat: Bool)
    case toggleMute
    case adjustBrightness(up: Bool, fine: Bool, isRepeat: Bool, display: UInt32)
    case openSettings(HUDKind)
}

public struct MediaKeyDecision: Equatable, Sendable {
    /// Whether the event is removed from the event stream (so macOS shows no OSD of its own).
    public var consume: Bool
    /// Work to do on the main thread (only for key-down events).
    public var action: MediaKeyAction?

    public static let pass = MediaKeyDecision(consume: false, action: nil)

    public init(consume: Bool, action: MediaKeyAction?) {
        self.consume = consume
        self.action = action
    }
}

/// Decides which keys Lintel takes.
///
/// - A key is only taken while its HUD is switched on; otherwise macOS handles it as usual.
/// - ⌥ + key opens Lintel's settings on the matching section; ⌥⇧ + key takes a fine step.
/// - Volume keys pass through when the output device has no adjustable volume.
/// - Brightness keys pass through when the target display can't be adjusted by Lintel — macOS or
///   BetterDisplay (which then reports the change through its OSD notifications) handles them, so a
///   key press is never handled twice.
/// - Key-up events of taken keys are taken too; auto-repeats adjust again ("holding a key repeats").
public enum MediaKeyRouter {
    public static func route(_ event: MediaKeyEvent, state: MediaKeyRoutingState, pointerDisplay: UInt32?) -> MediaKeyDecision {
        let act = event.isDown
        switch event.key.hud {
        case .volume:
            guard state.volumeEnabled else { return .pass }
            if event.modifiers.opensSettings {
                return MediaKeyDecision(consume: true, action: act && !event.isRepeat ? .openSettings(.volume) : nil)
            }
            guard state.volumeAdjustable else { return .pass }
            guard act else { return MediaKeyDecision(consume: true, action: nil) }
            if event.key == .mute {
                return MediaKeyDecision(consume: true, action: event.isRepeat ? nil : .toggleMute)
            }
            return MediaKeyDecision(consume: true, action: .adjustVolume(up: event.key == .volumeUp,
                                                                          fine: event.modifiers.isFineStep,
                                                                          isRepeat: event.isRepeat))
        case .brightness:
            guard state.brightnessEnabled else { return .pass }
            if event.modifiers.opensSettings {
                return MediaKeyDecision(consume: true, action: act && !event.isRepeat ? .openSettings(.brightness) : nil)
            }
            let target = BrightnessTargeting.target(mode: state.brightnessMode, displays: state.displays,
                                                    pointerDisplay: pointerDisplay, betterDisplayActive: state.betterDisplayActive,
                                                    alternate: event.modifiers.contains(.control))
            guard let target, target.adjustable else { return .pass }
            guard act else { return MediaKeyDecision(consume: true, action: nil) }
            return MediaKeyDecision(consume: true, action: .adjustBrightness(up: event.key == .brightnessUp,
                                                                              fine: event.modifiers.isFineStep,
                                                                              isRepeat: event.isRepeat, display: target.id))
        }
    }
}
