import Foundation

/// One reading of the Mac's power state (`PowerSource`).
public struct PowerSnapshot: Equatable, Sendable {
    /// False on Macs without an internal battery (the Battery alerts are then unavailable).
    public var hasBattery: Bool
    /// Charge in percent (0–100).
    public var level: Int
    /// Running on a power adapter.
    public var externalPower: Bool
    public var charging: Bool
    /// Full (or held at its charge limit) on a power adapter.
    public var charged: Bool
    public var lowPowerMode: Bool
    /// Estimated minutes until empty (on battery) or full (charging); nil while unknown.
    public var minutesToEmpty: Int?
    public var minutesToFull: Int?

    public init(hasBattery: Bool = true, level: Int, externalPower: Bool, charging: Bool = false, charged: Bool = false,
                lowPowerMode: Bool = false, minutesToEmpty: Int? = nil, minutesToFull: Int? = nil) {
        self.hasBattery = hasBattery
        self.level = level
        self.externalPower = externalPower
        self.charging = charging
        self.charged = charged
        self.lowPowerMode = lowPowerMode
        self.minutesToEmpty = minutesToEmpty
        self.minutesToFull = minutesToFull
    }

    public static func noBattery(lowPowerMode: Bool = false) -> PowerSnapshot {
        PowerSnapshot(hasBattery: false, level: 0, externalPower: true, lowPowerMode: lowPowerMode)
    }

    /// The estimate that matters right now: time to full while charging, to empty on battery.
    public var minutesRemaining: Int? {
        if externalPower { return charging ? minutesToFull : nil }
        return minutesToEmpty
    }

    /// Builds a snapshot from IOKit power-source descriptions (`IOPSGetPowerSourceDescription`),
    /// using the documented key strings (`kIOPSTypeKey` = "Type", …). The internal battery wins;
    /// without one the Mac has no battery.
    public static func parse(descriptions: [[String: Any]], lowPowerMode: Bool) -> PowerSnapshot {
        guard let battery = descriptions.first(where: { ($0["Type"] as? String) == "InternalBattery"
                                                        && (($0["Is Present"] as? Bool) ?? true) }) else {
            return .noBattery(lowPowerMode: lowPowerMode)
        }
        func int(_ key: String) -> Int? { (battery[key] as? NSNumber)?.intValue }
        func bool(_ key: String) -> Bool { (battery[key] as? NSNumber)?.boolValue ?? false }
        let current = int("Current Capacity") ?? 0
        let maximum = max(1, int("Max Capacity") ?? 100)
        let level = min(100, max(0, Int((Double(current) * 100 / Double(maximum)).rounded())))
        let external = (battery["Power Source State"] as? String) == "AC Power"
        let charging = bool("Is Charging")
        // IOKit reports -1 while it is still estimating, and 0 for "not applicable".
        let toEmpty = int("Time to Empty").flatMap { $0 > 0 ? $0 : nil }
        let toFull = int("Time to Full Charge").flatMap { $0 > 0 ? $0 : nil }
        return PowerSnapshot(hasBattery: true, level: level, externalPower: external, charging: charging,
                             charged: bool("Is Charged") || (external && !charging && level >= 100),
                             lowPowerMode: lowPowerMode,
                             minutesToEmpty: external ? nil : toEmpty,
                             minutesToFull: charging ? toFull : nil)
    }
}

/// Battery alert kinds.
public enum BatteryAlert: String, Equatable, Sendable {
    case charging, lowBattery, lowPowerMode
}

public struct BatteryAlertConfig: Equatable, Sendable {
    /// Master switch ("Battery").
    public var enabled = true
    /// "Notify on low power mode".
    public var lowPowerAlert = true
    /// "Warn on low battery".
    public var lowWarning = true
    /// Percent; the warning fires at or below it.
    public var lowThreshold: Double = 10

    /// The low-battery warning re-arms once the level is this many points above the threshold
    /// (once per crossing, 2 % hysteresis).
    public static let hysteresis: Double = 2
    /// Power-adapter changes settle for this long before "Charging" shows, so a connector that
    /// flickers on and off doesn't flash the alert ("a short debounce").
    public static let chargeDebounce: Double = 0.75

    public init() {}
}

/// Turns successive power readings into alerts: "Charging" when a power adapter is connected (after
/// a short debounce), "Low battery" once per crossing of the threshold while on battery, and
/// "Low Power" when Low Power Mode turns on. The first reading only sets the baseline.
public struct BatteryAlertMonitor: Sendable {
    public private(set) var config = BatteryAlertConfig()
    public private(set) var snapshot: PowerSnapshot?
    /// Whether the next drop to the threshold warns.
    public private(set) var lowArmed = false
    /// Deadline of a pending "Charging" alert.
    public private(set) var chargeDeadline: Double?

    public init() {}

    public mutating func setConfig(_ newValue: BatteryAlertConfig) {
        let thresholdChanged = newValue.lowThreshold != config.lowThreshold
        config = newValue
        if thresholdChanged, let snapshot { lowArmed = Double(snapshot.level) > newValue.lowThreshold }
    }

    @discardableResult
    public mutating func update(_ new: PowerSnapshot, now: Double) -> [BatteryAlert] {
        guard let old = snapshot else {
            snapshot = new
            lowArmed = new.hasBattery && Double(new.level) > config.lowThreshold
            return []
        }
        snapshot = new
        guard new.hasBattery else {
            chargeDeadline = nil
            return []
        }
        var alerts: [BatteryAlert] = []
        if new.externalPower && !old.externalPower {
            chargeDeadline = now + BatteryAlertConfig.chargeDebounce
        } else if !new.externalPower {
            chargeDeadline = nil // unplugged again within the debounce: no alert
        }
        if new.lowPowerMode && !old.lowPowerMode && config.enabled && config.lowPowerAlert {
            alerts.append(.lowPowerMode)
        }
        let level = Double(new.level)
        if level >= config.lowThreshold + BatteryAlertConfig.hysteresis { lowArmed = true }
        if lowArmed && !new.externalPower && level <= config.lowThreshold {
            lowArmed = false
            if config.enabled && config.lowWarning { alerts.append(.lowBattery) }
        }
        return alerts
    }

    /// Fires the debounced "Charging" alert once its deadline has passed.
    @discardableResult
    public mutating func tick(now: Double) -> [BatteryAlert] {
        guard let deadline = chargeDeadline, now >= deadline else { return [] }
        chargeDeadline = nil
        guard let snapshot, snapshot.hasBattery, snapshot.externalPower, config.enabled else { return [] }
        return [.charging]
    }

    public var nextDeadline: Double? { chargeDeadline }
}

/// Text helpers shared by the battery and device alerts.
public enum AlertFormat {
    /// "80 %" (Lintel's style puts a thin space before the sign).
    public static func percent(_ value: Int) -> String { "\(value) %" }

    /// "2h 5m", "45m"; nil for unknown or implausible estimates.
    public static func duration(minutes: Int?) -> String? {
        guard let minutes, minutes > 0, minutes < 100 * 60 else { return nil }
        let hours = minutes / 60, rest = minutes % 60
        if hours == 0 { return "\(rest)m" }
        return rest == 0 ? "\(hours)h" : "\(hours)h \(rest)m"
    }
}
