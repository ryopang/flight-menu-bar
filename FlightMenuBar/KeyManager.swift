import Foundation
import CryptoKit
import Security

/// Manages the P-256 key pair used for Tesla virtual key signing.
/// Private key lives in Keychain; public key is hosted on Vercel.
enum KeyManager {

    private static let keychainAccount = "com.personal.FlightMenuBar.teslaKey"

    // MARK: - Public API

    /// Generate a new key pair (overwrites any existing one).
    /// Returns the PEM string of the public key — host this on Vercel.
    @discardableResult
    static func generateKeyPair() throws -> String {
        deleteKey()
        let privateKey = P256.KeyAgreement.PrivateKey()
        try saveToKeychain(privateKey)
        return publicKeyPEM(from: privateKey.publicKey)
    }

    /// Returns the PEM of the existing public key, generating a new pair if none exists.
    static func getOrCreatePublicKeyPEM() throws -> String {
        if let existing = loadPrivateKey() {
            return publicKeyPEM(from: existing.publicKey)
        }
        return try generateKeyPair()
    }

    /// Load the private key from Keychain.
    static func loadPrivateKey() -> P256.KeyAgreement.PrivateKey? {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String:  true
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? P256.KeyAgreement.PrivateKey(rawRepresentation: data)
    }

    /// Returns the client's uncompressed public key (04 || x || y, 65 bytes).
    static func publicKeyX963() -> Data? {
        loadPrivateKey()?.publicKey.x963Representation
    }

    // MARK: - PEM encoding

    /// Encodes a P-256 public key as a PKCS#8 SubjectPublicKeyInfo PEM.
    static func publicKeyPEM(from key: P256.KeyAgreement.PublicKey) -> String {
        // Manually build DER SubjectPublicKeyInfo wrapper for P-256
        // 30 59           SEQUENCE (89 bytes total)
        //   30 13         SEQUENCE (19 bytes — algorithm)
        //     06 07 ...   OID id-ecPublicKey
        //     06 08 ...   OID prime256v1
        //   03 42 00      BIT STRING (66 bytes, 0 unused)
        //     04 [x][y]   uncompressed point
        let spkiHeader = Data([
            0x30, 0x59,
            0x30, 0x13,
            0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01,
            0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07,
            0x03, 0x42, 0x00
        ])
        let der = spkiHeader + key.x963Representation
        let b64 = der.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return "-----BEGIN PUBLIC KEY-----\n\(b64)-----END PUBLIC KEY-----\n"
    }

    // MARK: - Keychain helpers

    private static func saveToKeychain(_ key: P256.KeyAgreement.PrivateKey) throws {
        let query: [String: Any] = [
            kSecClass as String:            kSecClassGenericPassword,
            kSecAttrAccount as String:      keychainAccount,
            kSecValueData as String:        key.rawRepresentation,
            kSecAttrAccessible as String:   kSecAttrAccessibleAfterFirstUnlock
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            throw TeslaKeyError.keychainError(status)
        }
    }

    private static func deleteKey() {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrAccount as String: keychainAccount
        ]
        SecItemDelete(query as CFDictionary)
    }
}

enum TeslaKeyError: Error {
    case keychainError(OSStatus)
    case noKey
    case invalidPublicKey
}
