import Foundation
import UserNotifications

// NotificationManager: handles Mac local notifications ONLY.
// Bark (iPhone) pushes are deliberately NOT sent here — they are
// scheduled by AppState as Tasks so they fire at the right time
// (T-1h for arrival, T-leadMinutes for leave-by), not on every poll.

class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()
    private override init() {}

    private let identifier        = "com.personal.FlightMenuBar.arrival"
    private let leaveByIdentifier = "com.personal.FlightMenuBar.leaveBy"

    // Polling reschedules every 20 min; without this, the immediate
    // notification would re-fire on every poll in the final hour.
    private var lastImmediateKey: String?

    func resetImmediateDedup() {
        lastImmediateKey = nil
    }

    // MARK: - Authorization

    func requestAuthorization() {
        // Must set delegate before requesting authorization so that
        // notifications show as banners when the app is "running"
        // (macOS menu bar apps are always running — LSUIElement = true).
        UNUserNotificationCenter.current().delegate = self

        UNUserNotificationCenter.current().getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                UNUserNotificationCenter.current().requestAuthorization(
                    options: [.alert, .sound, .badge]
                ) { granted, error in
                    if let error { print("[Notifications] Auth error: \(error)") }
                    print("[Notifications] Authorization granted: \(granted)")
                }
            case .denied:
                print("[Notifications] Denied — user should enable in System Settings > Notifications > FlightMenuBar")
            default:
                break
            }
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    // Called when a notification is delivered while the app is running.
    // Without this, macOS silently suppresses banners for active apps.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    // MARK: - Arrival notification (Mac only)

    func scheduleArrivalNotification(
        flightNumber: String,
        arrivalDate: Date,
        airport: String,
        terminal: String?
    ) {
        cancelNotification()

        let now       = Date()
        let remaining = arrivalDate.timeIntervalSince(now)
        guard remaining > 0 else { return }

        let content   = UNMutableNotificationContent()
        content.sound = .default
        let notifyAt  = arrivalDate.addingTimeInterval(-3600)
        let arrivalStr = arrivalDate.formatted(date: .omitted, time: .shortened)

        if notifyAt <= now {
            // Within 1 hour of arrival — fire immediately (with dedup)
            let key = "\(flightNumber)-\(Int(arrivalDate.timeIntervalSince1970 / 60))"
            guard key != lastImmediateKey else { return }
            lastImmediateKey = key

            let mins = max(1, Int(remaining / 60))
            content.title = "✈ \(flightNumber) — Arriving Soon"
            content.body  = "Your flight arrives in approximately \(mins) minute\(mins == 1 ? "" : "s")."
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
            schedule(content: content, trigger: trigger)

        } else {
            // More than 1 hour away — schedule at T-1h
            content.title = "✈ \(flightNumber) — 1 Hour to Arrival"
            content.body  = "Your flight arrives at \(arrivalStr). Time to prepare!"
            let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: notifyAt)
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            schedule(content: content, trigger: trigger)
            // NOTE: Bark is NOT sent here. AppState.arrivalBarkTask handles
            // the T-1h Bark so it fires exactly once, not on every poll.
        }
    }

    func cancelNotification() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [identifier])
    }

    // MARK: - Leave-by notification (Mac only)

    func scheduleLeaveByNotification(
        airport: String,
        terminal: String?,
        arrivalDate: Date,
        drivingMinutes: Int
    ) {
        cancelLeaveByNotification()

        let leaveByDate = arrivalDate.addingTimeInterval(-TimeInterval(drivingMinutes * 60))
        let leadMinutes = Config.leaveByLeadMinutes
        let notifyAt    = leaveByDate.addingTimeInterval(-TimeInterval(leadMinutes * 60))
        guard notifyAt > Date() else { return }

        let content   = UNMutableNotificationContent()
        content.sound = .default
        content.title = "Time to head to \(airport)"
        let arrivalStr = arrivalDate.formatted(date: .omitted, time: .shortened)

        if let term = terminal {
            content.body = "Leave now to reach Terminal \(term) by \(arrivalStr). Drive is ~\(drivingMinutes) min."
        } else {
            content.body = "Leave now to reach \(airport) by \(arrivalStr). Drive is ~\(drivingMinutes) min."
        }

        let comps   = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: notifyAt)
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: leaveByIdentifier, content: content, trigger: trigger)
        )
    }

    /// The body string used for the Bark leave-by push (matches the Mac notification body).
    func leaveByBarkBody(airport: String, terminal: String?, arrivalDate: Date, drivingMinutes: Int) -> String {
        let arrivalStr = arrivalDate.formatted(date: .omitted, time: .shortened)
        if let term = terminal {
            return "Leave now to reach Terminal \(term) by \(arrivalStr). Drive is ~\(drivingMinutes) min."
        } else {
            return "Leave now to reach \(airport) by \(arrivalStr). Drive is ~\(drivingMinutes) min."
        }
    }

    func cancelLeaveByNotification() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [leaveByIdentifier])
    }

    // MARK: - Private

    private func schedule(content: UNMutableNotificationContent, trigger: UNNotificationTrigger) {
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        )
    }
}
