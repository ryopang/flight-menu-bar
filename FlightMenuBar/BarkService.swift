import Foundation

struct BarkService {
    static func send(title: String, body: String) async {
        guard let url = URL(string: "https://api.day.app/push") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10

        let payload: [String: String] = [
            "token": Config.barkDeviceToken,
            "title": title,
            "body":  body,
            "sound": "default",
            "level": "timeSensitive",
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        _ = try? await URLSession.shared.data(for: request)
    }
}
