import CommonCrypto
import CryptoKit
import Foundation
import LocalAuthentication
import Security
import TokenUsageCore

enum APIKeyStoreError: Error, LocalizedError {
    case emptyPassphrase
    case weakPassphrase
    case insecureStorage(String)
    case invalidVault
    case missingKey
    case encryptionFailed
    case decryptionFailed

    var errorDescription: String? {
        switch self {
        case .emptyPassphrase:
            return "Create a local encryption password before saving the API key."
        case .weakPassphrase:
            return "Use a local encryption password with at least 16 characters and a mix of character types."
        case .insecureStorage(let detail):
            return "API key storage is not private enough: \(detail)"
        case .invalidVault:
            return "Stored API key vault is invalid or corrupted."
        case .missingKey:
            return "No encrypted OpenAI API key is stored."
        case .encryptionFailed:
            return "Could not encrypt the OpenAI API key."
        case .decryptionFailed:
            return "Could not decrypt the OpenAI API key. Check the local encryption password."
        }
    }
}

@MainActor
final class APIKeyStore {
    private struct Vault: Codable {
        let version: Int
        let kdf: String
        let iterations: UInt32
        let salt: String
        let sealedBox: String
        let createdAt: Date
        let updatedAt: Date
    }

    private let fileManager = FileManager.default
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private let newVaultVersion = 2
    private let newVaultIterations: UInt32 = 600_000
    private let minimumPassphraseLength = 16
    private let vaultURL: URL

    init() {
        vaultURL = TODEXAppPaths.supportFile("api-key.vault.json")
    }

    func hasStoredKey() -> Bool {
        fileManager.fileExists(atPath: vaultURL.path)
    }

    func readKeyWithTouchID(reason: String, passphrase: String) async throws -> String {
        guard !passphrase.isEmpty else {
            throw APIKeyStoreError.emptyPassphrase
        }

        try await authenticate(reason: reason)
        try validatePrivateFile(vaultURL)

        let data = try Data(contentsOf: vaultURL)
        let vault = try decoder.decode(Vault.self, from: data)
        guard (1...newVaultVersion).contains(vault.version),
              vault.kdf == "PBKDF2-HMAC-SHA256",
              let salt = Data(base64Encoded: vault.salt),
              let boxData = Data(base64Encoded: vault.sealedBox) else {
            throw APIKeyStoreError.invalidVault
        }

        let key = try deriveKey(passphrase: passphrase, salt: salt, iterations: vault.iterations)
        do {
            let box = try AES.GCM.SealedBox(combined: boxData)
            var plaintext: Data
            if vault.version >= 2 {
                plaintext = try AES.GCM.open(box, using: key, authenticating: associatedData(for: vault))
            } else {
                plaintext = try AES.GCM.open(box, using: key)
            }
            defer {
                plaintext.resetBytes(in: 0..<plaintext.count)
            }
            guard let apiKey = String(data: plaintext, encoding: .utf8),
                  !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw APIKeyStoreError.decryptionFailed
            }
            let normalizedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if shouldUpgrade(vault) {
                try? saveKey(normalizedKey, passphrase: passphrase)
            }
            return normalizedKey
        } catch {
            throw APIKeyStoreError.decryptionFailed
        }
    }

    func saveKey(_ key: String, passphrase: String) throws {
        guard !passphrase.isEmpty else {
            throw APIKeyStoreError.emptyPassphrase
        }
        guard isStrongEnough(passphrase) else {
            throw APIKeyStoreError.weakPassphrase
        }

        let normalizedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedKey.isEmpty else {
            throw APIKeyStoreError.missingKey
        }

        var salt = Data(count: 32)
        let status = salt.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, bytes.count, bytes.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw APIKeyStoreError.encryptionFailed
        }

        let symmetricKey = try deriveKey(passphrase: passphrase, salt: salt, iterations: newVaultIterations)
        var plaintext = Data(normalizedKey.utf8)
        defer {
            plaintext.resetBytes(in: 0..<plaintext.count)
        }

        let now = Date()
        let vault = Vault(
            version: newVaultVersion,
            kdf: "PBKDF2-HMAC-SHA256",
            iterations: newVaultIterations,
            salt: salt.base64EncodedString(),
            sealedBox: "",
            createdAt: existingCreatedAt() ?? now,
            updatedAt: now
        )
        let sealed = try AES.GCM.seal(plaintext, using: symmetricKey, authenticating: associatedData(for: vault))
        guard let combined = sealed.combined else {
            throw APIKeyStoreError.encryptionFailed
        }
        let savedVault = Vault(
            version: vault.version,
            kdf: vault.kdf,
            iterations: vault.iterations,
            salt: vault.salt,
            sealedBox: combined.base64EncodedString(),
            createdAt: vault.createdAt,
            updatedAt: vault.updatedAt
        )

        try createPrivateDirectory(vaultURL.deletingLastPathComponent())
        try validatePrivateDirectory(vaultURL.deletingLastPathComponent())
        let data = try encoder.encode(savedVault)
        try PrivateFileIO.writePrivateData(data, to: vaultURL)
        try validatePrivateFile(vaultURL)
    }

    func deleteKey() throws {
        guard fileManager.fileExists(atPath: vaultURL.path) else { return }
        try fileManager.removeItem(at: vaultURL)
    }

    func storageDescription() -> String {
        vaultURL.path
    }

    private func authenticate(reason: String) async throws {
        let context = LAContext()
        context.localizedReason = reason
        var authError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &authError) else {
            throw authError ?? NSError(domain: LAError.errorDomain, code: LAError.biometryNotAvailable.rawValue)
        }

        let ok = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: success)
                }
            }
        }

        guard ok else {
            throw NSError(domain: LAError.errorDomain, code: LAError.authenticationFailed.rawValue)
        }
    }

    private func deriveKey(passphrase: String, salt: Data, iterations: UInt32) throws -> SymmetricKey {
        var passwordData = Data(passphrase.utf8)
        defer {
            passwordData.resetBytes(in: 0..<passwordData.count)
        }
        var derived = Data(count: 32)
        let derivedCount = derived.count
        let result = passwordData.withUnsafeBytes { passwordBytes in
            salt.withUnsafeBytes { saltBytes in
                derived.withUnsafeMutableBytes { derivedBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.bindMemory(to: Int8.self).baseAddress,
                        passwordData.count,
                        saltBytes.bindMemory(to: UInt8.self).baseAddress,
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        iterations,
                        derivedBytes.bindMemory(to: UInt8.self).baseAddress,
                        derivedCount
                    )
                }
            }
        }

        guard result == kCCSuccess else {
            throw APIKeyStoreError.encryptionFailed
        }
        let symmetricKey = SymmetricKey(data: derived)
        derived.resetBytes(in: 0..<derived.count)
        return symmetricKey
    }

    private func associatedData(for vault: Vault) -> Data {
        Data("CodexTokenMenuBar.APIKeyVault.v\(vault.version).\(vault.kdf).\(vault.iterations).\(vault.salt)".utf8)
    }

    private func shouldUpgrade(_ vault: Vault) -> Bool {
        vault.version < newVaultVersion || vault.iterations < newVaultIterations
    }

    private func createPrivateDirectory(_ url: URL) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private func validatePrivateDirectory(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true else {
            throw APIKeyStoreError.insecureStorage("\(url.path) is not a directory.")
        }
        guard values.isSymbolicLink != true else {
            throw APIKeyStoreError.insecureStorage("\(url.path) must not be a symlink.")
        }
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        try validateOwnerAndMode(attributes: attributes, path: url.path, maxPermissions: 0o700)
    }

    private func validatePrivateFile(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true else {
            throw APIKeyStoreError.insecureStorage("\(url.path) is not a regular file.")
        }
        guard values.isSymbolicLink != true else {
            throw APIKeyStoreError.insecureStorage("\(url.path) must not be a symlink.")
        }
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        if let referenceCount = attributes[.referenceCount] as? NSNumber,
           referenceCount.intValue > 1 {
            throw APIKeyStoreError.insecureStorage("\(url.path) must not have multiple hard links.")
        }
        try validateOwnerAndMode(attributes: attributes, path: url.path, maxPermissions: 0o600)
    }

    private func validateOwnerAndMode(
        attributes: [FileAttributeKey: Any],
        path: String,
        maxPermissions: Int
    ) throws {
        let owner = attributes[.ownerAccountID] as? NSNumber
        guard owner?.uint32Value == getuid() else {
            throw APIKeyStoreError.insecureStorage("\(path) is not owned by the current user.")
        }
        guard let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue else {
            throw APIKeyStoreError.insecureStorage("\(path) permissions could not be verified.")
        }
        guard permissions & ~maxPermissions == 0 else {
            throw APIKeyStoreError.insecureStorage("\(path) has overly broad permissions.")
        }
    }

    private func isStrongEnough(_ passphrase: String) -> Bool {
        guard passphrase.count >= minimumPassphraseLength else { return false }
        let scalars = passphrase.unicodeScalars
        let hasLower = scalars.contains { CharacterSet.lowercaseLetters.contains($0) }
        let hasUpper = scalars.contains { CharacterSet.uppercaseLetters.contains($0) }
        let hasDigit = scalars.contains { CharacterSet.decimalDigits.contains($0) }
        let hasSymbol = scalars.contains {
            !CharacterSet.alphanumerics.contains($0) && !CharacterSet.whitespacesAndNewlines.contains($0)
        }
        return [hasLower, hasUpper, hasDigit, hasSymbol].filter { $0 }.count >= 3
    }

    private func existingCreatedAt() -> Date? {
        guard fileManager.fileExists(atPath: vaultURL.path),
              (try? validatePrivateFile(vaultURL)) != nil,
              let data = try? Data(contentsOf: vaultURL),
              let vault = try? decoder.decode(Vault.self, from: data) else {
            return nil
        }
        return vault.createdAt
    }
}
