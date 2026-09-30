import CoreLocation
import Foundation
import MapKit

@MainActor
final class NearbyStoreMatcher: NSObject, CLLocationManagerDelegate {
    static let matchRadius: CLLocationDistance = 550
    private static let maxAccuracy: CLLocationDistance = 200

    var nearbyShop: Shop?
    var onNearbyShopChange: ((Shop?) -> Void)?
    var onResolvedCoordinate: ((UUID, Double, Double) -> Void)?

    private let manager = CLLocationManager()
    private var shops: [Shop] = []
    private var isRunning = false
    private var lastLocation: CLLocation?
    private var isSearching = false
    private var failedQueries: Set<String> = []

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = 80
        manager.pausesLocationUpdatesAutomatically = true
    }

    func start(shops: [Shop]) {
        self.shops = shops
        guard !shops.isEmpty else {
            stop()
            return
        }
        isRunning = true
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            manager.startUpdatingLocation()
            if let lastLocation {
                Task { await match(userLocation: lastLocation) }
            }
        default:
            publish(nil)
        }
    }

    func updateShops(_ shops: [Shop]) {
        self.shops = shops
        if shops.isEmpty {
            stop()
            return
        }
        if isRunning, let lastLocation {
            Task { await match(userLocation: lastLocation) }
        } else if isRunning {
            start(shops: shops)
        }
    }

    func applyResolvedShop(_ shop: Shop) {
        if let index = shops.firstIndex(where: { $0.id == shop.id }) {
            shops[index] = shop
        }
    }

    func stop() {
        isRunning = false
        manager.stopUpdatingLocation()
        lastLocation = nil
        publish(nil)
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            guard isRunning else { return }
            switch manager.authorizationStatus {
            case .authorizedAlways, .authorizedWhenInUse:
                manager.startUpdatingLocation()
            default:
                self.manager.stopUpdatingLocation()
                publish(nil)
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor in
            await match(userLocation: location)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            if nearbyShop != nil {
                publish(nil)
            }
        }
    }

    private func match(userLocation: CLLocation) async {
        lastLocation = userLocation
        guard isRunning, !shops.isEmpty else {
            publish(nil)
            return
        }
        guard userLocation.horizontalAccuracy >= 0,
              userLocation.horizontalAccuracy <= Self.maxAccuracy
        else { return }
        guard !isSearching else { return }
        isSearching = true
        defer { isSearching = false }

        var bestShop: Shop?
        var bestDistance = Self.matchRadius
        for shop in shops {
            guard let coordinate = await coordinate(for: shop, near: userLocation) else { continue }
            let pin = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            let distance = userLocation.distance(from: pin)
            guard distance <= bestDistance else { continue }
            bestDistance = distance
            bestShop = shop
        }
        publish(bestShop)
    }

    private func coordinate(for shop: Shop, near userLocation: CLLocation) async -> CLLocationCoordinate2D? {
        if let latitude = shop.latitude, let longitude = shop.longitude {
            return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }
        let query = shop.mapQuery
        guard !query.isEmpty, !failedQueries.contains(query) else { return nil }
        guard let found = await search(query, near: userLocation) else {
            failedQueries.insert(query)
            return nil
        }
        onResolvedCoordinate?(shop.id, found.latitude, found.longitude)
        return found
    }

    private func search(_ query: String, near userLocation: CLLocation) async -> CLLocationCoordinate2D? {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.resultTypes = [.pointOfInterest, .address]
        request.region = MKCoordinateRegion(
            center: userLocation.coordinate,
            latitudinalMeters: 4_000,
            longitudinalMeters: 4_000
        )
        do {
            let response = try await MKLocalSearch(request: request).start()
            if let nearUser = response.mapItems
                .compactMap(\.placemark.location)
                .map({ (location: $0, distance: userLocation.distance(from: $0)) })
                .filter({ $0.distance <= 2_000 })
                .min(by: { $0.distance < $1.distance })
            {
                return nearUser.location.coordinate
            }
        } catch {
            // Fall through to address geocoding, which still works without a nearby POI.
        }

        do {
            let marks = try await CLGeocoder().geocodeAddressString(query)
            return marks.first?.location?.coordinate
        } catch {
            return nil
        }
    }

    private func publish(_ shop: Shop?) {
        let changed = nearbyShop?.id != shop?.id
        nearbyShop = shop
        if changed {
            onNearbyShopChange?(shop)
        }
    }
}
