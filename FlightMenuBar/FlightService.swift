import Foundation
import CoreLocation

// MARK: - Public types

struct FlightResult {
    let arrivalDate: Date
    let scheduledArrival: Date?
    let arrivalAirportName: String
    let departureAirportName: String
    let flightStatus: String
    let departureCoordinate: CLLocationCoordinate2D?
    let arrivalCoordinate: CLLocationCoordinate2D?
    let callSign: String?
    let arrivalIATACode: String?
    let arrivalTerminal: String?
    // False when the API only has the published schedule (no revised/actual
    // times and no live status) — the arrival time can't confirm "on time".
    let hasLiveData: Bool
}

struct FlightPosition {
    let latitude: Double
    let longitude: Double
    let heading: Double   // degrees, 0 = North, 90 = East
    let altitude: Double? // metres (geo altitude)
    let onGround: Bool
}

enum FlightServiceError: LocalizedError {
    case flightNotFound
    case noArrivalTime
    case networkError(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .flightNotFound:
            return "Flight not found. Check the number and try again."
        case .noArrivalTime:
            return "No arrival time available for this flight yet."
        case .networkError(let msg):
            return "Network error: \(msg)"
        case .invalidResponse:
            return "Received unexpected data from the server."
        }
    }
}

// MARK: - AeroDataBox response models (private)

private struct FlightResponse: Codable {
    let departure: FlightEndpoint?
    let arrival: FlightEndpoint?
    let status: String?
    let number: String?
    let callSign: String?
}

private struct FlightEndpoint: Codable {
    let airport: AirportInfo?
    let scheduledTime: FlightTime?
    let revisedTime: FlightTime?
    let predictedTime: FlightTime?
    let actualTime: FlightTime?
    let runwayTime: FlightTime?
    let terminal: String?
}

private struct AirportInfo: Codable {
    let name: String?
    let iata: String?
    let icao: String?
    let shortName: String?
    let location: AirportLocation?
}

private struct AirportLocation: Codable {
    let lat: Double
    let lon: Double
}

private struct FlightTime: Codable {
    let utc: String?
    let local: String?
}

// MARK: - AeroAPI response models (private)

private struct AeroAPIResponse: Codable {
    let flights: [AeroAPIFlight]?
}

private struct AeroAPIFlight: Codable {
    let status: String?
    let cancelled: Bool?
    let diverted: Bool?
    let scheduledOut: String?
    let scheduledIn: String?
    let estimatedIn: String?
    let actualIn: String?
    let terminalDestination: String?

    enum CodingKeys: String, CodingKey {
        case status, cancelled, diverted
        case scheduledOut = "scheduled_out"
        case scheduledIn  = "scheduled_in"
        case estimatedIn  = "estimated_in"
        case actualIn     = "actual_in"
        case terminalDestination = "terminal_destination"
    }
}

// Live overlay applied on top of the AeroDataBox result
private struct AeroAPILive {
    let arrivalDate: Date
    let scheduledArrival: Date?
    let status: String
    let terminal: String?
}

// MARK: - Airport coordinate fallback

private let knownAirportCoordinates: [String: (Double, Double)] = [
    "ATL": (33.6407, -84.4277), "AUS": (30.1975, -97.6664), "BNA": (36.1245, -86.6782),
    "BOS": (42.3656, -71.0096), "BWI": (39.1754, -76.6682), "CLT": (35.2140, -80.9431),
    "DAL": (32.8481, -96.8517), "DCA": (38.8512, -77.0402), "DEN": (39.8561, -104.6737),
    "DFW": (32.8998, -97.0403), "DTW": (42.2162, -83.3554), "EWR": (40.6925, -74.1687),
    "FLL": (26.0726, -80.1527), "HNL": (21.3245, -157.9251), "HOU": (29.6454, -95.2789),
    "IAD": (38.9531, -77.4565), "IAH": (29.9902, -95.3368), "JFK": (40.6413, -73.7781),
    "LAS": (36.0840, -115.1537), "LAX": (33.9425, -118.4081), "LGA": (40.7773, -73.8726),
    "MCO": (28.4312, -81.3081), "MDW": (41.7868, -87.7522), "MIA": (25.7959, -80.2870),
    "MSP": (44.8848, -93.2223), "MSY": (29.9934, -90.2580), "OAK": (37.7213, -122.2208),
    "ORD": (41.9742, -87.9073), "PDX": (45.5898, -122.5951), "PHL": (39.8744, -75.2424),
    "PHX": (33.4373, -112.0078), "RDU": (35.8801, -78.7880), "SAN": (32.7338, -117.1933),
    "SEA": (47.4502, -122.3088), "SFO": (37.6213, -122.3790), "SJC": (37.3626, -121.9290),
    "SLC": (40.7899, -111.9791), "STL": (38.7487, -90.3700), "TPA": (27.9755, -82.5332),
]

// MARK: - FlightService

struct FlightService {
    static let shared = FlightService()
    private init() {}

    // AeroDataBox uses "2024-01-15 18:00Z" (space separator, no seconds)
    private func parseDate(_ string: String) -> Date? {
        for format in ["yyyy-MM-dd HH:mmX", "yyyy-MM-dd HH:mm:ssX",
                       "yyyy-MM-dd'T'HH:mmX", "yyyy-MM-dd'T'HH:mm:ssX"] {
            let f = DateFormatter()
            f.dateFormat = format
            f.locale = Locale(identifier: "en_US_POSIX")
            if let d = f.date(from: string) { return d }
        }
        return nil
    }

    // MARK: AeroDataBox — fetch flight details

    func fetchFlight(flightNumber: String) async throws -> FlightResult {
        let normalized = flightNumber.trimmingCharacters(in: .whitespaces).uppercased()
        guard !normalized.isEmpty else { throw FlightServiceError.flightNotFound }

        let encoded = normalized.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? normalized
        let urlString = "\(Config.flightAPIBaseURL)/\(encoded)?withAircraftImage=false&withLocation=false"
        guard let url = URL(string: urlString) else { throw FlightServiceError.invalidResponse }

        var request = URLRequest(url: url)
        request.addValue(Config.rapidAPIKey,  forHTTPHeaderField: "X-RapidAPI-Key")
        request.addValue(Config.rapidAPIHost, forHTTPHeaderField: "X-RapidAPI-Host")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else { throw FlightServiceError.invalidResponse }
        switch http.statusCode {
        case 200:        break
        case 401, 403:   throw FlightServiceError.networkError("Invalid API key.")
        case 404:        throw FlightServiceError.flightNotFound
        case 429:        throw FlightServiceError.networkError("Rate limit hit. Try again in a moment.")
        default:         throw FlightServiceError.networkError("Server error \(http.statusCode).")
        }

        let flights = try JSONDecoder().decode([FlightResponse].self, from: data)
        guard !flights.isEmpty else { throw FlightServiceError.flightNotFound }

        let best = pickBestFlight(from: flights)
        guard let arrivalDate = resolveDate(from: best.arrival) else {
            throw FlightServiceError.noArrivalTime
        }

        let arrivalName = best.arrival?.airport?.shortName
            ?? best.arrival?.airport?.name
            ?? best.arrival?.airport?.iata
            ?? "Unknown"
        let departureName = best.departure?.airport?.shortName
            ?? best.departure?.airport?.name
            ?? best.departure?.airport?.iata
            ?? "Unknown"

        let deptCoord = await resolveCoordinate(
            location: best.departure?.airport?.location,
            iata: best.departure?.airport?.iata,
            name: best.departure?.airport?.name
        )
        let arrCoord = await resolveCoordinate(
            location: best.arrival?.airport?.location,
            iata: best.arrival?.airport?.iata,
            name: best.arrival?.airport?.name
        )

        let scheduledArrival: Date? = best.arrival?.scheduledTime?.utc.flatMap { parseDate($0) }

        let liveStatuses: Set<String> = ["enroute", "en route", "departed", "boarding",
                                         "gateclosed", "delayed", "approaching",
                                         "landed", "arrived", "canceled", "cancelled", "diverted"]
        let hasLiveTime = [best.arrival?.actualTime, best.arrival?.runwayTime,
                           best.arrival?.revisedTime, best.arrival?.predictedTime]
            .contains { $0?.utc != nil }
        var hasLiveData = hasLiveTime || liveStatuses.contains((best.status ?? "").lowercased())

        // AeroDataBox often has schedule-only records; AeroAPI (when configured)
        // supplies the live estimated arrival and real status on top of it.
        var resolvedArrival   = arrivalDate
        var resolvedScheduled = scheduledArrival
        var resolvedStatus    = best.status ?? "Unknown"
        var resolvedTerminal  = best.arrival?.terminal
        if let live = await fetchAeroAPILive(flightNumber: normalized) {
            resolvedArrival   = live.arrivalDate
            resolvedScheduled = live.scheduledArrival ?? resolvedScheduled
            resolvedStatus    = live.status
            resolvedTerminal  = live.terminal ?? resolvedTerminal
            hasLiveData       = true
        }

        return FlightResult(
            arrivalDate: resolvedArrival,
            scheduledArrival: resolvedScheduled,
            arrivalAirportName: arrivalName,
            departureAirportName: departureName,
            flightStatus: resolvedStatus,
            departureCoordinate: deptCoord,
            arrivalCoordinate: arrCoord,
            callSign: best.callSign,
            arrivalIATACode: best.arrival?.airport?.iata,
            arrivalTerminal: resolvedTerminal,
            hasLiveData: hasLiveData
        )
    }

    // MARK: AeroAPI — live delay/status overlay (best-effort, never throws)

    private func fetchAeroAPILive(flightNumber: String) async -> AeroAPILive? {
        guard !Config.aeroAPIKey.isEmpty,
              let encoded = flightNumber.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "\(Config.aeroAPIBaseURL)/flights/\(encoded)")
        else { return nil }

        var request = URLRequest(url: url)
        request.addValue(Config.aeroAPIKey, forHTTPHeaderField: "x-apikey")
        request.timeoutInterval = 15

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let decoded = try? JSONDecoder().decode(AeroAPIResponse.self, from: data),
              let flights = decoded.flights, !flights.isEmpty
        else { return nil }

        // AeroAPI returns ~2 weeks of history plus upcoming legs; pick the one
        // whose scheduled departure is closest to now (same rule as AeroDataBox).
        let iso = ISO8601DateFormatter()
        let now = Date()
        let best = flights.min { a, b in
            let da = a.scheduledOut.flatMap { iso.date(from: $0) }.map { abs($0.timeIntervalSince(now)) } ?? .infinity
            let db = b.scheduledOut.flatMap { iso.date(from: $0) }.map { abs($0.timeIntervalSince(now)) } ?? .infinity
            return da < db
        }
        guard let flight = best,
              let arrival = [flight.actualIn, flight.estimatedIn, flight.scheduledIn]
                  .compactMap({ $0.flatMap { iso.date(from: $0) } }).first
        else { return nil }

        return AeroAPILive(
            arrivalDate: arrival,
            scheduledArrival: flight.scheduledIn.flatMap { iso.date(from: $0) },
            status: normalizeAeroAPIStatus(flight),
            terminal: flight.terminalDestination
        )
    }

    // Resolve airport coordinate: AeroDataBox location → known IATA dict → geocode by name
    private func resolveCoordinate(location: AirportLocation?, iata: String?, name: String?) async -> CLLocationCoordinate2D? {
        if let loc = location {
            return CLLocationCoordinate2D(latitude: loc.lat, longitude: loc.lon)
        }
        if let iata, let known = knownAirportCoordinates[iata.uppercased()] {
            return CLLocationCoordinate2D(latitude: known.0, longitude: known.1)
        }
        guard let query = iata.map({ "\($0) Airport" }) ?? name.map({ "\($0) Airport" }) else { return nil }
        return await withCheckedContinuation { cont in
            CLGeocoder().geocodeAddressString(query) { placemarks, _ in
                cont.resume(returning: placemarks?.first?.location?.coordinate)
            }
        }
    }

    // Map AeroAPI statuses ("En Route / Delayed", "Arrived / Gate Arrival", …)
    // onto the vocabulary the UI already understands.
    private func normalizeAeroAPIStatus(_ flight: AeroAPIFlight) -> String {
        if flight.cancelled == true { return "Cancelled" }
        if flight.diverted  == true { return "Diverted" }
        let s = (flight.status ?? "").lowercased()
        if s.contains("arrived") || s.contains("landed") { return "Landed" }
        if s.contains("delayed")   { return "Delayed" }
        if s.contains("en route")  { return "En Route" }
        if s.contains("taxiing") || s.contains("departed") { return "Departed" }
        if s.contains("scheduled") { return "Scheduled" }
        return flight.status ?? "Unknown"
    }

    // MARK: OpenSky — fetch real-time position (best-effort, never throws)

    func fetchPosition(callSign: String) async -> FlightPosition? {
        let trimmed = callSign.trimmingCharacters(in: .whitespaces).uppercased()
        guard !trimmed.isEmpty,
              let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://opensky-network.org/api/states/all?callsign=\(encoded)")
        else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              http.statusCode == 200
        else { return nil }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let states = json["states"] as? [[Any?]],
              let state = states.first,
              state.count > 10,
              let lon = state[5] as? Double,
              let lat = state[6] as? Double
        else { return nil }

        return FlightPosition(
            latitude:  lat,
            longitude: lon,
            heading:   state[10] as? Double ?? 0,
            altitude:  state[13] as? Double,
            onGround:  state[8]  as? Bool   ?? false
        )
    }

    // MARK: Private helpers

    private func pickBestFlight(from flights: [FlightResponse]) -> FlightResponse {
        let now = Date()
        let scored: [(FlightResponse, TimeInterval)] = flights.compactMap { f in
            guard let utc = f.departure?.scheduledTime?.utc,
                  let date = parseDate(utc) else { return nil }
            return (f, abs(date.timeIntervalSince(now)))
        }
        return scored.min(by: { $0.1 < $1.1 })?.0 ?? flights[0]
    }

    // Priority: actual > runway > revised > predicted > scheduled
    private func resolveDate(from endpoint: FlightEndpoint?) -> Date? {
        guard let ep = endpoint else { return nil }
        for candidate in [ep.actualTime, ep.runwayTime, ep.revisedTime, ep.predictedTime, ep.scheduledTime] {
            if let utc = candidate?.utc, let date = parseDate(utc) { return date }
        }
        return nil
    }
}
