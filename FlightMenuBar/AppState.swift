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

    // Incremented by display timer to drive menu bar label re-renders (minute resolution)
    @Published private var tick: Int = 0

    private var callSign: String = ""
    private var displayTimer:       Timer?
    private var pollingTimer:       Timer?
    private var positionTimer:      Timer?
    private var batteryTimer:       Timer?
    private var leaveByTask:        Task<Void, Never>?  // Bark + Tesla nav at leave-by time
    private var arrivalBarkTask:    Task<Void, Never>?  // Bark at T-1h
    private var landedAutoStopTask: Task<Void, Never>?  // Auto-stop 15 min after landing
    private var retryTask:          Task<Void, Never>?

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
            scheduleArrivalBark(flightNumber: normalized, arrivalDate: result.arrivalDate,
                                airport: result.arrivalAirportName, terminal: result.arrivalTerminal)
            scheduleAutoStop(flightStatus: result.flightStatus, arrivalDate: result.arrivalDate)
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
        NotificationManager.shared.cancelNotification()
        NotificationManager.shared.resetImmediateDedup()
        leaveByTask?.cancel();        leaveByTask        = nil
        arrivalBarkTask?.cancel();    arrivalBarkTask    = nil
        landedAutoStopTask?.cancel(); landedAutoStopTask = nil
        retryTask?.cancel();          retryTask          = nil
        stopTimers()
    }

    func refreshFlight() async {
        guard isTracking, !flightNumber.isEmpty else { return }
        retryTask?.cancel()
        retryTask = nil
        do {
            let result = try await FlightService.shared.fetchFlight(flightNumber: flightNumber)
            arrivalDate          = result.arrivalDate
            arrivalAirport       = result.arrivalAirportName
            flightStatus         = result.flightStatus
            callSign             = result.callSign ?? callSign
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
            // Re-schedule Bark only if no task is running (avoids re-arming on every poll)
            if arrivalBarkTask == nil {
                scheduleArrivalBark(flightNumber: flightNumber, arrivalDate: result.arrivalDate,
                                    airport: result.arrivalAirportName, terminal: result.arrivalTerminal)
            }
            scheduleAutoStop(flightStatus: result.flightStatus, arrivalDate: result.arrivalDate)
            await refreshDriving()
        } catch {
            statusMessage = "Refresh failed — retrying in 5 min"
            retryTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 300 * 1_000_000_000)
                guard !Task.isCancelled else { return }
                await self?.refreshFlight()
            }
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
            // Bark fires at leave-by time minus the configured lead
            let leadMinutes = Config.leaveByLeadMinutes
            let notifyAt = arrival
                .addingTimeInterval(-TimeInterval(minutes * 60))
                .addingTimeInterval(-TimeInterval(leadMinutes * 60))
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

        // Refresh Tesla battery every 5 minutes while tracking
        let bat = Timer(timeInterval: 300, repeats: true) { _ in
            Task { await TeslaService.shared.refreshBatteryLevel() }
        }
        RunLoop.main.add(bat, forMode: .common)
        batteryTimer = bat
    }

    private func stopTimers() {
        displayTimer?.invalidate();  displayTimer  = nil
        pollingTimer?.invalidate();  pollingTimer  = nil
        positionTimer?.invalidate(); positionTimer = nil
        batteryTimer?.invalidate();  batteryTimer  = nil
    }

    // MARK: - Scheduled helpers

    /// Schedules a Bark push exactly once at T-1h before arrival.
    /// Called on tracking start; NOT re-called on every poll (checked at call site).
    private func scheduleArrivalBark(flightNumber: String, arrivalDate: Date, airport: String, terminal: String?) {
        arrivalBarkTask?.cancel()
        arrivalBarkTask = nil

        let remaining = arrivalDate.timeIntervalSinceNow
        // Only schedule if there's more than 1 hour left; otherwise the immediate
        // Mac notification already fired and scheduleArrivalNotification handles it.
        guard remaining > 3600 else { return }

        let delay = remaining - 3600
        var barkBody = "\(flightNumber) lands at \(airport) in 1 hour (\(arrivalDate.formatted(date: .omitted, time: .shortened)))."
        if let term = terminal { barkBody += " Terminal \(term)." }

        arrivalBarkTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, self?.isTracking == true else { return }
            await BarkService.send(title: "✈ Flight arriving in 1 hour", body: barkBody)
            // Clear the task reference so refreshFlight can re-arm if the arrival time shifts
            await MainActor.run { self?.arrivalBarkTask = nil }
        }
    }

    /// Detects "Landed" / "Arrived" status and schedules an auto-stop 15 min later.
    private func scheduleAutoStop(flightStatus: String, arrivalDate: Date) {
        let isLanded = ["landed", "arrived"].contains(flightStatus.lowercased())
        guard isLanded else { return }
        guard landedAutoStopTask == nil else { return }  // already scheduled

        // Stop either 15 min after scheduled arrival or 15 min from now, whichever is later.
        let autoStopAt = max(Date().addingTimeInterval(15 * 60),
                             arrivalDate.addingTimeInterval(15 * 60))
        let delay = autoStopAt.timeIntervalSinceNow

        statusMessage = "Landed — auto-stopping tracking in 15 min"
        landedAutoStopTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.stopTracking()
        }
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
