@preconcurrency import CoreLocation
import Combine
import Foundation

@MainActor
final class LocationProvider: NSObject, ObservableObject, @MainActor CLLocationManagerDelegate {
    @Published private(set) var latest: CLLocation?
    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled else {
            latest = nil
            return
        }
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            manager.requestLocation()
        default:
            latest = nil
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if manager.authorizationStatus == .authorizedAlways
            || manager.authorizationStatus == .authorizedWhenInUse
        {
            manager.requestLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        latest = locations.last
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        latest = nil
    }
}
