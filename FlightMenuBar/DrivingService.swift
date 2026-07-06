import Foundation
import CoreLocation
import MapKit

struct DrivingService {
    static let shared = DrivingService()
    private init() {}

    // Cached geocode result. Cleared when the user changes their home address.
    private static var cachedHome: CLLocationCoordinate2D?

    /// Clears the cached home coordinate so the next fetch re-geocodes.
    static func clearCache() {
        cachedHome = nil
    }

    private static let terminalCoordinates: [String: [String: CLLocationCoordinate2D]] = [
        "JFK": [
            "1": CLLocationCoordinate2D(latitude: 40.6413, longitude: -73.7769),
            "2": CLLocationCoordinate2D(latitude: 40.6397, longitude: -73.7822),
            "4": CLLocationCoordinate2D(latitude: 40.6441, longitude: -73.7826),
            "5": CLLocationCoordinate2D(latitude: 40.6388, longitude: -73.7901),
            "7": CLLocationCoordinate2D(latitude: 40.6379, longitude: -73.7917),
            "8": CLLocationCoordinate2D(latitude: 40.6379, longitude: -73.7867),
        ],
        "LGA": [
            "A": CLLocationCoordinate2D(latitude: 40.7762, longitude: -73.8726),
            "B": CLLocationCoordinate2D(latitude: 40.7772, longitude: -73.8740),
            "C": CLLocationCoordinate2D(latitude: 40.7769, longitude: -73.8716),
        ],
        "EWR": [
            "A": CLLocationCoordinate2D(latitude: 40.6895, longitude: -74.1747),
            "B": CLLocationCoordinate2D(latitude: 40.6926, longitude: -74.1736),
            "C": CLLocationCoordinate2D(latitude: 40.6942, longitude: -74.1718),
        ],
    ]

    // Returns estimated driving minutes, or nil on any failure.
    func fetchDrivingTime(
        to airportCoordinate: CLLocationCoordinate2D,
        iataCode: String?,
        terminal: String?,
        arrivalDate: Date,
        previousDriveMinutes: Int? = nil
    ) async -> Int? {
        guard let origin = await resolveHome() else { return nil }
        let destination = resolveDestination(
            airportCoordinate: airportCoordinate,
            iataCode: iataCode,
            terminal: terminal
        )

        let request = MKDirections.Request()
        request.source        = MKMapItem(placemark: MKPlacemark(coordinate: origin))
        request.destination   = MKMapItem(placemark: MKPlacemark(coordinate: destination))
        request.transportType = .automobile
        // Use previously known drive time (or 2 h fallback) to set departure for traffic-aware routing
        let driveEstimate = TimeInterval((previousDriveMinutes ?? 120) * 60)
        request.departureDate = max(Date(), arrivalDate.addingTimeInterval(-driveEstimate))

        guard let response = try? await MKDirections(request: request).calculate() else { return nil }
        return response.routes
            .min(by: { $0.expectedTravelTime < $1.expectedTravelTime })
            .map { Int($0.expectedTravelTime / 60) }
    }

    private func resolveDestination(
        airportCoordinate: CLLocationCoordinate2D,
        iataCode: String?,
        terminal: String?
    ) -> CLLocationCoordinate2D {
        guard let iata = iataCode?.uppercased(),
              let term = terminal,
              let coord = Self.terminalCoordinates[iata]?[term]
        else { return airportCoordinate }
        return coord
    }

    private func resolveHome() async -> CLLocationCoordinate2D? {
        if let cached = Self.cachedHome { return cached }
        let address = Config.homeAddress   // reads UserDefaults or Secrets fallback
        return await withCheckedContinuation { continuation in
            CLGeocoder().geocodeAddressString(address) { placemarks, _ in
                let coord = placemarks?.first?.location?.coordinate
                Self.cachedHome = coord
                continuation.resume(returning: coord)
            }
        }
    }
}
