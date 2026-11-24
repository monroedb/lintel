import Foundation

/// Messages exchanged with the third-party BetterDisplay app over distributed notifications. The
/// exact request values are unconfirmed.
public enum BetterDisplayProtocol {
    public static let bundleID = "pro.betterdisplay.BetterDisplay"
    public static let launchedNotification = "pro.betterdisplay.BetterDisplay.launched"
    public static let terminatedNotification = "pro.betterdisplay.BetterDisplay.terminated"
    public static let requestNotification = "com.betterdisplay.BetterDisplay.request"
    public static let osdNotification = "com.betterdisplay.BetterDisplay.osd"

    /// Parameters of the "set" request: integration on → BetterDisplay posts OSD notifications and
    /// hides its own OSDs; off → its own OSDs come back (sent on quit).
    public static func requestParameters(integrate: Bool) -> [String: String] {
        [
            "osdIntegrationNotification": integrate ? "on" : "off",
            "osdShowBasic": integrate ? "off" : "on",
            "osdShowCustom": integrate ? "off" : "on",
        ]
    }

    /// JSON body of the request notification (posted as the notification's object).
    public static func requestJSON(integrate: Bool, requestID: String) -> String {
        let body: [String: Any] = ["uuid": requestID, "commands": ["set"], "parameters": requestParameters(integrate: integrate)]
        guard let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    /// One OSD event from BetterDisplay.
    public struct OSDEvent: Equatable, Sendable {
        public var kind: HUDKind
        public var level: Double
        public var muted: Bool
        public var displayID: UInt32?
        public var displayUUID: String?

        public init(kind: HUDKind, level: Double, muted: Bool = false, displayID: UInt32? = nil, displayUUID: String? = nil) {
            self.kind = kind
            self.level = level
            self.muted = muted
            self.displayID = displayID
            self.displayUUID = displayUUID
        }
    }

    /// Parses an OSD notification: a JSON object in the notification's object string and/or a
    /// userInfo dictionary. The field names are matched loosely (icon/value/max/display id/uuid),
    /// since the exact schema is unconfirmed; unknown icons are ignored.
    public static func parseOSD(object: String?, userInfo: [String: Any]?) -> OSDEvent? {
        var fields: [String: Any] = [:]
        if let object, let data = object.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            fields.merge(json) { current, _ in current }
        }
        if let userInfo { fields.merge(userInfo) { current, _ in current } }
        guard !fields.isEmpty else { return nil }
        var lower: [String: Any] = [:]
        for (key, value) in fields { lower[key.lowercased()] = value }

        func string(_ names: [String]) -> String? {
            for name in names { if let value = lower[name] { return "\(value)" } }
            return nil
        }
        func number(_ names: [String]) -> Double? {
            for name in names {
                if let value = lower[name] as? NSNumber { return value.doubleValue }
                if let value = lower[name] as? String, let parsed = Double(value) { return parsed }
            }
            return nil
        }

        let icon = (string(["systemiconid", "icon", "iconname", "osdicon", "type", "control"]) ?? "").lowercased()
        let kind: HUDKind
        var muted = icon.contains("mute")
        if icon.contains("bright") || icon.contains("sun") || icon.contains("display") || icon.contains("contrast") {
            kind = .brightness
        } else if icon.contains("volume") || icon.contains("speaker") || icon.contains("audio") || icon.contains("sound") || muted {
            kind = .volume
        } else {
            return nil
        }
        guard let value = number(["value", "currentvalue", "level"]) else { return nil }
        let maximum = number(["maxvalue", "max", "maximum"]) ?? (value > 1 ? 100 : 1)
        guard maximum > 0 else { return nil }
        if let flag = lower["muted"] ?? lower["mute"] {
            if let bool = flag as? Bool { muted = bool } else if let n = flag as? NSNumber { muted = n.boolValue }
        }
        let displayID = number(["displayid", "tagid", "id"]).flatMap { $0 >= 0 && $0 <= Double(UInt32.max) ? UInt32($0) : nil }
        let uuid = string(["uuid", "displayuuid"])
        return OSDEvent(kind: kind, level: min(1, max(0, value / maximum)), muted: muted, displayID: displayID, displayUUID: uuid)
    }
}

/// Which islands show a HUD (the display affected by the change — the pointer's
/// display for volume, the adjusted display for brightness — when it has an island; otherwise all).
public enum HUDRouting {
    public static func screens(target: String?, islands: [String]) -> [String] {
        if let target, islands.contains(target) { return [target] }
        return islands
    }
}
