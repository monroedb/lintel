import Foundation

/// An sRGB colour without UI framework types.
public struct SRGBColor: Equatable, Hashable, Sendable, Codable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(_ red: Double, _ green: Double, _ blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public init(hex: UInt32) {
        self.init(Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255, Double(hex & 0xFF) / 255)
    }
}

/// How a Focus mode is drawn: name, SF Symbol and tint.
public struct FocusModeDescriptor: Equatable, Hashable, Sendable, Codable {
    /// System mode identifier; nil when the active mode is unknown (on/off is all that's known).
    public var identifier: String?
    public var name: String
    public var symbol: String
    public var tint: SRGBColor

    public init(identifier: String?, name: String, symbol: String, tint: SRGBColor) {
        self.identifier = identifier
        self.name = name
        self.symbol = symbol
        self.tint = tint
    }
}

/// Built-in Focus modes and the system colour names custom modes use. Identifiers are the system's;
/// symbols and tints are Lintel's choices in the system palette (dark variants).
public enum FocusModeCatalog {
    public static let doNotDisturb = "com.apple.donotdisturb.mode.default"
    public static let sleep = "com.apple.sleep.sleep-mode"

    /// Do Not Disturb's tint as measured on the design's "On" screenshot (Rec. 709 ≈ sRGB: 89, 91, 239).
    public static let indigo = SRGBColor(hex: 0x595BEF)
    /// Drawn for an alert about a Focus turning off (measured on the "Off" screenshot: ≈ 81–83).
    public static let offGrey = SRGBColor(hex: 0x525254)

    public static let builtIn: [FocusModeDescriptor] = [
        FocusModeDescriptor(identifier: doNotDisturb, name: "Do Not Disturb", symbol: "moon.fill", tint: indigo),
        FocusModeDescriptor(identifier: sleep, name: "Sleep", symbol: "bed.double.fill", tint: SRGBColor(hex: 0x40C8E0)),
        FocusModeDescriptor(identifier: "com.apple.focus.personal-time", name: "Personal", symbol: "person.fill",
                            tint: SRGBColor(hex: 0xBF5AF2)),
        FocusModeDescriptor(identifier: "com.apple.focus.work", name: "Work", symbol: "briefcase.fill", tint: SRGBColor(hex: 0x64D2FF)),
        FocusModeDescriptor(identifier: "com.apple.focus.reading", name: "Reading", symbol: "book.fill", tint: SRGBColor(hex: 0xFF9F0A)),
        FocusModeDescriptor(identifier: "com.apple.donotdisturb.mode.driving", name: "Driving", symbol: "car.fill",
                            tint: SRGBColor(hex: 0x0A84FF)),
        FocusModeDescriptor(identifier: "com.apple.donotdisturb.mode.workout", name: "Fitness", symbol: "figure.run",
                            tint: SRGBColor(hex: 0x30D158)),
        FocusModeDescriptor(identifier: "com.apple.focus.gaming", name: "Gaming", symbol: "gamecontroller.fill",
                            tint: SRGBColor(hex: 0x0A84FF)),
        FocusModeDescriptor(identifier: "com.apple.focus.mindfulness", name: "Mindfulness", symbol: "brain.head.profile",
                            tint: SRGBColor(hex: 0x66D4CF)),
        FocusModeDescriptor(identifier: "com.apple.focus.reduce-interruptions", name: "Reduce Interruptions",
                            symbol: "sparkles", tint: SRGBColor(hex: 0x64D2FF)),
    ]

    /// Shown when a Focus is on but its mode is unknown (no access to the Focus database).
    public static let generic = FocusModeDescriptor(identifier: nil, name: "Focus", symbol: "moon.fill", tint: indigo)

    public static func builtIn(_ identifier: String?) -> FocusModeDescriptor? {
        guard let identifier else { return nil }
        return builtIn.first { $0.identifier == identifier }
    }

    /// Dark-appearance values of the system colours custom modes are tinted with.
    public static func tint(systemColorName raw: String?) -> SRGBColor? {
        guard var name = raw?.lowercased(), !name.isEmpty else { return nil }
        if name.hasPrefix("system") { name.removeFirst("system".count) }
        if name.hasSuffix("color") { name.removeLast("color".count) }
        switch name {
        case "red": return SRGBColor(hex: 0xFF453A)
        case "orange": return SRGBColor(hex: 0xFF9F0A)
        case "yellow": return SRGBColor(hex: 0xFFD60A)
        case "green": return SRGBColor(hex: 0x30D158)
        case "mint": return SRGBColor(hex: 0x66D4CF)
        case "teal": return SRGBColor(hex: 0x40C8E0)
        case "cyan": return SRGBColor(hex: 0x64D2FF)
        case "blue": return SRGBColor(hex: 0x0A84FF)
        case "indigo": return indigo
        case "purple": return SRGBColor(hex: 0xBF5AF2)
        case "pink": return SRGBColor(hex: 0xFF375F)
        case "brown": return SRGBColor(hex: 0xAC8E68)
        case "gray", "grey": return SRGBColor(hex: 0x8E8E93)
        default: return nil
        }
    }
}

/// What the Focus source reports: whether a Focus is on and, when known, which one.
public struct FocusState: Equatable, Sendable {
    public var active: Bool
    public var mode: FocusModeDescriptor?

    public init(active: Bool, mode: FocusModeDescriptor? = nil) {
        self.active = active
        self.mode = mode
    }
}

/// Where Lintel reads whether a Focus is on.
public enum FocusDetection: String, Sendable {
    /// `INFocusStatusCenter`. Needs the user's Focus-status permission *and* the Communication
    /// Notifications entitlement, which only Apple-provisioned builds can carry. Without the
    /// entitlement the Focus service rejects every request ("App is missing Communication
    /// Notifications entitlement") while the status center still answers, so its answer can't be
    /// trusted.
    case system
    /// Manual activations recorded in the Focus database (`~/Library/DoNotDisturb/DB`), read with
    /// Full Disk Access. The alternative for ad-hoc, self-signed and personal-team builds.
    case database
    /// Neither source can be read.
    case unavailable

    public static func choose(entitled: Bool, authorized: Bool, databaseReadable: Bool) -> FocusDetection {
        if entitled && authorized { return .system }
        if databaseReadable { return .database }
        return .unavailable
    }
}

extension FocusState {
    /// Combines the two Focus sources: on/off from the status center when it can be read,
    /// else from a manual activation recorded in the database; the mode from the database. nil when
    /// neither source is available.
    public static func combine(isFocused: Bool?, database: FocusDatabase.Snapshot?) -> FocusState? {
        combine(isFocused: isFocused, database: database, detection: .system)
    }

    /// Combines the sources for the chosen detection. With `.database` the status center's answer is
    /// ignored: without the entitlement it reports "off" even while a Focus is on, which hid every
    /// Focus change (regression check: "Focus on from the database despite status off").
    public static func combine(isFocused: Bool?, database: FocusDatabase.Snapshot?,
                               detection: FocusDetection) -> FocusState? {
        let databaseActive = database.map { $0.activeIdentifier != nil }
        let active: Bool?
        switch detection {
        case .system: active = isFocused ?? databaseActive
        case .database: active = databaseActive
        case .unavailable: active = nil
        }
        guard let active else { return nil }
        guard active else { return FocusState(active: false) }
        return FocusState(active: true, mode: database?.activeMode)
    }
}

public enum FocusAlert: Equatable, Sendable {
    /// A Focus turned on (or switched to another mode while on).
    case on(FocusModeDescriptor)
    /// The Focus turned off; carries the mode that was on (drawn in grey).
    case off(FocusModeDescriptor)

    public var mode: FocusModeDescriptor {
        switch self {
        case .on(let mode), .off(let mode): return mode
        }
    }

    public var isOn: Bool {
        if case .on = self { return true }
        return false
    }
}

/// Turns Focus readings into on/off alerts. Readings settle briefly first, because a source can
/// report "on" a moment before it knows which mode it is (the alert appeared ≈ 0.7 s after
/// toggling). The first reading only sets the baseline.
public struct FocusAlertMonitor: Sendable {
    public static let settle: Double = 0.15

    /// The reading alerts were last decided on.
    public private(set) var committed: FocusState?
    public private(set) var pending: FocusState?
    public private(set) var pendingDeadline: Double?

    public init() {}

    /// Records a reading; returns true when it starts or changes a pending decision.
    @discardableResult
    public mutating func submit(_ state: FocusState, now: Double) -> Bool {
        guard committed != nil else {
            committed = state
            return false
        }
        if state == (pending ?? committed) { return false }
        pending = state
        if pendingDeadline == nil { pendingDeadline = now + Self.settle }
        return true
    }

    public var nextDeadline: Double? { pendingDeadline }

    /// Decides once the settle time has passed.
    public mutating func tick(now: Double) -> FocusAlert? {
        guard let deadline = pendingDeadline, now >= deadline, let new = pending, let old = committed else { return nil }
        pending = nil
        pendingDeadline = nil
        committed = new
        switch (old.active, new.active) {
        case (false, true):
            return .on(new.mode ?? FocusModeCatalog.generic)
        case (true, false):
            return .off(old.mode ?? new.mode ?? FocusModeCatalog.generic)
        case (true, true):
            // Switching between two known modes reads as the new one turning on.
            guard let mode = new.mode, mode.identifier != old.mode?.identifier, mode.identifier != nil else { return nil }
            return .on(mode)
        case (false, false):
            return nil
        }
    }

    /// The Focus as last committed (for the context filters and the waveform replacement).
    public var current: FocusState? { committed }
}

/// "Replace waveform during focus": which Focus symbol, if any, stands in for the compact Now
/// Playing waveform ("When focus is": any, or one chosen mode).
public enum FocusWaveformRule {
    public static func replacement(for state: FocusState?, enabled: Bool, onlyMode: String?) -> FocusModeDescriptor? {
        guard enabled, let state, state.active else { return nil }
        let mode = state.mode ?? FocusModeCatalog.generic
        if let onlyMode, !onlyMode.isEmpty {
            return mode.identifier == onlyMode ? mode : nil
        }
        return mode
    }
}

/// Reads the system's Focus database (`~/Library/DoNotDisturb/DB`: `Assertions.json` for the mode
/// that was turned on, `ModeConfigurations.json` for every mode's name, symbol and tint). The format
/// is undocumented, so parsing is tolerant: keys are searched for anywhere in the tree and anything
/// unexpected yields "unknown" instead of an error.
public enum FocusDatabase {
    public struct Snapshot: Equatable, Sendable {
        /// Mode of the most recent manual activation; nil when none is recorded.
        public var activeIdentifier: String?
        public var modes: [FocusModeDescriptor]

        public init(activeIdentifier: String?, modes: [FocusModeDescriptor]) {
            self.activeIdentifier = activeIdentifier
            self.modes = modes
        }

        public func descriptor(for identifier: String?) -> FocusModeDescriptor? {
            guard let identifier else { return nil }
            return modes.first { $0.identifier == identifier } ?? FocusModeCatalog.builtIn(identifier)
        }

        public var activeMode: FocusModeDescriptor? { descriptor(for: activeIdentifier) }
    }

    public static let assertionsFile = "Assertions.json"
    public static let configurationsFile = "ModeConfigurations.json"

    public static func parse(assertions: Data?, configurations: Data?) -> Snapshot {
        let modes = configurations.flatMap(json).map(parseModes) ?? []
        let active = assertions.flatMap(json).flatMap(parseActiveIdentifier)
        return Snapshot(activeIdentifier: active, modes: modes)
    }

    private static func json(_ data: Data) -> Any? { try? JSONSerialization.jsonObject(with: data) }

    /// Every dictionary that has a mode identifier together with a name or symbol.
    static func parseModes(_ root: Any) -> [FocusModeDescriptor] {
        var found: [String: FocusModeDescriptor] = [:]
        visit(root) { dict in
            guard let identifier = dict["modeIdentifier"] as? String, !identifier.isEmpty else { return }
            let name = dict["name"] as? String
            let symbol = dict["symbolImageName"] as? String ?? dict["symbolName"] as? String
            guard name != nil || symbol != nil else { return }
            let builtIn = FocusModeCatalog.builtIn(identifier)
            let tint = FocusModeCatalog.tint(systemColorName: dict["tintColorName"] as? String)
            found[identifier] = FocusModeDescriptor(
                identifier: identifier,
                name: (name?.isEmpty == false ? name : nil) ?? builtIn?.name ?? "Focus",
                symbol: (symbol?.isEmpty == false ? symbol : nil) ?? builtIn?.symbol ?? FocusModeCatalog.generic.symbol,
                tint: tint ?? builtIn?.tint ?? FocusModeCatalog.indigo)
        }
        return found.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The mode of the latest assertion record (by start time when present, else the last one).
    static func parseActiveIdentifier(_ root: Any) -> String? {
        var records: [(identifier: String, start: Double, order: Int)] = []
        visit(root) { dict in
            guard let list = dict["storeAssertionRecords"] as? [Any] else { return }
            for item in list {
                guard let record = item as? [String: Any] else { continue }
                var identifier: String?
                visit(record) { inner in
                    if identifier == nil, let value = inner["assertionDetailsModeIdentifier"] as? String, !value.isEmpty {
                        identifier = value
                    }
                }
                guard let identifier else { continue }
                let start = (record["assertionStartDateTimestamp"] as? NSNumber)?.doubleValue ?? 0
                records.append((identifier, start, records.count))
            }
        }
        return records.max { ($0.start, $0.order) < ($1.start, $1.order) }?.identifier
    }

    private static func visit(_ node: Any, depth: Int = 0, _ body: ([String: Any]) -> Void) {
        guard depth < 12 else { return }
        if let dict = node as? [String: Any] {
            body(dict)
            for value in dict.values { visit(value, depth: depth + 1, body) }
        } else if let array = node as? [Any] {
            for value in array { visit(value, depth: depth + 1, body) }
        }
    }
}
