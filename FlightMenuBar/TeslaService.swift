import Foundation
import AppKit
import CoreLocation

/// Manages Tesla Fleet API: OAuth, virtual key setup, and signed navigation commands.
@MainActor
class TeslaService: ObservableObject {
    static let shared = TeslaService()
    private init() {}

    // MARK: - Published state

    @Published var isConnected: Bool         = false
    @Published var isConnecting: Bool        = false
    @Published var hasVirtualKey: Bool       = false
    @Published var isPartnerRegistered: Bool = false
    @Published var isRegisteringPartner: Bool = false
    @Published var lastError: String?        = nil
    @Published var publicKeyPEM: String?     = nil
    @Published var batteryLevel: Int?        = nil

    // MARK: - Lifecycle

    func restoreSession() {
        isConnected          = UserDefaults.standard.string(forKey: Config.teslaRefreshTokenKey) != nil
        hasVirtualKey        = UserDefaults.standard.bool(forKey: Config.teslaVirtualKeyAddedKey)
        isPartnerRegistered  = UserDefaults.standard.bool(forKey: Config.teslaPartnerRegisteredKey)
        publicKeyPEM         = KeyManager.loadPrivateKey().map { KeyManager.publicKeyPEM(from: $0.publicKey) }
        if isConnected { Task { await refreshBatteryLevel() } }
    }

    func refreshBatteryLevel() async {
        guard isConnected,
              let token = await validAccessToken(),
              let vin = UserDefaults.standard.string(forKey: Config.teslaVehicleVINKey), !vin.isEmpty
        else { return }
        var req = URLRequest(url: URL(string: "\(Config.teslaFleetBaseURL)/api/1/vehicles/\(vin)/vehicle_data?endpoints=charge_state")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let response = json["response"] as? [String: Any],
              let chargeState = response["charge_state"] as? [String: Any],
              let level = chargeState["battery_level"] as? Int
        else { return }
        batteryLevel = level
    }

    func disconnect() {
        UserDefaults.standard.removeObject(forKey: Config.teslaAccessTokenKey)
        UserDefaults.standard.removeObject(forKey: Config.teslaRefreshTokenKey)
        UserDefaults.standard.removeObject(forKey: Config.teslaTokenExpiryKey)
        UserDefaults.standard.removeObject(forKey: Config.teslaVehicleIDKey)
        UserDefaults.standard.removeObject(forKey: Config.teslaVehicleVINKey)
        UserDefaults.standard.set(false, forKey: Config.teslaVirtualKeyAddedKey)
        TeslaCommandSigner.clearSession()
        isConnected   = false
        hasVirtualKey = false
        lastError     = nil
    }

    // MARK: - Virtual Key Setup

    /// Step 1 of setup: generate the P-256 key pair.
    /// The returned PEM must be hosted at:
    ///   https://ryosportfolio.vercel.app/.well-known/appspecific/com.tesla.3p.public-key.pem
    func generateVirtualKey() -> String? {
        do {
            let pem = try KeyManager.generateKeyPair()
            publicKeyPEM = pem
            TeslaCommandSigner.clearSession()  // session uses old key
            return pem
        } catch {
            lastError = "Key generation failed: \(error.localizedDescription)"
            return nil
        }
    }

    /// Step 3 of setup: register with Tesla's Fleet API backend, then open the key-add URL.
    /// The partner registration call is required once before the _ak QR flow will succeed.
    func registerAndOpenKeyURL() async {
        if !isPartnerRegistered {
            isRegisteringPartner = true
            lastError = nil
            let ok = await doRegisterPartner()
            isRegisteringPartner = false
            if !ok { return }
        }
        let url = URL(string: "https://tesla.com/_ak/\(Config.teslaKeyServerDomain)")!
        NSWorkspace.shared.open(url)
    }

    /// Call after user confirms they've added the key to their car.
    func markVirtualKeyAdded() {
        hasVirtualKey = true
        UserDefaults.standard.set(true, forKey: Config.teslaVirtualKeyAddedKey)
    }

    // MARK: - OAuth: Step 1 — open browser

    func startAuth() {
        var comps = URLComponents(string: "https://auth.tesla.com/oauth2/v3/authorize")!
        comps.queryItems = [
            URLQueryItem(name: "client_id",     value: Config.teslaClientID),
            URLQueryItem(name: "redirect_uri",  value: Config.teslaRedirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope",         value: "openid offline_access vehicle_device_data vehicle_cmds"),
            URLQueryItem(name: "state",         value: UUID().uuidString)
        ]
        if let url = comps.url {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - OAuth: Step 2 — handle redirect

    func handleCallback(url: URL) async {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let code = comps.queryItems?.first(where: { $0.name == "code" })?.value else {
            lastError = "Invalid callback URL"
            return
        }
        isConnecting = true
        lastError    = nil
        defer { isConnecting = false }

        if await exchangeCode(code) {
            await fetchAndCacheVehicleInfo()
            isConnected = true
            await refreshBatteryLevel()
        } else {
            lastError = "Token exchange failed — please try again"
        }
    }

    // MARK: - Navigation

    /// Call when the leave-by notification fires.
    func sendNavigation(airport: String, terminal: String?) async {
        guard isConnected else { return }
        guard hasVirtualKey else {
            print("TeslaService: virtual key not added — skipping navigation")
            return
        }
        guard let vin = UserDefaults.standard.string(forKey: Config.teslaVehicleVINKey), !vin.isEmpty else {
            print("TeslaService: no VIN cached")
            return
        }
        guard let token = await validAccessToken() else {
            print("TeslaService: no valid token")
            return
        }

        let address = terminalAddress(airport: airport, terminal: terminal)
        print("TeslaService: geocoding \(address)")

        // Geocode address to GPS coordinates
        guard let (lat, lon) = await geocode(address: address) else {
            print("TeslaService: geocoding failed")
            return
        }

        print("TeslaService: sending GPS navigation \(lat), \(lon) to VIN \(vin)")

        // Wake vehicle
        await wakeVehicle(vin: vin, token: token)

        // Build and sign the navigation command
        let commandBytes = buildNavGPSAction(latitude: lat, longitude: lon)
        do {
            try await TeslaCommandSigner.sendCommand(
                commandBytes: commandBytes,
                vin: vin,
                accessToken: token
            )
            print("TeslaService: navigation sent ✓")
        } catch SignerError.badSessionResponse {
            // Session may be stale — clear and retry once
            TeslaCommandSigner.clearSession()
            do {
                try await TeslaCommandSigner.sendCommand(
                    commandBytes: commandBytes,
                    vin: vin,
                    accessToken: token
                )
                print("TeslaService: navigation sent on retry ✓")
            } catch {
                print("TeslaService: navigation failed after retry — \(error)")
            }
        } catch {
            print("TeslaService: navigation failed — \(error.localizedDescription)")
        }
    }

    // MARK: - Private: Partner registration

    private func doRegisterPartner() async -> Bool {
        guard let ccToken = await clientCredentialsToken() else {
            lastError = "Could not obtain client credentials token"
            return false
        }
        var request = URLRequest(url: URL(string: "\(Config.teslaFleetBaseURL)/api/1/partner_accounts")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(ccToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json",  forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(["domain": Config.teslaKeyServerDomain])

        guard let (data, resp) = try? await URLSession.shared.data(for: request) else {
            lastError = "Partner registration: network error"
            return false
        }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        print("TeslaService: partner_accounts HTTP \(status) — \(String(data: data, encoding: .utf8) ?? "")")

        // 200 = registered, 409 = already registered — both are success
        if status == 200 || status == 201 || status == 409 {
            UserDefaults.standard.set(true, forKey: Config.teslaPartnerRegisteredKey)
            isPartnerRegistered = true
            return true
        }
        lastError = "Partner registration failed (HTTP \(status))"
        return false
    }

    private func clientCredentialsToken() async -> String? {
        var request = URLRequest(url: URL(string: "https://auth.tesla.com/oauth2/v3/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let params: [String: String] = [
            "grant_type":    "client_credentials",
            "client_id":     Config.teslaClientID,
            "client_secret": Config.teslaClientSecret,
            "scope":         "openid vehicle_device_data vehicle_cmds vehicle_charging_cmds",
            "audience":      Config.teslaFleetBaseURL
        ]
        request.httpBody = urlEncode(params)
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let response  = try? JSONDecoder().decode(TokenResponse.self, from: data),
              let token     = response.access_token else { return nil }
        return token
    }

    // MARK: - Private: OAuth helpers

    private func exchangeCode(_ code: String) async -> Bool {
        var request = URLRequest(url: URL(string: "https://auth.tesla.com/oauth2/v3/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let params: [String: String] = [
            "grant_type":    "authorization_code",
            "client_id":     Config.teslaClientID,
            "client_secret": Config.teslaClientSecret,
            "code":          code,
            "redirect_uri":  Config.teslaRedirectURI
        ]
        request.httpBody = urlEncode(params)

        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let response  = try? JSONDecoder().decode(TokenResponse.self, from: data),
              response.access_token != nil else { return false }
        saveTokens(response)
        return true
    }

    private func refreshAccessToken() async -> String? {
        guard let rt = UserDefaults.standard.string(forKey: Config.teslaRefreshTokenKey) else {
            return nil
        }
        var request = URLRequest(url: URL(string: "https://auth.tesla.com/oauth2/v3/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let params: [String: String] = [
            "grant_type":    "refresh_token",
            "client_id":     Config.teslaClientID,
            "client_secret": Config.teslaClientSecret,
            "refresh_token": rt
        ]
        request.httpBody = urlEncode(params)

        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let response  = try? JSONDecoder().decode(TokenResponse.self, from: data),
              response.access_token != nil else {
            await MainActor.run { isConnected = false }
            return nil
        }
        saveTokens(response)
        return response.access_token
    }

    func validAccessToken() async -> String? {
        let expiry = UserDefaults.standard.double(forKey: Config.teslaTokenExpiryKey)
        let now    = Date().timeIntervalSince1970
        if expiry > 0, now < expiry - 300,
           let token = UserDefaults.standard.string(forKey: Config.teslaAccessTokenKey) {
            return token
        }
        return await refreshAccessToken()
    }

    private func saveTokens(_ r: TokenResponse) {
        if let at = r.access_token  { UserDefaults.standard.set(at, forKey: Config.teslaAccessTokenKey) }
        if let rt = r.refresh_token { UserDefaults.standard.set(rt, forKey: Config.teslaRefreshTokenKey) }
        if let ex = r.expires_in    { UserDefaults.standard.set(Date().timeIntervalSince1970 + Double(ex), forKey: Config.teslaTokenExpiryKey) }
    }

    private func urlEncode(_ params: [String: String]) -> Data? {
        params.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }
              .joined(separator: "&")
              .data(using: .utf8)
    }

    // MARK: - Private: Vehicle info

    private func fetchAndCacheVehicleInfo() async {
        guard let token = await validAccessToken() else { return }
        var request = URLRequest(url: URL(string: "\(Config.teslaFleetBaseURL)/api/1/vehicles")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let list = try? JSONDecoder().decode(VehicleListResponse.self, from: data),
              let first = list.response?.first else { return }
        UserDefaults.standard.set(String(first.id),  forKey: Config.teslaVehicleIDKey)
        UserDefaults.standard.set(first.vin ?? "",   forKey: Config.teslaVehicleVINKey)
        print("TeslaService: vehicle cached — \(first.display_name ?? "?") VIN=\(first.vin ?? "?")")
    }

    private func wakeVehicle(vin: String, token: String) async {
        var req = URLRequest(url: URL(string: "\(Config.teslaFleetBaseURL)/api/1/vehicles/\(vin)/wake_up")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        _ = try? await URLSession.shared.data(for: req)
        try? await Task.sleep(nanoseconds: 3_000_000_000) // 3s
    }

    // MARK: - Private: Geocoding

    private func geocode(address: String) async -> (Double, Double)? {
        await withCheckedContinuation { continuation in
            CLGeocoder().geocodeAddressString(address) { placemarks, _ in
                if let loc = placemarks?.first?.location?.coordinate {
                    continuation.resume(returning: (loc.latitude, loc.longitude))
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    // MARK: - Private: Address helpers

    private func terminalAddress(airport: String, terminal: String?) -> String {
        guard let term = terminal else { return "\(airport) Airport" }
        switch airport {
        case "JFK": return "Terminal \(term), JFK International Airport, Jamaica, NY 11430"
        case "LGA": return "Terminal \(term), LaGuardia Airport, East Elmhurst, NY 11371"
        case "EWR": return "Terminal \(term), Newark Liberty International Airport, Newark, NJ 07114"
        case "HPN": return "Westchester County Airport, White Plains, NY 10604"
        default:    return "\(airport) Airport Terminal \(term)"
        }
    }

    // MARK: - Decodable models

    private struct TokenResponse: Decodable {
        let access_token: String?
        let refresh_token: String?
        let expires_in: Int?
    }

    private struct VehicleListResponse: Decodable {
        let response: [VehicleItem]?
    }

    private struct VehicleItem: Decodable {
        let id: Int
        let vin: String?
        let display_name: String?
    }
}
