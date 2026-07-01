import Foundation
import CryptoKit

// MARK: - Session cache keys
private let kEpoch      = "tesla.session.epoch"
private let kCounter    = "tesla.session.counter"
private let kVehicleKey = "tesla.session.vehiclePublicKey"

// MARK: - TeslaCommandSigner
//
// Implements Tesla's signed command protocol for Fleet API.
// Reference: https://github.com/teslamotors/vehicle-command
//
// Flow:
//   1. Session handshake: send SessionInfoRequest → receive SessionInfo
//   2. ECDH: shared secret from our private key + vehicle's public key
//   3. HKDF: derive AES-128 session key from shared secret
//   4. AES-GCM: encrypt command, append authentication tag
//   5. Wrap in RoutableMessage with SignatureData
//   6. POST base64url to /api/1/vehicles/{vin}/signed_command

enum TeslaCommandSigner {

    // MARK: - Session handshake

    /// Send a SessionInfoRequest to the vehicle and parse the response.
    /// Returns the session info on success.
    static func fetchSession(vin: String, accessToken: String) async throws -> TeslaSessionInfo {
        guard let clientPubKey = KeyManager.publicKeyX963() else {
            throw SignerError.noKey
        }

        // Build RoutableMessage with session_info_request
        var msg = ProtoWriter()
        // field 2 (session_info_request): contains our public key
        msg.embedded(2) { req in
            req.bytes(1, value: clientPubKey)
        }
        // field 5 (to_destination): INFOTAINMENT domain
        msg.embedded(5) { dest in
            dest.varint(1, value: TeslaDomain.infotainment.rawValue)
        }
        // field 6 (from_destination): our key as routing address
        msg.embedded(6) { dest in
            dest.bytes(2, value: clientPubKey)
        }
        // field 7 (request_uuid)
        msg.bytes(7, value: randomUUID())

        let requestBody = msg.data
        let response    = try await postSignedCommand(vin: vin, token: accessToken, body: requestBody)

        // Parse RoutableMessage response — session_info is field 3
        var reader = ProtoReader(response)
        let fields  = reader.readAll()

        guard let sessionInfoBytes = fields[3]?.first,
              let info = TeslaSessionInfo.parse(from: sessionInfoBytes) else {
            throw SignerError.badSessionResponse
        }

        // Cache session state
        UserDefaults.standard.set(info.epoch,                  forKey: kEpoch)
        UserDefaults.standard.set(Int(info.counter),           forKey: kCounter)
        UserDefaults.standard.set(info.vehiclePublicKeyX963,   forKey: kVehicleKey)

        return info
    }

    // MARK: - Sign and send a command

    /// Sign and send an encrypted command to the vehicle.
    /// - Parameters:
    ///   - commandBytes: Serialized car_server.Action proto
    ///   - vin: Vehicle identification number
    ///   - accessToken: Valid Fleet API bearer token
    static func sendCommand(
        commandBytes: Data,
        vin: String,
        accessToken: String
    ) async throws {
        // Load or fetch session
        let session = try await ensureSession(vin: vin, accessToken: accessToken)
        guard let privateKey = KeyManager.loadPrivateKey() else {
            throw SignerError.noKey
        }
        guard let clientPubKey = KeyManager.publicKeyX963() else {
            throw SignerError.noKey
        }

        // Derive session key via ECDH + HKDF-SHA256
        let vehiclePubKey = try P256.KeyAgreement.PublicKey(x963Representation: session.vehiclePublicKeyX963)
        let sharedSecret  = try privateKey.sharedSecretFromKeyAgreement(with: vehiclePubKey)

        // ⚠️ If commands fail, verify salt/sharedInfo against Tesla's exact derivation
        let symmetricKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: session.epoch,
            sharedInfo: Data(),
            outputByteCount: 16
        )

        // Increment counter (monotonically required by Tesla protocol)
        let counter = (UserDefaults.standard.integer(forKey: kCounter)) + 1
        UserDefaults.standard.set(counter, forKey: kCounter)

        // Expiry: now + 5 minutes (in seconds)
        let expiresAt = Int(Date().timeIntervalSince1970) + 300

        // AES-GCM nonce: 12 random bytes
        let nonce = AES.GCM.Nonce()

        // Encrypt command
        let sealedBox = try AES.GCM.seal(commandBytes, using: symmetricKey, nonce: nonce)
        let tag         = sealedBox.tag          // 16 bytes auth tag
        let ciphertext  = sealedBox.ciphertext   // encrypted command bytes
        let nonceData   = Data(nonce)            // 12 bytes

        // Build AES_GCM_Personalized_Signature_Data
        // Build SignatureData
        // Build RoutableMessage
        var routable = ProtoWriter()

        // field 1 (signature_data)
        routable.embedded(1) { sigData in
            // signer_identity = field 1: our public key
            sigData.bytes(1, value: clientPubKey)
            // AES_GCM_Personalized_data = field 5
            sigData.embedded(5) { aes in
                aes.bytes(1,  value: tag)                           // authentication tag
                aes.bytes(2,  value: nonceData)                     // nonce
                aes.varint(3, value: counter)                       // counter
                aes.varint(4, value: expiresAt)                     // expires_at
                aes.bytes(5,  value: session.epoch)                 // epoch
                // field 6 (flags): 0 = default, omit
                // field 7 (key_id): optional, omit for simplicity
            }
        }

        // field 4 (protobuf_message_as_bytes): ciphertext of the command
        routable.bytes(4, value: ciphertext)

        // field 5 (to_destination): INFOTAINMENT
        routable.embedded(5) { dest in
            dest.varint(1, value: TeslaDomain.infotainment.rawValue)
        }

        // field 6 (from_destination): our routing address
        routable.embedded(6) { dest in
            dest.bytes(2, value: clientPubKey)
        }

        // field 7 (request_uuid)
        routable.bytes(7, value: randomUUID())

        _ = try await postSignedCommand(vin: vin, token: accessToken, body: routable.data)
    }

    // MARK: - Helpers

    private static func ensureSession(vin: String, accessToken: String) async throws -> TeslaSessionInfo {
        // Use cached session if available
        if let epoch = UserDefaults.standard.data(forKey: kEpoch),
           let pubKey = UserDefaults.standard.data(forKey: kVehicleKey),
           !epoch.isEmpty, !pubKey.isEmpty {
            let counter = UserDefaults.standard.integer(forKey: kCounter)
            return TeslaSessionInfo(
                counter: UInt32(counter),
                vehiclePublicKeyX963: pubKey,
                epoch: epoch,
                clockTime: 0
            )
        }
        // Fetch fresh session
        return try await fetchSession(vin: vin, accessToken: accessToken)
    }

    /// Clear cached session — call when the vehicle may have rotated its session key
    static func clearSession() {
        UserDefaults.standard.removeObject(forKey: kEpoch)
        UserDefaults.standard.removeObject(forKey: kCounter)
        UserDefaults.standard.removeObject(forKey: kVehicleKey)
    }

    private static func postSignedCommand(vin: String, token: String, body: Data) async throws -> Data {
        let url = URL(string: "\(Config.teslaFleetBaseURL)/api/1/vehicles/\(vin)/signed_command")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-protobuf", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let (data, resp) = try await URLSession.shared.data(for: request)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        print("TeslaCommandSigner: signed_command HTTP \(status)")
        if status == 401 {
            throw SignerError.unauthorized
        }
        return data
    }

    private static func randomUUID() -> Data {
        let uuid = UUID().uuid
        return Data([uuid.0,  uuid.1,  uuid.2,  uuid.3,
                     uuid.4,  uuid.5,  uuid.6,  uuid.7,
                     uuid.8,  uuid.9,  uuid.10, uuid.11,
                     uuid.12, uuid.13, uuid.14, uuid.15])
    }
}

enum SignerError: Error, LocalizedError {
    case noKey
    case badSessionResponse
    case unauthorized
    case vehicleError(String)

    var errorDescription: String? {
        switch self {
        case .noKey:               return "No virtual key found — generate one first"
        case .badSessionResponse:  return "Could not parse Tesla session response"
        case .unauthorized:        return "Access token invalid or expired"
        case .vehicleError(let r): return "Vehicle error: \(r)"
        }
    }
}
