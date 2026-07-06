import Foundation

// MARK: - Config
//
// Copy Config.secret.swift.template → Config.secret.swift and fill in your values.
// Config.secret.swift is gitignored and never committed.

enum Config {
    // AeroDataBox via RapidAPI
    static let rapidAPIKey      = Secrets.rapidAPIKey
    static let rapidAPIHost     = "aerodatabox.p.rapidapi.com"
    static let flightAPIBaseURL = "https://aerodatabox.p.rapidapi.com/flights/number"

    // FlightAware AeroAPI — optional live delay/status overlay
    static let aeroAPIKey     = Secrets.aeroAPIKey
    static let aeroAPIBaseURL = "https://aeroapi.flightaware.com/aeroapi"

    // Timers
    static let displayTimerInterval:  TimeInterval = 30.0   // menu bar label (minute resolution is fine)
    static let pollingTimerInterval:  TimeInterval = 1200.0 // 20 min
    static let positionTimerInterval: TimeInterval = 120.0  // 2 min (OpenSky budget)

    // UserDefaults — flight
    static let lastFlightNumberKey = "lastFlightNumber"

    // UserDefaults — settings (user-configurable)
    static let homeAddressKey         = "settings.homeAddress"
    static let leaveByLeadMinutesKey  = "settings.leaveByLeadMinutes"
    static let defaultLeaveByLeadMin  = 15   // minutes before leave-by time to notify

    // Bark push notifications
    static let barkDeviceToken = Secrets.barkDeviceToken

    // Tesla Fleet API
    static let teslaClientID        = Secrets.teslaClientID
    static let teslaClientSecret    = Secrets.teslaClientSecret
    static let teslaRedirectURI     = "flightmenubar://auth/callback"
    static let teslaFleetBaseURL    = "https://fleet-api.prd.na.vn.cloud.tesla.com"
    static let teslaKeyServerDomain = Secrets.teslaKeyServerDomain

    // Tesla UserDefaults keys
    static let teslaAccessTokenKey       = "tesla.accessToken"
    static let teslaRefreshTokenKey      = "tesla.refreshToken"
    static let teslaTokenExpiryKey       = "tesla.tokenExpiry"
    static let teslaVehicleIDKey         = "tesla.vehicleID"
    static let teslaVehicleVINKey        = "tesla.vehicleVIN"
    static let teslaVirtualKeyAddedKey   = "tesla.virtualKeyAdded"
    static let teslaPartnerRegisteredKey = "tesla.partnerRegistered"

    // Helpers
    static var homeAddress: String {
        UserDefaults.standard.string(forKey: homeAddressKey)?.trimmingCharacters(in: .whitespaces).isEmpty == false
            ? UserDefaults.standard.string(forKey: homeAddressKey)!
            : Secrets.homeAddress
    }

    static var leaveByLeadMinutes: Int {
        let v = UserDefaults.standard.integer(forKey: leaveByLeadMinutesKey)
        return v > 0 ? v : defaultLeaveByLeadMin
    }
}
