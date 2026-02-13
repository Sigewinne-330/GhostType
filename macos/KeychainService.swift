import Foundation

enum CredentialPresenceHint: String {
    case present
    case missing
    case unknown
}

protocol KeychainStoring {
    func getSecret(forRef keyRef: String, policy: KeychainReadPolicy) throws -> String?
    func setSecret(_ value: String, forRef keyRef: String) throws
    func deleteSecret(forRef keyRef: String) throws
    func getSecret(for key: APISecretKey, policy: KeychainReadPolicy) throws -> String?
    func setSecret(_ value: String, for key: APISecretKey) throws
    func deleteSecret(for key: APISecretKey) throws
    func deleteAllSecrets() -> KeychainRepairReport
    func runSelfCheck() -> KeychainRepairReport
    func runInteractiveRepair() -> KeychainRepairReport
    func savedSecretCount() -> Int
}

struct KeychainService: KeychainStoring {
    private static let presenceHintPrefix = "GhostType.keychain.presence."
    private static let defaults = UserDefaults.standard

    static let live = KeychainService(store: LocalFileSecretStore.shared)
    static let dryRun = KeychainService(store: NoopKeychainService())

    let store: KeychainStoring

    init(store: KeychainStoring = LocalFileSecretStore.shared) {
        self.store = store
    }

    static func defaultService() -> KeychainService {
        let environment = ProcessInfo.processInfo.environment["GHOSTTYPE_KEYCHAIN_DRY_RUN"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if environment == "1" || environment == "true" {
            return .dryRun
        }
        if ProcessInfo.processInfo.arguments.contains("--keychain-dry-run") {
            return .dryRun
        }
        return .live
    }

    func getSecret(forRef keyRef: String, policy: KeychainReadPolicy = .allowUserInteraction) throws -> String? {
        try store.getSecret(forRef: keyRef, policy: policy)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func setSecret(_ value: String, forRef keyRef: String) throws {
        try store.setSecret(value, forRef: keyRef)
    }

    func deleteSecret(forRef keyRef: String) throws {
        try store.deleteSecret(forRef: keyRef)
    }

    func getSecret(for key: APISecretKey, policy: KeychainReadPolicy = .allowUserInteraction) throws -> String? {
        let value = try store.getSecret(for: key, policy: policy)
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            markCredentialMissing(for: key)
            return nil
        }
        markCredentialPresent(for: key)
        return value
    }

    func setSecret(_ value: String, for key: APISecretKey) throws {
        try store.setSecret(value, for: key)
        if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            markCredentialMissing(for: key)
        } else {
            markCredentialPresent(for: key)
        }
    }

    func deleteSecret(for key: APISecretKey) throws {
        try store.deleteSecret(for: key)
        markCredentialMissing(for: key)
    }

    func deleteAllSecrets() -> KeychainRepairReport {
        let report = store.deleteAllSecrets()
        APISecretKey.allCases.forEach { markCredentialMissing(for: $0) }
        return report
    }

    func runSelfCheck() -> KeychainRepairReport {
        store.runSelfCheck()
    }

    func runInteractiveRepair() -> KeychainRepairReport {
        let report = store.runInteractiveRepair()
        updatePresenceHintsFromStore()
        return report
    }

    func savedSecretCount() -> Int {
        store.savedSecretCount()
    }

    func knownSavedSecretCount() -> Int {
        APISecretKey.allCases.reduce(into: 0) { result, key in
            if presenceHint(for: key) == .present {
                result += 1
            }
        }
    }

    func presenceHint(for key: APISecretKey) -> CredentialPresenceHint {
        let keyName = Self.presenceHintPrefix + key.rawValue
        guard let value = Self.defaults.object(forKey: keyName) as? Bool else {
            return .unknown
        }
        return value ? .present : .missing
    }

    func markCredentialPresent(for key: APISecretKey) {
        let keyName = Self.presenceHintPrefix + key.rawValue
        Self.defaults.set(true, forKey: keyName)
    }

    func markCredentialMissing(for key: APISecretKey) {
        let keyName = Self.presenceHintPrefix + key.rawValue
        Self.defaults.set(false, forKey: keyName)
    }

    func clearPresenceHint(for key: APISecretKey) {
        let keyName = Self.presenceHintPrefix + key.rawValue
        Self.defaults.removeObject(forKey: keyName)
    }

    func updatePresenceHintsFromStore() {
        APISecretKey.allCases.forEach { key in
            let status = try? getSecret(for: key, policy: .noUserInteraction)
            let trimmed = status?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if trimmed.isEmpty {
                markCredentialMissing(for: key)
            } else {
                markCredentialPresent(for: key)
            }
        }
    }
}

struct NoopKeychainService: KeychainStoring {
    private final class Storage {
        let queue = DispatchQueue(label: "ghosttype.keychain.noop.queue")
        var values: [String: String] = [:]
    }

    private static let sharedStorage = Storage()
    private let storage: Storage

    init() {
        self.storage = NoopKeychainService.sharedStorage
    }

    private init(storage: Storage) {
        self.storage = storage
    }

    func getSecret(forRef keyRef: String, policy: KeychainReadPolicy) throws -> String? {
        storage.queue.sync {
            storage.values[keyRef]
        }
    }

    func setSecret(_ value: String, forRef keyRef: String) throws {
        storage.queue.sync {
            storage.values[keyRef] = value
        }
    }

    func deleteSecret(forRef keyRef: String) throws {
        storage.queue.sync {
            storage.values.removeValue(forKey: keyRef)
        }
    }

    func getSecret(for key: APISecretKey, policy: KeychainReadPolicy) throws -> String? {
        try getSecret(forRef: key.rawValue, policy: policy)
    }

    func setSecret(_ value: String, for key: APISecretKey) throws {
        try setSecret(value, forRef: key.rawValue)
    }

    func deleteSecret(for key: APISecretKey) throws {
        try deleteSecret(forRef: key.rawValue)
    }

    func deleteAllSecrets() -> KeychainRepairReport {
        storage.queue.sync {
            storage.values.removeAll()
        }
        return makeReport()
    }

    func runSelfCheck() -> KeychainRepairReport {
        var report = makeReport()
        report.guidance.append("Dry-run keychain mode is enabled. No macOS Keychain APIs were called.")
        return report
    }

    func runInteractiveRepair() -> KeychainRepairReport {
        runSelfCheck()
    }

    func savedSecretCount() -> Int {
        storage.queue.sync {
            storage.values.reduce(into: 0) { result, item in
                if !item.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    result += 1
                }
            }
        }
    }

    private func makeReport() -> KeychainRepairReport {
        let bundleID = Bundle.main.bundleIdentifier ?? "unknown.bundle"
        let executablePath = Bundle.main.executableURL?.path ?? "unknown.executable"
        return KeychainRepairReport(
            checkedAt: Date(),
            runtimeIdentity: KeychainRuntimeIdentity(
                bundleIdentifier: bundleID,
                executablePath: executablePath,
                signingIdentifier: nil,
                teamIdentifier: nil,
                cdhash: nil,
                sandboxEnabled: false,
                keychainAccessGroups: []
            )
        )
    }
}

enum AppKeychain {
    private static let lock = NSLock()
    private static var service = KeychainService.defaultService()

    static var shared: KeychainService {
        lock.lock()
        defer { lock.unlock() }
        return service
    }

    static func replace(with newService: KeychainService) {
        lock.lock()
        service = newService
        lock.unlock()
    }
}
