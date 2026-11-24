import Foundation

/// Durations typed into the custom-timer window. Case-insensitive,
/// spaces optional: `25` (minutes), `2.5` / `2,5`, `90s`, `10 min`, `1h`, `1h 30m`, `1h30`, `2m30s`,
/// `2m 30`, `1:30` (m:ss), `1:30:00` (h:mm:ss). Result: whole seconds within 1 s … 24 h, else nil.
public enum TimerDuration {
    public static func parse(_ text: String) -> Double? {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !input.isEmpty, input.count <= 40 else { return nil }
        let seconds: Double?
        if input.contains(":") {
            seconds = clock(input)
        } else if let minutes = decimal(input) {
            seconds = minutes * 60
        } else {
            seconds = units(input)
        }
        return seconds.flatMap(TimerPolicy.validDuration)
    }

    /// A plain decimal number with `.` or `,` as the separator (no sign, exponent or grouping).
    public static func decimal(_ text: String) -> Double? {
        let chars = Array(text)
        guard !chars.isEmpty, chars.count <= 12 else { return nil }
        var digits = 0, separators = 0
        for char in chars {
            if char.isASCII, char.isNumber { digits += 1 } else if char == "." || char == "," { separators += 1 } else { return nil }
        }
        guard digits > 0, separators <= 1 else { return nil }
        if separators == 1, chars.last == "." || chars.last == "," { return nil }
        return Double(text.replacingOccurrences(of: ",", with: "."))
    }

    /// `m:ss`, `h:mm:ss`; the parts after the first need two digits, 00–59.
    private static func clock(_ text: String) -> Double? {
        let parts = text.replacingOccurrences(of: " ", with: "").split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 || parts.count == 3, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }),
              parts[0].count <= 4 else { return nil }
        let numbers = parts.compactMap { Int($0) }
        guard numbers.count == parts.count else { return nil }
        for (index, part) in parts.enumerated() where index > 0 {
            guard part.count == 2, numbers[index] < 60 else { return nil }
        }
        if parts.count == 2 { return Double(numbers[0] * 60 + numbers[1]) }
        return Double(numbers[0] * 3600 + numbers[1] * 60 + numbers[2])
    }

    private enum Unit: Int { case hours = 3, minutes = 2, seconds = 1
        var factor: Double { self == .hours ? 3600 : self == .minutes ? 60 : 1 }
        var smaller: Unit? { Unit(rawValue: rawValue - 1) }
    }

    private static let unitWords: [(String, Unit)] = [
        ("hours", .hours), ("hour", .hours), ("hrs", .hours), ("hr", .hours), ("h", .hours),
        ("minutes", .minutes), ("minute", .minutes), ("mins", .minutes), ("min", .minutes), ("m", .minutes),
        ("seconds", .seconds), ("second", .seconds), ("secs", .seconds), ("sec", .seconds), ("s", .seconds),
    ]

    /// Numbers with units, largest first, each unit once; a trailing bare number takes the next
    /// smaller unit (`1h30` → 1 h 30 min, `2m 30` → 2 min 30 s).
    private static func units(_ text: String) -> Double? {
        var rest = Substring(text)
        var total = 0.0
        var previous: Unit?
        var sawNumber = false
        while true {
            rest = rest.drop { $0 == " " }
            if rest.isEmpty { break }
            let number = rest.prefix { ($0.isASCII && $0.isNumber) || $0 == "." || $0 == "," }
            guard !number.isEmpty, let value = decimal(String(number)) else { return nil }
            rest = rest.dropFirst(number.count).drop { $0 == " " }
            var unit: Unit?
            for (word, candidate) in unitWords where rest.hasPrefix(word) {
                let after = rest.dropFirst(word.count)
                if let next = after.first, next.isLetter { continue } // "min" must not match "mins…" partially
                unit = candidate
                rest = after
                break
            }
            if unit == nil {
                // A bare number after a unit takes the next smaller one; on its own it means minutes
                // (handled by `decimal` before we get here), so it is invalid here.
                guard let previous, let smaller = previous.smaller, rest.drop(while: { $0 == " " }).isEmpty else { return nil }
                unit = smaller
            }
            guard let resolved = unit else { return nil }
            if let previous, resolved.rawValue >= previous.rawValue { return nil }
            total += value * resolved.factor
            previous = resolved
            sawNumber = true
        }
        return sawNumber ? total : nil
    }
}

/// Commands from `lintel://timer…` links.
public enum TimerURLCommand: Equatable, Sendable {
    case start(seconds: Double)
    case pause
    case resume
    case restart
    case add(seconds: Double)
    case cancel

    public enum Failure: Error, Equatable, Sendable, CustomStringConvertible {
        case notLintel
        case unknownRoute(String)
        case missingMinutes
        case invalidMinutes(String)
        case outOfRange(String)

        public var description: String {
            switch self {
            case .notLintel: return "not a lintel://timer link"
            case .unknownRoute(let route): return "unknown route \"\(route)\""
            case .missingMinutes: return "minutes=N is missing"
            case .invalidMinutes(let value): return "minutes=\"\(value)\" isn't a number"
            case .outOfRange(let value): return "minutes=\(value) is outside 1 s … 24 h"
            }
        }
    }

    public static let scheme = "lintel"

    /// `lintel://timer?minutes=N` (or `/start?minutes=N`), `/pause`, `/resume`, `/restart`,
    /// `/add[?minutes=N]` (default 1), `/cancel`. N: decimal minutes (`.` or `,`), N × 60 rounded to
    /// whole seconds within 1 s … 24 h; the first `minutes` counts, other parameters are ignored.
    public static func parse(_ url: URL) -> Result<TimerURLCommand, Failure> {
        guard url.scheme?.lowercased() == scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.host?.lowercased() == "timer" else { return .failure(.notLintel) }
        var route = components.path.lowercased()
        while route.hasSuffix("/") { route.removeLast() }
        if route.hasPrefix("/") { route.removeFirst() }
        let minutesText = components.queryItems?.first { $0.name.lowercased() == "minutes" }?.value

        func duration(required: Bool, default fallback: Double?) -> Result<Double, Failure> {
            guard let raw = minutesText?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
                if let fallback, !required { return .success(fallback) }
                return .failure(.missingMinutes)
            }
            guard let minutes = TimerDuration.decimal(raw) else { return .failure(.invalidMinutes(raw)) }
            guard let seconds = TimerPolicy.validDuration(minutes * 60) else { return .failure(.outOfRange(raw)) }
            return .success(seconds)
        }

        switch route {
        case "", "start":
            return duration(required: true, default: nil).map { .start(seconds: $0) }
        case "add":
            return duration(required: false, default: 60).map { .add(seconds: $0) }
        case "pause": return .success(.pause)
        case "resume": return .success(.resume)
        case "restart": return .success(.restart)
        case "cancel", "stop": return .success(.cancel)
        default: return .failure(.unknownRoute(route))
        }
    }
}
