import CryptoKit
import Foundation
import Security

/// App Store Connect API key. Loaded from, in order:
/// 1. `ASC_KEY_ID`, `ASC_ISSUER_ID` and `ASC_KEY_PATH` (or `ASC_KEY_P8`, the key's contents)
/// 2. `~/.config/launchseq/credentials` (`key = value` lines), which must not be readable by others
/// 3. For the private key only: the login Keychain, service `launchseq`, account = the key ID
///
/// Nothing here is ever printed, logged or written to disk.
public struct ASCCredentials: Sendable {
    public let keyID: String
    public let issuerID: String
    let privateKey: P256.Signing.PrivateKey

    public init(keyID: String, issuerID: String, privateKey: P256.Signing.PrivateKey) {
        self.keyID = keyID; self.issuerID = issuerID; self.privateKey = privateKey
    }

    public static var defaultFile: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/launchseq/credentials")
    }

    public static func load(environment: [String: String] = ProcessInfo.processInfo.environment, file: URL = defaultFile) throws -> ASCCredentials {
        var values: [String: String] = [:]
        if FileManager.default.fileExists(atPath: file.path) {
            try checkPermissions(file)
            values = parseFile(try String(contentsOf: file, encoding: .utf8))
        }
        func value(_ envName: String, _ fileKey: String) -> String? {
            if let v = environment[envName], !v.isEmpty { return v }
            return values[fileKey]
        }
        guard let keyID = value("ASC_KEY_ID", "key_id") else {
            throw LaunchError.precondition("No App Store Connect key ID. Set ASC_KEY_ID or key_id in \(file.path).")
        }
        guard let issuerID = value("ASC_ISSUER_ID", "issuer_id") else {
            throw LaunchError.precondition("No App Store Connect issuer ID. Set ASC_ISSUER_ID or issuer_id in \(file.path).")
        }
        guard keyID.range(of: #"^[A-Z0-9]{6,20}$"#, options: .regularExpression) != nil else {
            throw LaunchError.precondition("The App Store Connect key ID doesn't look right (expected letters and digits).")
        }

        let pem: String
        if let inline = environment["ASC_KEY_P8"], !inline.isEmpty {
            pem = inline
        } else if let path = value("ASC_KEY_PATH", "key_path") {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            try checkPermissions(url)
            pem = try String(contentsOf: url, encoding: .utf8)
        } else if let fromKeychain = try keychainKey(account: keyID) {
            pem = fromKeychain
        } else {
            let defaultPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".appstoreconnect/private_keys/AuthKey_\(keyID).p8")
            guard FileManager.default.fileExists(atPath: defaultPath.path) else {
                throw LaunchError.precondition("No App Store Connect private key. Set ASC_KEY_PATH, key_path in \(file.path), or store it in the Keychain (`launchseq doctor` explains how).")
            }
            try checkPermissions(defaultPath)
            pem = try String(contentsOf: defaultPath, encoding: .utf8)
        }
        do {
            return ASCCredentials(keyID: keyID, issuerID: issuerID, privateKey: try P256.Signing.PrivateKey(pemRepresentation: pem))
        } catch {
            throw LaunchError.precondition("The App Store Connect private key couldn't be read as a .p8 (PKCS#8 PEM) EC key.")
        }
    }

    static func parseFile(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), let eq = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[..<eq].trimmingCharacters(in: .whitespaces)
            var value = trimmed[trimmed.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") { value = String(value.dropFirst().dropLast()) }
            out[key] = value
        }
        return out
    }

    /// Refuses secret files that group or others can read.
    static func checkPermissions(_ url: URL) throws {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let mode = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        guard mode & 0o077 == 0 else {
            throw LaunchError.precondition("\(url.path) is readable by other users (mode \(String(mode, radix: 8))). Run: chmod 600 \(url.path)")
        }
    }

    static func keychainKey(account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "launchseq",
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// ES256 JWTs for the App Store Connect API. Tokens live in memory only.
public enum ASCToken {
    /// Apple rejects tokens that live longer than 20 minutes.
    public static let lifetime: TimeInterval = 15 * 60

    public static func make(_ credentials: ASCCredentials, now: Date = Date()) throws -> String {
        let header = ["alg": "ES256", "kid": credentials.keyID, "typ": "JWT"]
        let iat = Int(now.timeIntervalSince1970)
        let payload: [String: Any] = [
            "iss": credentials.issuerID,
            "iat": iat,
            "exp": iat + Int(lifetime),
            "aud": "appstoreconnect-v1",
        ]
        let h = try base64url(JSONSerialization.data(withJSONObject: header, options: [.sortedKeys]))
        let p = try base64url(JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
        let signingInput = Data("\(h).\(p)".utf8)
        // CryptoKit's raw representation is r || s, which is what JWS ES256 expects.
        let signature = try credentials.privateKey.signature(for: signingInput).rawRepresentation
        return "\(h).\(p).\(base64url(signature))"
    }

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
