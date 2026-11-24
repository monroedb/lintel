import CoreLocation
import Foundation
import LintelCore

/// Location access as Lintel sees it (services disabled, not authorized, timeout).
enum LocationAccess: String {
    case notDetermined, denied, restricted, authorized, servicesOff

    var isAuthorized: Bool { self == .authorized }
}

/// Current location for weather and travel times (CoreLocation, public).
@MainActor
protocol LocationProviding: AnyObject {
    var access: LocationAccess { get }
    var onAccessChange: (() -> Void)? { get set }
    func requestAccess()
    /// A location no older than `maxAge`, or nil (no access, services off, error or timeout).
    func currentLocation(maxAge: TimeInterval, accuracy: CLLocationAccuracy, timeout: TimeInterval) async -> GeoCoordinate?
}

@MainActor
final class CoreLocationProvider: NSObject, LocationProviding, CLLocationManagerDelegate {
    var onAccessChange: (() -> Void)?
    private let manager = CLLocationManager()
    private var waiting: [CheckedContinuation<GeoCoordinate?, Never>] = []
    private var timeoutTask: Task<Void, Never>?
    private var last: (point: GeoCoordinate, at: Date)?
    private(set) var lastError: String?
    private(set) var requests = 0
    /// System-wide Location Services switch, read off the main thread (the call can block).
    private var servicesEnabled = true

    override init() {
        super.init()
        manager.delegate = self
        refreshServicesState()
    }

    private func refreshServicesState() {
        Task.detached { [weak self] in
            let enabled = CLLocationManager.locationServicesEnabled()
            await self?.servicesStateChanged(enabled)
        }
    }

    private func servicesStateChanged(_ enabled: Bool) {
        guard enabled != servicesEnabled else { return }
        servicesEnabled = enabled
        onAccessChange?()
    }

    var access: LocationAccess {
        guard servicesEnabled else { return .servicesOff }
        switch manager.authorizationStatus {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .authorizedAlways, .authorized: return .authorized
        @unknown default: return .denied
        }
    }

    func requestAccess() {
        guard manager.authorizationStatus == .notDetermined else { return }
        manager.requestWhenInUseAuthorization()
    }

    func currentLocation(maxAge: TimeInterval, accuracy: CLLocationAccuracy, timeout: TimeInterval) async -> GeoCoordinate? {
        if let last, Date().timeIntervalSince(last.at) <= maxAge { return last.point }
        guard access.isAuthorized else { return nil }
        return await withCheckedContinuation { continuation in
            waiting.append(continuation)
            guard waiting.count == 1 else { return }
            requests += 1
            manager.desiredAccuracy = accuracy
            manager.requestLocation()
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                guard !Task.isCancelled else { return }
                self?.finish(with: nil, error: "timeout")
            }
        }
    }

    private func finish(with point: GeoCoordinate?, error: String?) {
        timeoutTask?.cancel()
        timeoutTask = nil
        if let point { last = (point, Date()) }
        lastError = error
        let pending = waiting
        waiting.removeAll()
        pending.forEach { $0.resume(returning: point) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let coordinate = locations.last?.coordinate else { return }
        let point = GeoCoordinate(latitude: coordinate.latitude, longitude: coordinate.longitude)
        MainActor.assumeIsolated { finish(with: point, error: nil) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let code = (error as? CLError)?.code
        let text = code == .denied ? "denied" : (code == .locationUnknown ? "unknown" : "error")
        // `locationUnknown` is transient: keep waiting until the timeout.
        guard code != .locationUnknown else { return }
        MainActor.assumeIsolated { finish(with: nil, error: text) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated {
            refreshServicesState()
            onAccessChange?()
        }
    }
}
