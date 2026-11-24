import Foundation
import Observation

public extension Notification.Name {
    /// Posted on the main actor after a setting changes; `userInfo["key"]` holds the key name.
    static let lintelSettingDidChange = Notification.Name("LintelSettingDidChange")
}

/// Typed settings storage on top of `UserDefaults`, observable by SwiftUI and by AppKit code.
///
/// Reads fall back to the key's default when nothing (or something unusable) is stored. Writing
/// the default value still stores it explicitly; `reset(_:)` removes the key.
@MainActor
@Observable
public final class SettingsStore {
    @ObservationIgnored public let defaults: UserDefaults
    @ObservationIgnored private let center: NotificationCenter
    /// Bumped on every change; reading it inside `subscript` registers Observation tracking.
    private var revision: Int = 0

    public init(defaults: UserDefaults = .standard, center: NotificationCenter = .default) {
        self.defaults = defaults
        self.center = center
    }

    public subscript<Value: SettingValue>(key: SettingKey<Value>) -> Value {
        get {
            _ = revision
            guard let object = defaults.object(forKey: key.name), let value = Value.decode(object) else {
                return key.defaultValue
            }
            return value
        }
        set {
            if let encoded = newValue.encoded {
                defaults.set(encoded, forKey: key.name)
            } else {
                defaults.removeObject(forKey: key.name)
            }
            didChange(key.name)
        }
    }

    /// Whether a value is explicitly stored for the key.
    public func hasValue<Value>(for key: SettingKey<Value>) -> Bool {
        _ = revision
        return defaults.object(forKey: key.name) != nil
    }

    public func reset<Value>(_ key: SettingKey<Value>) {
        defaults.removeObject(forKey: key.name)
        didChange(key.name)
    }

    /// Call when the underlying defaults may have changed outside this store (e.g. `defaults write`).
    public func externalChange(keyName: String? = nil) {
        didChange(keyName ?? "*")
    }

    private func didChange(_ name: String) {
        revision &+= 1
        center.post(name: .lintelSettingDidChange, object: self, userInfo: ["key": name])
    }
}
