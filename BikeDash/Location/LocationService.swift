import BikeDashCore
import CoreLocation
import Foundation
import Observation
import os

private let log = Logger(subsystem: "com.jlmoh.bikedash", category: "location")

/// Phone GPS. Hands every fix to `onFix` (the ride decides which to trust) and
/// keeps going in the background (blue pill) so a ride isn't cut short.
/// It runs only when the ride asks for it: GPS chosen as the speed source, or
/// the speed sensor dropping out mid-ride.
@MainActor
@Observable
final class LocationService: NSObject {
    enum Permission: Equatable {
        case unknown, denied, allowed
    }

    private(set) var permission: Permission = .unknown
    private(set) var isTracking = false
    /// Accuracy of the latest fix in metres.
    private(set) var accuracy: Double?
    private(set) var lastFixAt: Date?

    /// Receives every fix.
    @ObservationIgnored var onFix: (@MainActor (GPSFix) -> Void)?

    private let manager = CLLocationManager()
    @ObservationIgnored private var wantsTracking = false

    override init() {
        super.init()
        manager.delegate = self
        manager.activityType = .fitness
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = kCLDistanceFilterNone
        manager.pausesLocationUpdatesAutomatically = false
        permission = Self.mapPermission(manager.authorizationStatus)
    }

    /// Asked to run (it may still be waiting for permission).
    var isRequested: Bool { wantsTracking }

    func start() {
        wantsTracking = true
        if DemoMode.isOn {
            startDemo()
            return
        }
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()  // tracking begins once allowed
        case .authorizedWhenInUse, .authorizedAlways:
            begin()
        default:
            permission = .denied
        }
    }

    func stop() {
        wantsTracking = false
        guard isTracking else { return }
        isTracking = false
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        lastFixAt = nil
    }

    /// Back in the foreground: reads the permission again, and restarts updates
    /// that were asked for from the background, where iOS may not begin them.
    func ensureRunning() {
        permission = Self.mapPermission(manager.authorizationStatus)
        guard wantsTracking, permission == .allowed, !DemoMode.isOn else { return }
        if let lastFixAt, Date().timeIntervalSince(lastFixAt) < 10 { return }
        isTracking = false
        begin()
    }

    /// Demo mode (simulator screenshots): GPS looks on; fixes come from DemoMode.
    private func startDemo() {
        isTracking = true
        accuracy = 4
        lastFixAt = Date()
    }

    private func begin() {
        guard !isTracking else { return }
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        manager.startUpdatingLocation()
        isTracking = true
    }

    private static func mapPermission(_ status: CLAuthorizationStatus) -> Permission {
        switch status {
        case .authorizedWhenInUse, .authorizedAlways: return .allowed
        case .denied, .restricted: return .denied
        default: return .unknown
        }
    }
}

extension LocationService: @preconcurrency CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        permission = Self.mapPermission(manager.authorizationStatus)
        if wantsTracking, permission == .allowed {
            begin()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        for location in locations {
            accuracy = location.horizontalAccuracy
            lastFixAt = location.timestamp
            onFix?(GPSFix(
                time: location.timestamp,
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude,
                horizontalAccuracy: location.horizontalAccuracy,
                speed: location.speed
            ))
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        log.error("Location error: \(error.localizedDescription, privacy: .public)")
        if (error as? CLError)?.code == .denied {
            permission = .denied
            stop()
        }
    }
}
