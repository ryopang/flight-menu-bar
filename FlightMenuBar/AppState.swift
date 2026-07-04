import Foundation
import CoreLocation
import Combine

@MainActor
class AppState: ObservableObject {
    @Published var flightNumber: String = ""
    @Published var arrivalDate: Date?
    @Published var arrivalAirport: String = ""
    @Published var departureAirport: String = ""
    @Published var flightStatus: String = ""
    @Published var statusMessage: String = "Enter a flight number to start tracking"
    @Published var isTracking: Bool = false
    @Published var isLoading: Bool = false

    // Map data
    @Published var departureCoordinate: CLLocationCoordinate2D?
    @Published var arrivalCoordinate: CLLocationCoordinate2D?
    @Published var currentPosition: FlightPosition?

    // Terminal info (surfaced only for NY/NJ airports in the UI)
    @Published var arrivalIATACode: String = ""
    @Published var arrivalTerminal: String?

    // Delay: positive = late, negative = early, nil = unknown or within ±5 min threshold
    @Published var delayMinutes: Int?
    @Published var scheduledArrivalDate: Date?
    // False when the API only has published-schedule data for this flight
    @Published var hasLiveData: Bool = false

    // Driving: nil until first MKDirections result
    @Published var drivingMinutes: Int?

    // Incremented by display timer to drive countdown re-renders
    @Published private var tick: Int = 0

    private var callSign: String = ""
    private var displayTimer:  Timer?
    private var pollingTimer:  Timer?
    private var positionTimer: Timer?
    private var leaveByTask:   Task<Void, Never>?

    init() {
        flightNumber = UserDefaults.standard.string(forKey: Config.lastFlightNumberKey) ?? ""
    }

    // MARK: - Computed display properties

    var menuBarLabel: String {
        _ = tick
        guard isTracking, let arrival = arrivalDate else { return "✈" }
        let remaining = arrival.timeIntervalSinceNow
        guard remaining > 0 else { return "✈ Landed" }
        let h = Int(remaining) / 3600
        let m = (Int(remaining) % 3600) / 60
        if h > 0 { return "✈ \(h)h \(m)m" }
        return "✈ \(m)m"
    }

    var countdownString: String {
        _ = tick
        guard let arrival = arrivalDate else { return "" }
        let remaining = arrival.timeIntervalSinceNow
        guard remaining > 0 else { return "Arrived" }
        let h = Int(remaining) / 3600
        let m = (Int(remaining) % 3600) / 60
        let s = Int(remaining) % 60
        if h > 0 { return "\(h)h \(m)m \(s)s" }
        return "\(m)m \(s)s"
    }

    var formattedArrivalTime: String {
        guard let arrival = arrivalDate else { return "" }
        return arrival.formatted(date: .abbreviated, time: .shortened)
    }

    // MARK: - Actions

    func startTracking(with number: String) async {
        let normalized = number.trimmingCharacters(in: .whitespaces).uppercased()
        guard !normalized.isEmpty else { return }

        flightNumber = normalized
        isLoading = true
        statusMessage = "Looking up \(normalized)…"
        UserDefaults.standard.set(normalized, forKey: Config.lastFlightNumberKey)

        do {
            let result = try await FlightService.shared.fetchFlight(flightNumber: normalized)
            arrivalDate          = result.arrivalDate
            arrivalAirport       = result.arrivalAirportName
            departureAirport     = result.departureAirportName
            flightStatus         = result.flightStatus
            departureCoordinate  = result.departureCoordinate
            arrivalCoordinate    = result.arrivalCoordinate
            callSign             = result.callSign ?? ""
            arrivalIATACode      = result.arrivalIATACode ?? ""
            arrivalTerminal      = result.arrivalTerminal
            scheduledArrivalDate = result.scheduledArrival
            delayMinutes         = computeDelay(scheduled: result.scheduledArrival, resolved: result.arrivalDate)
            hasLiveData          = result.hasLiveData
            isTracking           = true
            statusMessage        = "Status: \(friendlyStatus(result.flightStatus))"

            NotificationManager.shared.scheduleArrivalNotification(
                flightNumber: normalized,
                arrivalDate: result.arrivalDate,
                airport: result.arrivalAirportName,
                terminal: result.arrivalTerminal
            )
            startTimers()
            // Fetch position and driving time immediately on first open
            Task { await refreshPosition() }
            Task { await refreshDriving() }
        } catch {
            statusMessage = error.localizedDescription
        }

        isLoading = false
    }

    func stopTracking() {
        isTracking           = false
        arrivalDate          = nil
        arrivalAirport       = ""
        departureAirport     = ""
        flightStatus         = ""
        departureCoordinate  = nil
        arrivalCoordinate    = nil
        currentPosition      = nil
        callSign             = ""
        arrivalIATACode      = ""
        arrivalTerminal      = nil
        scheduledArrivalDate = nil
        delayMinutes         = nil
        hasLiveData          = false
        drivingMinutes       = nil
        statusMessage        = "Enter a flight number to start tracking"
        NotificationManager.shared.cancelLeaveByNotification()
        leaveByTask?.cancel()
        leaveByTask = nil
        stopTimers()
        NotificationManager.shared.cancelNotification()
    }

    func refreshFlight() async {
        guard isTracking, !flightNumber.isEmpty else { return }
        do {
            let result = try await FlightService.shared.fetchFlight(flightNumber: flightNumber)
            arrivalDate          = result.arrivalDate
            arrivalAirport       = result.arrivalAirportName
            flightStatus         = result.flightStatus
            callSign             = result.callSign ?? callSign  // keep existing if missing
            arrivalTerminal      = result.arrivalTerminal
            scheduledArrivalDate = result.scheduledArrival
            delayMinutes         = computeDelay(scheduled: result.scheduledArrival, resolved: result.arrivalDate)
            hasLiveData          = result.hasLiveData
            statusMessage        = "Status: \(friendlyStatus(result.flightStatus))"
            NotificationManager.shared.scheduleArrivalNotification(
                flightNumber: flightNumber,
                arrivalDate: result.arrivalDate,
                airport: result.arrivalAirportName,
                terminal: result.arrivalTerminal
            )
            await refreshDriving()
        } catch {
            statusMessage = "Refresh failed — retrying in 5m"
        }
    }

    func refreshDriving() async {
        guard isTracking, let arrival = arrivalDate, let arrCoord = arrivalCoordinate else { return }
        let minutes = await DrivingService.shared.fetchDrivingTime(
            to: arrCoord,
            iataCode: arrivalIATACode.isEmpty ? nil : arrivalIATACode,
            terminal: arrivalTerminal,
            arrivalDate: arrival,
            previousDriveMinutes: drivingMinutes
        )
        drivingMinutes = minutes
        leaveByTask?.cancel()
        leaveByTask = nil

        if let minutes {
            NotificationManager.shared.scheduleLeaveByNotification(
                airport: arrivalAirport,
                terminal: arrivalTerminal,
                arrivalDate: arrival,
                drivingMinutes: minutes
            )
            // Bark fires at the same time as the Mac notification (leaveByDate - 15 min)
            let notifyAt = arrival
                .addingTimeInterval(-TimeInterval(minutes * 60))
                .addingTimeInterval(-15 * 60)
            let delay = notifyAt.timeIntervalSinceNow
            if delay > 0 {
                let airport  = arrivalAirport
                let terminal = arrivalTerminal
                let body = NotificationManager.shared.leaveByBarkBody(
                    airport: airport, terminal: terminal,
                    arrivalDate: arrival, drivingMinutes: minutes
                )
                leaveByTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    guard !Task.isCancelled, self?.isTracking == true else { return }
                    await BarkService.send(title: "🚗 Time to leave for \(airport)", body: body)
                    await TeslaService.shared.sendNavigation(airport: airport, terminal: terminal)
                }
            }
        } else {
            NotificationManager.shared.cancelLeaveByNotification()
        }
    }

    func refreshPosition() async {
        guard isTracking, !callSign.isEmpty else { return }
        let pos = await FlightService.shared.fetchPosition(callSign: callSign)
        currentPosition = pos
    }

    // MARK: - Timers

    private func startTimers() {
        stopTimers()

        let dt = Timer(timeInterval: Config.displayTimerInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick += 1 }
        }
        RunLoop.main.add(dt, forMode: .common)
        displayTimer = dt

        let pt = Timer(timeInterval: Config.pollingTimerInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.refreshFlight() }
        }
        RunLoop.main.add(pt, forMode: .common)
        pollingTimer = pt

        let pos = Timer(timeInterval: Config.positionTimerInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.refreshPosition() }
        }
        RunLoop.main.add(pos, forMode: .common)
        positionTimer = pos
    }

    private func stopTimers() {
        displayTimer?.invalidate();  displayTimer  = nil
        pollingTimer?.invalidate();  pollingTimer  = nil
        positionTimer?.invalidate(); positionTimer = nil
    }

    // MARK: - Helpers

    private func computeDelay(scheduled: Date?, resolved: Date?) -> Int? {
        guard let s = scheduled, let r = resolved else { return nil }
        let diff = Int(r.timeIntervalSince(s) / 60)
        return abs(diff) < 5 ? nil : diff
    }

    private func friendlyStatus(_ raw: String) -> String {
        switch raw.lowercased() {
        case "enroute", "en route": return "En Route"
        case "scheduled":           return "Scheduled"
        case "expected":            return "Expected"
        case "departed":            return "Departed"
        case "boarding":            return "Boarding"
        case "gateclosed":          return "Gate Closed"
        case "delayed":             return "Delayed"
        case "approaching":         return "Approaching"
        case "landed", "arrived":   return "Landed"
        case "canceled", "cancelled": return "Cancelled"
        case "diverted":            return "Diverted"
        default:                    return raw.isEmpty ? "Unknown" : raw
        }
    }
}
