import Foundation
import CryptoKit
import Security
import CommonCrypto

// MARK: - Local passphrase encryption

/// Canonicalize visually equivalent Unicode before deriving bytes. This keeps
/// a passphrase entered with a different keyboard composition form stable
/// across launches without trimming or otherwise changing its characters.
nonisolated private func normalizedPassphrase(_ passphrase: String) -> String {
    passphrase.precomposedStringWithCanonicalMapping
}

enum SecureStorageError: LocalizedError {
    case invalidEnvelope
    case encryptionFailed
    case decryptionFailed
    case invalidPassphrase
    case passphraseTooShort(minimumLength: Int)
    case missingPassphraseConfiguration
    case missingKey
    case randomGenerationFailed
    case storageLocationUnavailable
    case legacyCleanupFailed

    var errorDescription: String? {
        switch self {
        case .invalidEnvelope:
            return "The encrypted data has an unsupported or damaged format."
        case .encryptionFailed:
            return "Copi could not encrypt the data."
        case .decryptionFailed:
            return "Copi could not decrypt the data."
        case .invalidPassphrase:
            return "The passphrase is incorrect."
        case .passphraseTooShort(let minimumLength):
            return "The passphrase must contain at least \(minimumLength) characters."
        case .missingPassphraseConfiguration:
            return "Copi has not been configured with an encryption passphrase."
        case .missingKey:
            return "Copi is locked. Enter the encryption passphrase to unlock stored content for this session."
        case .randomGenerationFailed:
            return "Copi could not generate secure random data."
        case .storageLocationUnavailable:
            return "Copi could not access its Application Support folder."
        case .legacyCleanupFailed:
            return "Copi could not remove all legacy plaintext storage. Cleanup will be retried on the next launch."
        }
    }
}

/// Encrypts every persisted clipboard/favorite payload with a root key derived
/// from the user's passphrase. Only a salted verifier is persisted; the
/// passphrase and derived key exist in memory for the current app session.
nonisolated final class SecurePayloadCrypto: @unchecked Sendable {
    static let shared = SecurePayloadCrypto()

    static let envelopeVersion = 2
    static let minimumPassphraseLength = 12
    private static let magic = Data("COPIENC2".utf8)
    private static let descriptorVersion = 1
    private static let descriptorFileName = "SecureStoragePassphrase-v2.json"
    private static let descriptorRounds: UInt32 = 600_000
    private static let verifierPlaintext = Data("COPI-PASSPHRASE-VERIFIER-v1".utf8)
    private static let verifierContext = Data("com.jos.copi.passphrase-verifier-v1".utf8)
    private let lock = NSLock()
    private var cachedKey: SymmetricKey?

    private struct PassphraseDescriptor: Codable {
        let version: Int
        let algorithm: String
        let keyDerivation: String
        let rounds: UInt32
        let salt: Data
        let verifier: Data
    }

    private init() {}

    var keyIsAvailable: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cachedKey != nil
    }

    var hasPassphraseConfiguration: Bool {
        guard let descriptorURL = try? Self.descriptorURL() else { return false }
        return FileManager.default.fileExists(atPath: descriptorURL.path)
    }

    func unlock(passphrase: String) throws {
        try Self.validatePassphraseLength(passphrase)
        let descriptor: PassphraseDescriptor
        do {
            let data = try Data(contentsOf: Self.descriptorURL())
            descriptor = try JSONDecoder().decode(PassphraseDescriptor.self, from: data)
        } catch let error as SecureStorageError {
            throw error
        } catch {
            if !hasPassphraseConfiguration {
                throw SecureStorageError.missingPassphraseConfiguration
            }
            throw SecureStorageError.invalidEnvelope
        }

        guard descriptor.version == Self.descriptorVersion,
              descriptor.algorithm == "AES-256-GCM",
              descriptor.keyDerivation == "PBKDF2-HMAC-SHA256",
              descriptor.rounds >= 100_000,
              descriptor.rounds <= 1_000_000,
              descriptor.salt.count >= 16,
              descriptor.salt.count <= 64,
              descriptor.verifier.count <= 4_096 else {
            throw SecureStorageError.invalidEnvelope
        }

        let key = try Self.derivePassphraseKey(
            passphrase: passphrase,
            salt: descriptor.salt,
            rounds: descriptor.rounds
        )
        do {
            let box = try AES.GCM.SealedBox(combined: descriptor.verifier)
            let plaintext = try AES.GCM.open(
                box,
                using: key,
                authenticating: Self.verifierContext
            )
            guard plaintext == Self.verifierPlaintext else {
                throw SecureStorageError.invalidPassphrase
            }
        } catch {
            throw SecureStorageError.invalidPassphrase
        }

        Self.enforceExistingStoragePermissions()
        lock.lock()
        cachedKey = key
        lock.unlock()
    }

    func seal(_ plaintext: Data, purpose: String) throws -> Data {
        let context = authenticatedContext(for: purpose)
        let box = try AES.GCM.seal(
            plaintext,
            using: derivedKey(label: "payload-encryption-v1"),
            authenticating: context
        )
        guard let combined = box.combined else { throw SecureStorageError.encryptionFailed }
        var envelope = Self.magic
        envelope.append(combined)
        return envelope
    }

    func open(_ envelope: Data, purpose: String) throws -> Data {
        guard envelope.count > Self.magic.count,
              envelope.prefix(Self.magic.count) == Self.magic else {
            throw SecureStorageError.invalidEnvelope
        }
        do {
            let box = try AES.GCM.SealedBox(combined: envelope.dropFirst(Self.magic.count))
            return try AES.GCM.open(
                box,
                using: derivedKey(label: "payload-encryption-v1"),
                authenticating: authenticatedContext(for: purpose)
            )
        } catch let error as SecureStorageError {
            throw error
        } catch {
            throw SecureStorageError.decryptionFailed
        }
    }

    /// Stable keyed identity for deduplication and learning. Unlike a plain hash,
    /// persisted metadata cannot be used to guess common clipboard values.
    func digest(_ data: Data) -> String? {
        guard let key = try? derivedKey(label: "payload-digest-v1") else { return nil }
        let authentication = HMAC<SHA256>.authenticationCode(for: data, using: key)
        return Data(authentication).map { String(format: "%02x", $0) }.joined()
    }

    private func masterKey() throws -> SymmetricKey {
        lock.lock()
        defer { lock.unlock() }
        if let cachedKey { return cachedKey }
        throw SecureStorageError.missingKey
    }

    private func derivedKey(label: String) throws -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: try masterKey(),
            salt: Data("com.jos.copi.secure-storage".utf8),
            info: Data(label.utf8),
            outputByteCount: 32
        )
    }

    private func authenticatedContext(for purpose: String) -> Data {
        Data("copi-secure-envelope-v1|\(purpose)".utf8)
    }

    fileprivate func configureNewPassphrase(_ passphrase: String) throws {
        try Self.validatePassphraseLength(passphrase)
        let salt = try Self.randomData(count: 16)
        let key = try Self.derivePassphraseKey(
            passphrase: passphrase,
            salt: salt,
            rounds: Self.descriptorRounds
        )
        let box = try AES.GCM.seal(
            Self.verifierPlaintext,
            using: key,
            authenticating: Self.verifierContext
        )
        guard let verifier = box.combined else {
            throw SecureStorageError.encryptionFailed
        }
        let descriptor = PassphraseDescriptor(
            version: Self.descriptorVersion,
            algorithm: "AES-256-GCM",
            keyDerivation: "PBKDF2-HMAC-SHA256",
            rounds: Self.descriptorRounds,
            salt: salt,
            verifier: verifier
        )
        let descriptorData = try JSONEncoder().encode(descriptor)
        let descriptorURL = try Self.descriptorURL()
        let fileManager = FileManager.default
        let storageDirectory = descriptorURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: storageDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: storageDirectory.path
        )
        try descriptorData.write(to: descriptorURL, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: descriptorURL.path
        )

        lock.lock()
        cachedKey = key
        lock.unlock()
    }

    fileprivate func encryptedArtifactsExist() -> Bool {
        let defaults = UserDefaults.standard
        if defaults.data(forKey: "secureClipboardHistoryV2") != nil
            || defaults.data(forKey: "secureFavoriteCategoriesV2") != nil {
            return true
        }
        guard let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return false }
        let root = support.appendingPathComponent("Copi", isDirectory: true)
        for name in ["SecureHistory-v2", "SecureFavorites-v2"] {
            let directory = root.appendingPathComponent(name, isDirectory: true)
            if let contents = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ), contents.contains(where: { $0.pathExtension == "copi" }) {
                return true
            }
        }
        return false
    }

    private static func descriptorURL() throws -> URL {
        guard let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw SecureStorageError.storageLocationUnavailable
        }
        return support
            .appendingPathComponent("Copi", isDirectory: true)
            .appendingPathComponent(descriptorFileName, isDirectory: false)
    }

    private static func validatePassphraseLength(_ passphrase: String) throws {
        guard normalizedPassphrase(passphrase).count >= minimumPassphraseLength else {
            throw SecureStorageError.passphraseTooShort(minimumLength: minimumPassphraseLength)
        }
    }

    private static func enforceExistingStoragePermissions() {
        guard let descriptorURL = try? descriptorURL() else { return }
        let fileManager = FileManager.default
        let storageDirectory = descriptorURL.deletingLastPathComponent()
        try? fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: storageDirectory.path
        )
        try? fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: descriptorURL.path
        )
    }

    private static func randomData(count: Int) throws -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, bytes.count, baseAddress)
        }
        guard status == errSecSuccess else {
            throw SecureStorageError.randomGenerationFailed
        }
        return data
    }

    private static func derivePassphraseKey(
        passphrase: String,
        salt: Data,
        rounds: UInt32
    ) throws -> SymmetricKey {
        let password = Array(normalizedPassphrase(passphrase).utf8)
        var output = [UInt8](repeating: 0, count: 32)
        let result = password.withUnsafeBufferPointer { passwordBuffer in
            salt.withUnsafeBytes { saltBuffer in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    passwordBuffer.baseAddress?.withMemoryRebound(
                        to: Int8.self,
                        capacity: passwordBuffer.count
                    ) { $0 },
                    passwordBuffer.count,
                    saltBuffer.bindMemory(to: UInt8.self).baseAddress,
                    salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    rounds,
                    &output,
                    output.count
                )
            }
        }
        guard result == kCCSuccess else { throw SecureStorageError.encryptionFailed }
        return SymmetricKey(data: output)
    }
}

// MARK: - Passphrase-protected portable envelopes

/// The portable envelope contains only derivation parameters and ciphertext.
/// Its decrypted JSON exists in memory only while export/import is running.
struct PortableEncryptedEnvelope: Codable {
    let version: Int
    let algorithm: String
    let keyDerivation: String
    let rounds: UInt32
    let salt: Data
    let ciphertext: Data
}

enum PortableBackupCrypto {
    static let rounds: UInt32 = 210_000

    static func seal(_ plaintext: Data, passphrase: String) throws -> PortableEncryptedEnvelope {
        guard !passphrase.isEmpty else { throw SecureStorageError.invalidPassphrase }
        var salt = Data(count: 16)
        let status = salt.withUnsafeMutableBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, bytes.count, baseAddress)
        }
        guard status == errSecSuccess else { throw SecureStorageError.randomGenerationFailed }

        let key = try derivedKey(passphrase: passphrase, salt: salt, rounds: rounds)
        let box = try AES.GCM.seal(plaintext, using: key)
        guard let combined = box.combined else { throw SecureStorageError.encryptionFailed }
        return PortableEncryptedEnvelope(
            version: 1,
            algorithm: "AES-256-GCM",
            keyDerivation: "PBKDF2-HMAC-SHA256",
            rounds: rounds,
            salt: salt,
            ciphertext: combined
        )
    }

    static func open(_ envelope: PortableEncryptedEnvelope, passphrase: String) throws -> Data {
        guard envelope.version == 1,
              envelope.algorithm == "AES-256-GCM",
              envelope.keyDerivation == "PBKDF2-HMAC-SHA256",
              envelope.rounds >= 100_000,
              envelope.rounds <= 1_000_000,
              envelope.salt.count >= 16,
              envelope.salt.count <= 64,
              envelope.ciphertext.count <= 64 * 1024 * 1024,
              !passphrase.isEmpty else {
            throw SecureStorageError.invalidEnvelope
        }
        do {
            let key = try derivedKey(passphrase: passphrase, salt: envelope.salt, rounds: envelope.rounds)
            let box = try AES.GCM.SealedBox(combined: envelope.ciphertext)
            return try AES.GCM.open(box, using: key)
        } catch {
            throw SecureStorageError.invalidPassphrase
        }
    }

    private static func derivedKey(passphrase: String, salt: Data, rounds: UInt32) throws -> SymmetricKey {
        let password = Array(normalizedPassphrase(passphrase).utf8)
        var output = [UInt8](repeating: 0, count: 32)
        let result = password.withUnsafeBufferPointer { passwordBuffer in
            salt.withUnsafeBytes { saltBuffer in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    passwordBuffer.baseAddress?.withMemoryRebound(to: Int8.self, capacity: passwordBuffer.count) { $0 },
                    passwordBuffer.count,
                    saltBuffer.bindMemory(to: UInt8.self).baseAddress,
                    salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    rounds,
                    &output,
                    output.count
                )
            }
        }
        guard result == kCCSuccess else { throw SecureStorageError.encryptionFailed }
        return SymmetricKey(data: output)
    }
}

// MARK: - One-time fresh secure schema

enum SecureStorageBootstrap {
    private static let schemaKey = "secureStorageSchemaVersion"
    private static let schemaVersion = 2

    static var hasExistingEncryptedArtifacts: Bool {
        SecurePayloadCrypto.shared.encryptedArtifactsExist()
    }

    /// Establishes a new local passphrase configuration. Current development
    /// data cannot be opened without the former device-managed key, so all old
    /// payloads and learned usage are deliberately removed before configuration.
    static func initializePassphraseStorage(passphrase: String) throws {
        let defaults = UserDefaults.standard
        do {
            guard passphrase.count >= SecurePayloadCrypto.minimumPassphraseLength else {
                throw SecureStorageError.passphraseTooShort(
                    minimumLength: SecurePayloadCrypto.minimumPassphraseLength
                )
            }
            try removePersistedPayloads(includeLearning: true)
            try SecurePayloadCrypto.shared.configureNewPassphrase(passphrase)
            defaults.set(schemaVersion, forKey: schemaKey)
            defaults.removeObject(forKey: "secureStorageBootstrapError")
        } catch {
            defaults.set(error.localizedDescription, forKey: "secureStorageBootstrapError")
            throw error
        }
    }

    /// The secure store intentionally starts clean. Old Copi builds persisted
    /// previews and favorite values as plaintext, so carrying that schema forward
    /// would violate the password guarantee before an item can be reclassified.
    static func prepareIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.integer(forKey: schemaKey) < schemaVersion else { return }

        defaults.removeObject(forKey: "clipboardHistory")
        defaults.removeObject(forKey: "favoriteCategories")
        defaults.removeObject(forKey: "favorites")

        var cleanupSucceeded = true
        if let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let copi = base.appendingPathComponent("Copi", isDirectory: true)
            for name in ["History", "Favorites"] {
                let directory = copi.appendingPathComponent(name, isDirectory: true)
                guard FileManager.default.fileExists(atPath: directory.path) else { continue }
                do {
                    try FileManager.default.removeItem(at: directory)
                } catch {
                    cleanupSucceeded = false
                }
            }
        } else {
            cleanupSucceeded = false
        }
        if cleanupSucceeded {
            defaults.set(schemaVersion, forKey: schemaKey)
            defaults.removeObject(forKey: "secureStorageBootstrapError")
        } else {
            defaults.set(
                SecureStorageError.legacyCleanupFailed.localizedDescription,
                forKey: "secureStorageBootstrapError"
            )
        }
    }

    /// Destructively returns encrypted clipboard/favorite storage to a clean,
    /// writable state. The passphrase descriptor and in-memory key are retained.
    /// The UI must obtain explicit confirmation before calling.
    static func resetEncryptedStorage() throws {
        let defaults = UserDefaults.standard
        do {
            guard SecurePayloadCrypto.shared.hasPassphraseConfiguration else {
                throw SecureStorageError.missingPassphraseConfiguration
            }
            guard SecurePayloadCrypto.shared.keyIsAvailable else {
                throw SecureStorageError.missingKey
            }
            try removePersistedPayloads(includeLearning: false)
            defaults.set(schemaVersion, forKey: schemaKey)
            defaults.removeObject(forKey: "secureStorageBootstrapError")
        } catch {
            defaults.set(error.localizedDescription, forKey: "secureStorageBootstrapError")
            throw error
        }
    }

    private static func removePersistedPayloads(includeLearning: Bool) throws {
        guard let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw SecureStorageError.storageLocationUnavailable
        }

        let fileManager = FileManager.default
        let copi = base.appendingPathComponent("Copi", isDirectory: true)
        var directoryNames = [
            "History",
            "Favorites",
            "SecureHistory-v2",
            "SecureFavorites-v2",
        ]
        if includeLearning {
            directoryNames.append("Learning")
        }
        for name in directoryNames {
            let directory = copi.appendingPathComponent(name, isDirectory: true)
            guard fileManager.fileExists(atPath: directory.path) else { continue }
            try fileManager.removeItem(at: directory)
        }

        let defaults = UserDefaults.standard
        for key in [
            "clipboardHistory",
            "favoriteCategories",
            "favorites",
            "secureClipboardHistoryV2",
            "secureFavoriteCategoriesV2",
        ] {
            defaults.removeObject(forKey: key)
        }
    }
}
