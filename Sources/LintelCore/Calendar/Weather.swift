import Foundation

/// Weather conditions from WMO weather codes (as reported by Open-Meteo), with Lintel's wording
/// and SF Symbols.
public enum WeatherCondition: String, Codable, Sendable, CaseIterable {
    case clear, mostlyClear, partlyCloudy, cloudy, fog
    case drizzle, freezingDrizzle, rain, heavyRain, freezingRain
    case snow, heavySnow, showers, snowShowers, thunderstorm, hail, unknown

    public init(wmoCode code: Int) {
        switch code {
        case 0: self = .clear
        case 1: self = .mostlyClear
        case 2: self = .partlyCloudy
        case 3: self = .cloudy
        case 45, 48: self = .fog
        case 51, 53, 55: self = .drizzle
        case 56, 57: self = .freezingDrizzle
        case 61, 63: self = .rain
        case 65: self = .heavyRain
        case 66, 67: self = .freezingRain
        case 71, 73, 77: self = .snow
        case 75: self = .heavySnow
        case 80, 81, 82: self = .showers
        case 85, 86: self = .snowShowers
        case 95: self = .thunderstorm
        case 96, 99: self = .hail
        default: self = .unknown
        }
    }

    public var title: String {
        switch self {
        case .clear: return "Clear"
        case .mostlyClear: return "Mostly clear"
        case .partlyCloudy: return "Some clouds"
        case .cloudy: return "Overcast"
        case .fog: return "Fog"
        case .drizzle: return "Drizzle"
        case .freezingDrizzle: return "Freezing drizzle"
        case .rain: return "Rain"
        case .heavyRain: return "Heavy rain"
        case .freezingRain: return "Freezing rain"
        case .snow: return "Snow"
        case .heavySnow: return "Heavy snow"
        case .showers: return "Showers"
        case .snowShowers: return "Snow showers"
        case .thunderstorm: return "Thunderstorms"
        case .hail: return "Storms with hail"
        case .unknown: return "Weather"
        }
    }

    public func symbol(isDay: Bool) -> String {
        switch self {
        case .clear: return isDay ? "sun.max.fill" : "moon.stars.fill"
        case .mostlyClear: return isDay ? "sun.max.fill" : "moon.fill"
        case .partlyCloudy: return isDay ? "cloud.sun.fill" : "cloud.moon.fill"
        case .cloudy: return "cloud.fill"
        case .fog: return "cloud.fog.fill"
        case .drizzle: return "cloud.drizzle.fill"
        case .freezingDrizzle, .freezingRain: return "cloud.sleet.fill"
        case .rain: return "cloud.rain.fill"
        case .heavyRain: return "cloud.heavyrain.fill"
        case .snow, .heavySnow, .snowShowers: return "cloud.snow.fill"
        case .showers: return isDay ? "cloud.sun.rain.fill" : "cloud.moon.rain.fill"
        case .thunderstorm: return "cloud.bolt.rain.fill"
        case .hail: return "cloud.hail.fill"
        case .unknown: return "cloud.fill"
        }
    }

    public var isWet: Bool {
        switch self {
        case .drizzle, .freezingDrizzle, .rain, .heavyRain, .freezingRain, .showers, .thunderstorm, .hail: return true
        default: return false
        }
    }
}

/// The cached weather (`cachedWeather`): condition, °C, today's and the next sunrise and sunset,
/// chance of precipitation, whether it's raining, when it was fetched and for which coordinates.
public struct WeatherReport: Codable, Equatable, Sendable {
    public var condition: WeatherCondition
    public var code: Int
    public var isDay: Bool
    public var temperatureCelsius: Double
    public var sunrise: Date?
    public var sunset: Date?
    public var nextSunrise: Date?
    public var nextSunset: Date?
    /// Chance of precipitation today, 0…1.
    public var precipitationChance: Double?
    public var isRaining: Bool
    public var fetchedAt: Date
    /// Rounded coordinates the report was fetched for.
    public var latitude: Double
    public var longitude: Double

    public init(condition: WeatherCondition, code: Int, isDay: Bool, temperatureCelsius: Double, sunrise: Date? = nil,
                sunset: Date? = nil, nextSunrise: Date? = nil, nextSunset: Date? = nil, precipitationChance: Double? = nil,
                isRaining: Bool, fetchedAt: Date, latitude: Double, longitude: Double) {
        self.condition = condition
        self.code = code
        self.isDay = isDay
        self.temperatureCelsius = temperatureCelsius
        self.sunrise = sunrise
        self.sunset = sunset
        self.nextSunrise = nextSunrise
        self.nextSunset = nextSunset
        self.precipitationChance = precipitationChance
        self.isRaining = isRaining
        self.fetchedAt = fetchedAt
        self.latitude = latitude
        self.longitude = longitude
    }

    public func encodedJSON() -> String? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) }
    }

    public static func decode(json: String?) -> WeatherReport? {
        guard let data = json?.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(WeatherReport.self, from: data)
    }
}

/// Open-Meteo forecast API (free, no key): request building and parsing. Coordinates are rounded to
/// 0.01° (about 1 km) before they leave the Mac.
public enum OpenMeteo {
    public static let endpoint = "https://api.open-meteo.com/v1/forecast"
    public static let coordinateStep = 0.01

    public static func rounded(_ value: Double, step: Double = coordinateStep) -> Double {
        ((value / step).rounded() * step * 100).rounded() / 100
    }

    public static func requestURL(latitude: Double, longitude: Double) -> URL? {
        var components = URLComponents(string: endpoint)
        components?.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.2f", rounded(latitude))),
            URLQueryItem(name: "longitude", value: String(format: "%.2f", rounded(longitude))),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code,is_day,precipitation"),
            URLQueryItem(name: "daily", value: "sunrise,sunset,precipitation_probability_max"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "forecast_days", value: "2"),
            URLQueryItem(name: "timeformat", value: "unixtime"),
        ]
        return components?.url
    }

    public enum ParseError: Error, Equatable {
        case notJSON
        case service(String)
        case missingCurrent
    }

    public static func parse(_ data: Data, fetchedAt: Date, latitude: Double, longitude: Double) throws -> WeatherReport {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw ParseError.notJSON }
        if root["error"] as? Bool == true { throw ParseError.service(root["reason"] as? String ?? "error") }
        guard let current = root["current"] as? [String: Any],
              let temperature = number(current["temperature_2m"]),
              let code = number(current["weather_code"]).map({ Int($0) }) else { throw ParseError.missingCurrent }
        let isDay = (number(current["is_day"]) ?? 1) > 0
        let precipitation = number(current["precipitation"]) ?? 0
        let daily = root["daily"] as? [String: Any] ?? [:]
        func dates(_ key: String) -> [Date] {
            (daily[key] as? [Any] ?? []).compactMap(number).map { Date(timeIntervalSince1970: $0) }
        }
        let sunrises = dates("sunrise"), sunsets = dates("sunset")
        let chance = (daily["precipitation_probability_max"] as? [Any])?.first.flatMap(number).map { $0 / 100 }
        let condition = WeatherCondition(wmoCode: code)
        return WeatherReport(condition: condition, code: code, isDay: isDay, temperatureCelsius: temperature,
                             sunrise: sunrises.first, sunset: sunsets.first,
                             nextSunrise: sunrises.first(where: { $0 > fetchedAt }), nextSunset: sunsets.first(where: { $0 > fetchedAt }),
                             precipitationChance: chance, isRaining: condition.isWet || precipitation > 0,
                             fetchedAt: fetchedAt, latitude: rounded(latitude), longitude: rounded(longitude))
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        return nil
    }
}

/// When to fetch again and when a cached report is still worth showing.
public enum WeatherCachePolicy {
    /// A report is refreshed once it is this old.
    public static let maxAge: TimeInterval = 30 * 60
    /// Older reports are hidden rather than shown stale.
    public static let displayAge: TimeInterval = 3 * 3600
    /// Failed or throttled attempts wait at least this long.
    public static let retryInterval: TimeInterval = 5 * 60
    /// Moving farther than this (degrees) fetches for the new place.
    public static let moveThreshold = 0.1

    public static func needsRefresh(cached: WeatherReport?, now: Date, latitude: Double, longitude: Double) -> Bool {
        guard let cached else { return true }
        if now.timeIntervalSince(cached.fetchedAt) >= maxAge || now < cached.fetchedAt { return true }
        let moved = max(abs(OpenMeteo.rounded(latitude) - cached.latitude), abs(OpenMeteo.rounded(longitude) - cached.longitude))
        return moved > moveThreshold
    }

    public static func isDisplayable(_ report: WeatherReport?, now: Date) -> Bool {
        guard let report else { return false }
        let age = now.timeIntervalSince(report.fetchedAt)
        return age >= -60 && age < displayAge
    }
}

/// °C or °F: the user's explicit preference (`AppleTemperatureUnit`), else the region's custom
/// (units follow the locale; the UK uses °C).
public enum TemperatureUnitChoice: String, Sendable, Equatable {
    case celsius, fahrenheit

    static let fahrenheitRegions: Set<String> = ["US", "PR", "GU", "VI", "AS", "MP", "UM", "BS", "BZ", "KY", "PW", "LR", "FM", "MH"]

    public static func resolve(preference: String?, regionCode: String?) -> TemperatureUnitChoice {
        switch preference?.lowercased() {
        case "fahrenheit": return .fahrenheit
        case "celsius": return .celsius
        default: return fahrenheitRegions.contains(regionCode?.uppercased() ?? "") ? .fahrenheit : .celsius
        }
    }

    public func value(fromCelsius celsius: Double) -> Double {
        self == .celsius ? celsius : celsius * 9 / 5 + 32
    }

    /// "4°" (the unit is implied by the locale, as in the system's own weather displays).
    public func label(celsius: Double) -> String {
        let value = value(fromCelsius: celsius).rounded()
        return "\(Int(value == 0 ? 0 : value))°"
    }
}
