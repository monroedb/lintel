import CoreLocation
import Foundation
import LintelCore
import Observation

/// Weather for the open card's free-day state, from Open-Meteo instead of
/// WeatherKit (free, no key). Only rounded coordinates leave the Mac; the last report is cached in
/// the settings domain and errors are handled quietly.
@MainActor
@Observable
final class WeatherStore {
    private(set) var report: WeatherReport?
    private(set) var lastError: String?
    private(set) var fetchCount = 0
    private(set) var lastAttempt: Date?
    /// Mirrors the location permission (set by the feature); without it the weather is hidden.
    var locationAuthorized = false

    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let location: LocationProviding
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var periodicTask: Task<Void, Never>?
    /// While the displays sleep or the session is locked the half-hourly refresh waits (nobody sees
    /// the card); it catches up as soon as they wake.
    @ObservationIgnored var paused = false {
        didSet { if oldValue, !paused { refreshIfNeeded() } }
    }

    init(settings: SettingsStore, location: LocationProviding) {
        self.settings = settings
        self.location = location
        report = WeatherReport.decode(json: settings[Keys.weatherCache])
    }

    /// Weather is fetched only while a feature that shows it is on.
    var isWanted: Bool { settings[Keys.calendarEnabled] && settings[Keys.calendarWeatherOnFreeDay] }

    /// What the card shows: a recent report when Location is allowed.
    var displayReport: WeatherReport? {
        guard locationAuthorized, WeatherCachePolicy.isDisplayable(report, now: Date()) else { return nil }
        return report
    }

    /// Starts or stops the half-hourly refresh to match the settings.
    func updateSchedule() {
        periodicTask?.cancel()
        periodicTask = nil
        guard isWanted else { return }
        refreshIfNeeded()
        periodicTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(WeatherCachePolicy.maxAge))
                guard !Task.isCancelled else { return }
                if self?.paused == false { self?.refreshIfNeeded() }
            }
        }
    }

    func refreshIfNeeded(force: Bool = false) {
        guard isWanted, locationAuthorized, refreshTask == nil else { return }
        if !force, let lastAttempt, Date().timeIntervalSince(lastAttempt) < WeatherCachePolicy.retryInterval,
           WeatherCachePolicy.isDisplayable(report, now: Date()) {
            return
        }
        lastAttempt = Date()
        refreshTask = Task { [weak self] in
            await self?.refresh(force: force)
            self?.refreshTask = nil
        }
    }

    private func refresh(force: Bool) async {
        guard let point = await location.currentLocation(maxAge: 30 * 60, accuracy: kCLLocationAccuracyKilometer, timeout: 15) else {
            lastError = "location unavailable"
            return
        }
        guard force || WeatherCachePolicy.needsRefresh(cached: report, now: Date(), latitude: point.latitude, longitude: point.longitude),
              let url = OpenMeteo.requestURL(latitude: point.latitude, longitude: point.longitude) else { return }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            fetchCount += 1
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode), http.statusCode != 400 {
                lastError = "HTTP \(http.statusCode)"
                return
            }
            let fresh = try OpenMeteo.parse(data, fetchedAt: Date(), latitude: point.latitude, longitude: point.longitude)
            report = fresh
            lastError = nil
            settings[Keys.weatherCache] = fresh.encodedJSON()
        } catch {
            lastError = (error as? OpenMeteo.ParseError).map { "\($0)" } ?? "network"
        }
    }

    /// Temperature in the user's unit (°C/°F by preference or region).
    static var unit: TemperatureUnitChoice {
        TemperatureUnitChoice.resolve(preference: UserDefaults.standard.string(forKey: "AppleTemperatureUnit"),
                                      regionCode: Locale.current.region?.identifier)
    }
}
