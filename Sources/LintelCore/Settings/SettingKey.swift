import Foundation

/// A value that can be persisted in the settings store.
public protocol SettingValue: Sendable, Equatable {
    /// Decodes a value read from `UserDefaults`; `nil` when the stored object is unusable.
    static func decode(_ object: Any) -> Self?
    /// The property-list object to store, or `nil` to remove the key.
    var encoded: Any? { get }
}

extension Bool: SettingValue {
    /// Accepts numbers and the strings used by the launch-argument domain ("YES", "true", "1", …).
    public static func decode(_ object: Any) -> Bool? {
        if let number = object as? NSNumber { return number.boolValue }
        guard let string = (object as? String)?.lowercased() else { return nil }
        switch string {
        case "yes", "true", "1": return true
        case "no", "false", "0": return false
        default: return nil
        }
    }
    public var encoded: Any? { self }
}

extension Double: SettingValue {
    public static func decode(_ object: Any) -> Double? {
        if let number = object as? NSNumber { return number.doubleValue }
        return (object as? String).flatMap { Double($0) }
    }
    public var encoded: Any? { self }
}

extension Int: SettingValue {
    public static func decode(_ object: Any) -> Int? {
        if let number = object as? NSNumber { return number.intValue }
        return (object as? String).flatMap { Int($0) }
    }
    public var encoded: Any? { self }
}

extension String: SettingValue {
    public static func decode(_ object: Any) -> String? { object as? String }
    public var encoded: Any? { self }
}

extension Optional: SettingValue where Wrapped: SettingValue {
    public static func decode(_ object: Any) -> Optional<Wrapped>? { .some(Wrapped.decode(object)) }
    public var encoded: Any? {
        switch self {
        case .none: return nil
        case .some(let value): return value.encoded
        }
    }
}

/// A closed set of options stored by their raw string value.
public protocol SettingChoice: SettingValue, RawRepresentable, CaseIterable where RawValue == String {}

extension SettingChoice {
    public static func decode(_ object: Any) -> Self? { (object as? String).flatMap(Self.init(rawValue:)) }
    public var encoded: Any? { rawValue }
}

/// A typed, defaulted settings key. Names are namespaced, e.g. `island.expandOnHover`.
public struct SettingKey<Value: SettingValue>: Sendable {
    public let name: String
    public let defaultValue: Value

    public init(_ name: String, default defaultValue: Value) {
        self.name = name
        self.defaultValue = defaultValue
    }
}
