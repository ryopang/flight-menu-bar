import Foundation
import UserNotifications

class NotificationManager {
    static let shared = NotificationManager()
    private init() {}

    private let identifier        = "com.personal.FlightMenuBar.arrival"
    private let leaveByIdentifier = "com.personal.FlightMenuBar.leaveBy"

    // Polling reschedules every 20 min; without this, the immediate "arriving
    // soon" notification + Bark push would re-fire on every poll in the final hour.
    private var lastImmediateKey: String?

    func resetImmediateDedup() {
        lastImmediateKey = nil
    }

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

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

        let content    = UNMutableNotificationContent()
        content.sound  = .default
        let notifyAt   = arrivalDate.addingTimeInterval(-3600)
        let arrivalStr = arrivalDate.formatted(date: .omitted, time: .shortened)

        if notifyAt <= now {
            // Key on flight + arrival minute: re-fires only if the arrival time actually changes
            let key = "\(flightNumber)-\(Int(arrivalDate.timeIntervalSince1970 / 60))"
            guard key != lastImmediateKey else { return }
            lastImmediateKey = key

            let mins = max(1, Int(remaining / 60))
            content.title = "✈ \(flightNumber) — Arriving Soon"
            content.body  = "Your flight arrives in approximately \(mins) minute\(mins == 1 ? "" : "s")."
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
            schedule(content: content, trigger: trigger)
            var barkBody = "\(flightNumber) lands at \(airport) in ~\(mins) min (\(arrivalStr))."
            if let term = terminal { barkBody += " Terminal \(term)." }
            Task { await BarkService.send(title: "✈ Flight arriving soon", body: barkBody) }
        } else {
            content.title = "✈ \(flightNumber) — 1 Hour to Arrival"
            content.body  = "Your flight arrives at \(arrivalStr). Time to prepare!"
            let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: notifyAt)
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            schedule(content: content, trigger: trigger)
            var barkBody = "\(flightNumber) lands at \(airport) in 1 hour (\(arrivalStr))."
            if let term = terminal { barkBody += " Terminal \(term)." }
            Task { await BarkService.send(title: "✈ Flight arriving soon", body: barkBody) }
        }
    }

    func cancelNotification() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [identifier])
    }

    func scheduleLeaveByNotification(
        airport: String,
        terminal: String?,
        arrivalDate: Date,
        drivingMinutes: Int
    ) {
        cancelLeaveByNotification()

        let leaveByDate = arrivalDate.addingTimeInterval(-TimeInterval(drivingMinutes * 60))
        let notifyAt    = leaveByDate.addingTimeInterval(-15 * 60)
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

    /// The body string for the Bark leave-by push — matches the Mac notification body.
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

    private func schedule(content: UNMutableNotificationContent, trigger: UNNotificationTrigger) {
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        )
    }
}
