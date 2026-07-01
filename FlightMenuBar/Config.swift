import Foundation

// MARK: - Config
//
// Copy Config.secret.swift.template → Config.secret.swift and fill in your values.
// Config.secret.swift is gitignored and never committed.

enum Config {
    // AeroDataBox via RapidAPI — get a key at rapidapi.com/aedbx-aerodatabox
    static let rapidAPIKey      = Secrets.rapidAPIKey
    static let rapidAPIHost     = "aerodatabox.p.rapidapi.com"
    static let flightAPIBaseURL = "https://aerodatabox.p.rapidapi.com/flights/number"

    // Timers
    static let displayTimerInterval:  TimeInterval = 1.0
    static let pollingTimerInterval:  TimeInterval = 1200.0  // 20 min
    static let positionTimerInterval: TimeInterval = 30.0    // 30 s

    // UserDefaults keys
    static let lastFlightNumberKey = "lastFlightNumber"

    // Bark push notifications — get your device token from the Bark iOS app
    static let barkDeviceToken = Secrets.barkDeviceToken

    // Tesla Fleet API — register at developer.tesla.com
    static let teslaClientID        = Secrets.teslaClientID
    static let teslaClientSecret    = Secrets.teslaClientSecret
    static let teslaRedirectURI     = "flightmenubar://auth/callback"
    static let teslaFleetBaseURL    = "https://fleet-api.prd.na.vn.cloud.tesla.com"
    // Domain where your Tesla public key PEM is hosted (see README)
    static let teslaKeyServerDomain = Secrets.teslaKeyServerDomain

    // Tesla UserDefaults keys
    static let teslaAccessTokenKey       = "tesla.accessToken"
    static let teslaRefreshTokenKey      = "tesla.refreshToken"
    static let teslaTokenExpiryKey       = "tesla.tokenExpiry"
    static let teslaVehicleIDKey         = "tesla.vehicleID"
    static let teslaVehicleVINKey        = "tesla.vehicleVIN"
    static let teslaVirtualKeyAddedKey   = "tesla.virtualKeyAdded"
    static let teslaPartnerRegisteredKey = "tesla.partnerRegistered"
}
