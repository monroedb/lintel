import CoreLocation
import Foundation
import LintelCore
import MapKit

/// Travel times to an event's place (MapKit, public).
@MainActor
protocol TravelTimeEstimating: AnyObject {
    func travelTime(from origin: GeoCoordinate, to destination: GeoCoordinate, mode: TravelMode) async -> TimeInterval?
    func coordinate(for address: String) async -> GeoCoordinate?
}

/// MapKit ETA (`MKDirections.calculateETA`, which also covers public transport) and geocoding of
/// free-text locations (cached per text).
@MainActor
final class MapKitTravelEstimator: TravelTimeEstimating {
    private var geocoded: [String: GeoCoordinate?] = [:]
    private var inFlight: [ObjectIdentifier: MKDirections] = [:]
    private let geocoder = CLGeocoder()

    func travelTime(from origin: GeoCoordinate, to destination: GeoCoordinate, mode: TravelMode) async -> TimeInterval? {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: origin.latitude, longitude: origin.longitude)))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: destination.latitude,
                                                                                                    longitude: destination.longitude)))
        switch mode {
        case .driving: request.transportType = .automobile
        case .walking: request.transportType = .walking
        case .transit: request.transportType = .transit
        }
        let directions = MKDirections(request: request)
        let key = ObjectIdentifier(directions)
        inFlight[key] = directions
        defer { inFlight[key] = nil }
        return await withCheckedContinuation { continuation in
            directions.calculateETA { response, _ in
                continuation.resume(returning: response?.expectedTravelTime)
            }
        }
    }

    func coordinate(for address: String) async -> GeoCoordinate? {
        if let cached = geocoded[address] { return cached }
        let point: GeoCoordinate? = await withCheckedContinuation { continuation in
            geocoder.geocodeAddressString(address) { placemarks, _ in
                let coordinate = placemarks?.first?.location?.coordinate
                continuation.resume(returning: coordinate.map { GeoCoordinate(latitude: $0.latitude, longitude: $0.longitude) })
            }
        }
        geocoded[address] = point
        return point
    }
}

/// Posts one time-to-leave alert per event when now ≥ start − travel time − buffer,
/// with the travel sound. Needs Location; quietly does nothing without it.
@MainActor
final class TimeToLeaveMonitor {
    struct Estimate {
        var seconds: TimeInterval
        var at: Date
        var mode: TravelMode
    }

    private(set) var alerted: Set<String> = []
    private(set) var estimates: [String: Estimate] = [:]
    private(set) var lastAlert: (eventID: String, travel: TimeInterval, at: Date)?
    private(set) var nextCheck: Date?
    /// Latest events to consider (included calendars, any display mode).
    var events: () -> [CalendarEventRecord] = { [] }

    private let settings: SettingsStore
    private let hub: ActivityHub
    private let location: LocationProviding
    private let estimator: TravelTimeEstimating
    private let tones: TonePlayer
    private var checkTask: Task<Void, Never>?
    private var estimating: Set<String> = []
    private var failures: [String: Date] = [:]

    init(settings: SettingsStore, hub: ActivityHub, location: LocationProviding, estimator: TravelTimeEstimating, tones: TonePlayer) {
        self.settings = settings
        self.hub = hub
        self.location = location
        self.estimator = estimator
        self.tones = tones
    }

    var isEnabled: Bool { settings[Keys.calendarEnabled] && settings[Keys.timeToLeaveEnabled] }

    func update(now: Date = Date()) {
        checkTask?.cancel()
        nextCheck = nil
        guard isEnabled else { return }
        let buffer = settings[Keys.timeToLeaveBufferMinutes] * 60
        let mode = settings[Keys.timeToLeaveMode]
        let all = events()
        var next: Date?
        for event in TimeToLeavePlanner.candidates(events: all, now: now, alerted: alerted).prefix(3) {
            var travel: TimeInterval?
            if let estimate = estimates[event.id], estimate.mode == mode,
               now.timeIntervalSince(estimate.at) < TimeToLeavePlanner.refreshInterval {
                travel = estimate.seconds
            }
            guard let travel else {
                requestEstimate(for: event, mode: mode, now: now)
                continue
            }
            if TimeToLeavePlanner.isDue(now: now, start: event.start, travel: travel, buffer: buffer) {
                alert(event, travel: travel, mode: mode, now: now)
            } else {
                let check = TimeToLeavePlanner.nextCheck(now: now, start: event.start, travel: travel, buffer: buffer)
                next = min(next ?? check, check)
            }
        }
        // Keep an eye on events that come within range later.
        if next == nil, all.contains(where: { $0.start > now }) {
            next = now.addingTimeInterval(TimeToLeavePlanner.refreshInterval)
        }
        guard let next else { return }
        nextCheck = next
        checkTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0.05, next.timeIntervalSinceNow)), tolerance: .milliseconds(100))
            guard !Task.isCancelled else { return }
            self?.update()
        }
    }

    private func alert(_ event: CalendarEventRecord, travel: TimeInterval, mode: TravelMode, now: Date) {
        alerted.insert(event.id)
        lastAlert = (event.id, travel, now)
        hub.post(.timeToLeave, payload: NotificationPayload(symbol: mode.symbol, label: "Leave now",
                                                             value: TimeToLeavePlanner.travelLabel(travel)))
        if settings[Keys.timeToLeaveSound] { tones.play(.leaveNow) }
    }

    private func requestEstimate(for event: CalendarEventRecord, mode: TravelMode, now: Date) {
        guard !estimating.contains(event.id) else { return }
        if let failed = failures[event.id], now.timeIntervalSince(failed) < TimeToLeavePlanner.refreshInterval { return }
        estimating.insert(event.id)
        Task { [weak self] in
            guard let self else { return }
            let seconds = await self.estimate(event, mode: mode)
            self.estimating.remove(event.id)
            if let seconds {
                self.estimates[event.id] = Estimate(seconds: seconds, at: Date(), mode: mode)
                self.failures[event.id] = nil
                self.update()
            } else {
                self.failures[event.id] = Date()
            }
        }
    }

    private func estimate(_ event: CalendarEventRecord, mode: TravelMode) async -> TimeInterval? {
        guard let origin = await location.currentLocation(maxAge: 5 * 60, accuracy: kCLLocationAccuracyHundredMeters, timeout: 15) else {
            return nil
        }
        let destination: GeoCoordinate?
        if let latitude = event.latitude, let longitude = event.longitude {
            destination = GeoCoordinate(latitude: latitude, longitude: longitude)
        } else if let text = event.location {
            destination = await estimator.coordinate(for: text)
        } else {
            destination = nil
        }
        guard let destination else { return nil }
        return await estimator.travelTime(from: origin, to: destination, mode: mode)
    }

    func forgetAlerts() {
        alerted.removeAll()
        lastAlert = nil
    }
}

/// Chimes on the hour while the setting is on.
@MainActor
final class HourlyChimeTimer {
    private(set) var nextFire: Date?
    private(set) var fired = 0
    var isEnabled: () -> Bool = { false }
    var onChime: () -> Void = {}
    private var task: Task<Void, Never>?

    /// Schedules the next chime at the top of the hour, or at `next` when given.
    func reschedule(now: Date = Date(), next override: Date? = nil) {
        task?.cancel()
        nextFire = nil
        guard isEnabled() else { return }
        let next = override ?? HourlyChimeSchedule.next(after: now, calendar: .current)
        nextFire = next
        task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, next.timeIntervalSinceNow)), tolerance: .milliseconds(100))
            guard !Task.isCancelled, let self else { return }
            // Woken late (sleep, clock change)? Only chime close to the hour.
            if abs(Date().timeIntervalSince(next)) < 60, self.isEnabled() {
                self.fired += 1
                self.onChime()
            }
            self.reschedule()
        }
    }

    func stop() {
        task?.cancel()
        nextFire = nil
    }
}
