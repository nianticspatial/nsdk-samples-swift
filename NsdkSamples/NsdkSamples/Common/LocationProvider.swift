// Copyright 2026 Niantic Spatial.

import CoreLocation
import Foundation

final class LocationProvider: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var completion: ((Double, Double) -> Void)?

    func requestLocation(_ completion: @escaping (Double, Double) -> Void) {
        self.completion = completion
        manager.delegate = self
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            // Note: on iOS 14+, if the user grants "Approximate Location", the OS silently
            // caps accuracy to ~1 km regardless of this setting.
            manager.desiredAccuracy = kCLLocationAccuracyBest
            manager.requestLocation()
        default:
            break
        }
    }

    /// Cancels any pending location request and detaches from the manager so a late
    /// callback (e.g. when the GPS service finally boots after the view is gone) can't
    /// fire its completion into torn-down view state. Idempotent.
    func invalidate() {
        completion = nil
        manager.delegate = nil
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard completion != nil else { return }
        if manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways {
            manager.desiredAccuracy = kCLLocationAccuracyBest
            manager.requestLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last, let completion else { return }
        self.completion = nil
        completion(location.coordinate.latitude, location.coordinate.longitude)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("[LocationProvider] Location error: \(error.localizedDescription)")
    }
}
