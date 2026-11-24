import Foundation

/// A place on Earth in degrees (WGS 84).
public struct GeoCoordinate: Equatable, Hashable, Sendable, Codable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    /// Parses "lat,lon".
    public init?(text: String) {
        let parts = text.split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 2, let lat = parts[0], let lon = parts[1], abs(lat) <= 90, abs(lon) <= 180 else { return nil }
        self.init(latitude: lat, longitude: lon)
    }
}
