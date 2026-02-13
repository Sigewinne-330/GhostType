import Foundation
import Security

enum APISecretKey: String, CaseIterable {
    case asrOpenAI = "asr.openai.api_key"
    case asrDeepgram = "asr.deepgram.api_key"
    case asrAssemblyAI = "asr.assemblyai.api_key"
    case asrGroq = "asr.groq.api_key"
    case llmOpenAI = "llm.openai.api_key"
    case llmOpenAICompatible = "llm.openai_compatible.api_key"
    case llmAzureOpenAI = "llm.azure_openai.api_key"
    case llmAnthropic = "llm.anthropic.api_key"
    case llmGemini = "llm.gemini.api_key"
    case llmDeepSeek = "llm.deepseek.api_key"
    case llmGroq = "llm.groq.api_key"

    var displayName: String {
        switch self {
        case .asrOpenAI: return "ASR OpenAI"
        case .asrDeepgram: return "ASR Deepgram"
        case .asrAssemblyAI: return "ASR AssemblyAI"
        case .asrGroq: return "ASR Groq"
        case .llmOpenAI: return "LLM OpenAI"
        case .llmOpenAICompatible: return "LLM OpenAI Compatible"
        case .llmAzureOpenAI: return "LLM Azure OpenAI"
        case .llmAnthropic: return "LLM Anthropic"
        case .llmGemini: return "LLM Gemini"
        case .llmDeepSeek: return "LLM DeepSeek"
        case .llmGroq: return "LLM Groq"
        }
    }
}

enum KeychainReadPolicy {
    case allowUserInteraction
    case noUserInteraction

    var secAuthenticationUIValue: CFString {
        switch self {
        case .allowUserInteraction:
            return kSecUseAuthenticationUIAllow
        case .noUserInteraction:
            return kSecUseAuthenticationUIFail
        }
    }
}

enum KeychainError: LocalizedError {
    case encodingFailed
    case decodingFailed
    case unexpectedStatus(OSStatus, String)

    var errorDescription: String? {
        switch self {
        case .encodingFailed:
            return "Unable to encode secret."
        case .decodingFailed:
            return "Unable to decode secret."
        case .unexpectedStatus(let status, let context):
            let statusText = KeychainManager.statusDescription(for: status)
            return "\(context) failed (\(status): \(statusText))."
        }
    }
}

struct KeychainRuntimeIdentity {
    let bundleIdentifier: String
    let executablePath: String
    let signingIdentifier: String?
    let teamIdentifier: String?
    let cdhash: String?
    let sandboxEnabled: Bool
    let keychainAccessGroups: [String]

    var summaryText: String {
        var components: [String] = []
        components.append("bundle_id=\(bundleIdentifier)")
        components.append("exec=\(executablePath)")
        components.append("signing_id=\(signingIdentifier ?? "unknown")")
        components.append("team_id=\(teamIdentifier ?? "unknown")")
        components.append("cdhash=\(cdhash ?? "unknown")")
        components.append("sandbox=\(sandboxEnabled)")
        components.append("access_groups=\(keychainAccessGroups.joined(separator: ","))")
        return components.joined(separator: " ")
    }
}

struct KeychainRepairReport {
    let checkedAt: Date
    let runtimeIdentity: KeychainRuntimeIdentity
    var foundCurrentItems: Int = 0
    var migratedLegacyItems: Int = 0
    var rebuiltItems: Int = 0
    var interactionRequiredKeys: [APISecretKey] = []
    var failures: [String] = []
    var guidance: [String] = []

    var requiresAttention: Bool {
        !interactionRequiredKeys.isEmpty || !failures.isEmpty
    }

    var summaryText: String {
        let keys = interactionRequiredKeys.map(\.displayName).joined(separator: ", ")
        let interaction = interactionRequiredKeys.isEmpty ? "none" : keys
        return "checked=\(APISecretKey.allCases.count) current=\(foundCurrentItems) migrated=\(migratedLegacyItems) rebuilt=\(rebuiltItems) interaction_required=\(interaction) failures=\(failures.count)"
    }
}

final class KeychainManager: KeychainStoring {
    static let shared = KeychainManager()

    static let diagnosticsEnabledDefaultsKey = "GhostType.keychainDiagnosticsEnabled"

    private let service = "com.codeandchill.ghosttype"
    private let accountDefault = "default"
    private let labelPrefix = "GhostType Credential"
    private let queue = DispatchQueue(label: "ghosttype.keychain.queue")
    private let legacyServices = [
        "com.codeandchill.localtypeless",
        "com.codeandchill.local-typeless",
        "com.codeandchill.typeless",
        "com.codeandchill.ghosttype.beta",
        "now.typeless.desktop",
    ]
    private var latestReportCache: KeychainRepairReport?

    private init() {}

    func save(_ value: String, for key: APISecretKey) throws {
        try setSecret(value, for: key)
    }

    func read(_ key: APISecretKey) -> String? {
        try? getSecret(for: key, policy: .noUserInteraction)
    }

    func delete(_ key: APISecretKey) throws {
        try deleteSecret(for: key)
    }

    func getSecret(forRef keyRef: String, policy: KeychainReadPolicy = .allowUserInteraction) throws -> String? {
        try queue.sync {
            let data = try readData(service: service, account: accountName(forRef: keyRef), policy: policy)
            guard let data else { return nil }
            guard let string = String(data: data, encoding: .utf8) else {
                throw KeychainError.decodingFailed
            }
            return string
        }
    }

    func setSecret(_ value: String, forRef keyRef: String) throws {
        try queue.sync {
            guard let data = value.data(using: .utf8) else {
                throw KeychainError.encodingFailed
            }

            let account = accountName(forRef: keyRef)
            let label = label(forRef: keyRef)
            let query = baseQuery(service: service, account: account)
            let updateAttributes: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
                kSecAttrLabel as String: label,
            ]

            let status = SecItemUpdate(query as CFDictionary, updateAttributes as CFDictionary)
            if status == errSecSuccess {
                logDiagnostic("Updated keychain secret for ref \(keyRef).")
                return
            }
            if status != errSecItemNotFound {
                throw KeychainError.unexpectedStatus(status, "SecItemUpdate(\(keyRef))")
            }

            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            addQuery[kSecAttrLabel as String] = label
            if let access = trustedAccess(label: label) {
                addQuery[kSecAttrAccess as String] = access
            }

            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.unexpectedStatus(addStatus, "SecItemAdd(\(keyRef))")
            }
            logDiagnostic("Added keychain secret for ref \(keyRef).")
        }
    }

    func deleteSecret(forRef keyRef: String) throws {
        try queue.sync {
            let account = accountName(forRef: keyRef)
            let status = SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeychainError.unexpectedStatus(status, "SecItemDelete(\(keyRef))")
            }
            logDiagnostic("Deleted keychain secret for ref \(keyRef). status=\(status)")
        }
    }

    func getSecret(for key: APISecretKey, policy: KeychainReadPolicy = .allowUserInteraction) throws -> String? {
        try getSecret(forRef: key.rawValue, policy: policy)
    }

    func setSecret(_ value: String, for key: APISecretKey) throws {
        try setSecret(value, forRef: key.rawValue)
        logDiagnostic("Saved keychain secret for \(key.displayName).")
    }

    func deleteSecret(for key: APISecretKey) throws {
        try deleteSecret(forRef: key.rawValue)
        logDiagnostic("Deleted keychain secret for \(key.displayName).")
    }

    func deleteAllSecrets() -> KeychainRepairReport {
        queue.sync {
            var report = KeychainRepairReport(checkedAt: Date(), runtimeIdentity: currentRuntimeIdentity())
            for key in APISecretKey.allCases {
                do {
                    try deleteSecretInternal(for: key)
                } catch {
                    report.failures.append("Delete \(key.displayName): \(error.localizedDescription)")
                }
            }
            setLatestReport(report)
            return report
        }
    }

    func runSelfCheck() -> KeychainRepairReport {
        queue.sync {
            var report = KeychainRepairReport(checkedAt: Date(), runtimeIdentity: currentRuntimeIdentity())

            for key in APISecretKey.allCases {
                let account = accountName(for: key)
                let status = readStatusOnly(service: service, account: account, policy: .noUserInteraction)
                switch status {
                case errSecSuccess:
                    report.foundCurrentItems += 1
                case errSecItemNotFound:
                    if hasLegacyCandidate(for: key) {
                        report.guidance.append("Legacy key candidate found for \(key.displayName). Run Keychain Repair.")
                    }
                case errSecInteractionNotAllowed, errSecAuthFailed:
                    report.interactionRequiredKeys.append(key)
                    report.guidance.append("Access to \(key.displayName) requires keychain interaction. Run Keychain Repair.")
                default:
                    report.failures.append("Self-check \(key.displayName): \(Self.statusDescription(for: status)) (\(status))")
                }
            }

            if report.runtimeIdentity.teamIdentifier == nil || report.runtimeIdentity.teamIdentifier?.isEmpty == true {
                report.guidance.append("Code-signing Team ID is missing. Use a stable signing identity in Debug and Release.")
            }
            if report.runtimeIdentity.sandboxEnabled && report.runtimeIdentity.keychainAccessGroups.isEmpty {
                report.guidance.append("App Sandbox is enabled but Keychain Access Groups are missing. Enable Keychain Sharing with a stable access group.")
            }

            if report.requiresAttention {
                report.guidance.append("Manual fallback: open Keychain Access, search \(service), remove stale entries, then re-enter keys.")
            }

            logDiagnostic("Keychain self-check report: \(report.summaryText)")
            setLatestReport(report)
            return report
        }
    }

    func migrateLegacyIfNeeded(allowUserInteraction: Bool = false) -> KeychainRepairReport {
        allowUserInteraction ? runInteractiveRepair() : runSelfCheck()
    }

    func runInteractiveRepair() -> KeychainRepairReport {
        queue.sync {
            var report = KeychainRepairReport(checkedAt: Date(), runtimeIdentity: currentRuntimeIdentity())

            for key in APISecretKey.allCases {
                let account = accountName(for: key)

                if migrateLegacyIfPresent(for: key, account: account, report: &report) {
                    continue
                }

                do {
                    guard let value = try readData(service: service, account: account, policy: .allowUserInteraction) else {
                        continue
                    }
                    report.foundCurrentItems += 1
                    try rebuildCurrentItem(for: key, value: value)
                    report.rebuiltItems += 1
                } catch {
                    report.failures.append("Repair \(key.displayName): \(error.localizedDescription)")
                }
            }

            if !report.interactionRequiredKeys.isEmpty {
                report.guidance.append("Some keys still need manual confirmation. Choose Always Allow when prompted.")
            }
            if report.requiresAttention {
                report.guidance.append("If prompts persist: open Keychain Access, search \(service), delete old entries, then save keys again.")
            }

            logDiagnostic("Keychain interactive repair report: \(report.summaryText)")
            setLatestReport(report)
            return report
        }
    }

    func latestRepairReport() -> KeychainRepairReport? {
        queue.sync { latestReportCache }
    }

    func savedSecretCount() -> Int {
        queue.sync {
            APISecretKey.allCases.reduce(into: 0) { result, key in
                let status = readStatusOnly(
                    service: service,
                    account: accountName(for: key),
                    policy: .noUserInteraction
                )
                if status == errSecSuccess {
                    result += 1
                }
            }
        }
    }

    private func setLatestReport(_ report: KeychainRepairReport) {
        latestReportCache = report
    }

    private func hasLegacyCandidate(for key: APISecretKey) -> Bool {
        let account = accountName(for: key)
        for legacyService in legacyServices {
            let status = readStatusOnly(service: legacyService, account: account, policy: .noUserInteraction)
            if status == errSecSuccess || status == errSecInteractionNotAllowed || status == errSecAuthFailed {
                return true
            }
        }
        return false
    }

    @discardableResult
    private func migrateLegacyIfPresent(for key: APISecretKey, account: String, report: inout KeychainRepairReport) -> Bool {
        for legacyService in legacyServices {
            do {
                guard let legacyValue = try readData(service: legacyService, account: account, policy: .allowUserInteraction) else {
                    continue
                }
                try setData(legacyValue, service: service, account: account, key: key)
                try deleteData(service: legacyService, account: account)
                report.migratedLegacyItems += 1
                report.rebuiltItems += 1
                logDiagnostic("Migrated \(key.displayName) from legacy service \(legacyService).")
                return true
            } catch {
                report.failures.append("Migrate \(key.displayName) from \(legacyService): \(error.localizedDescription)")
            }
        }
        return false
    }

    private func rebuildCurrentItem(for key: APISecretKey, value: Data) throws {
        let account = accountName(for: key)
        try deleteData(service: service, account: account)
        try setData(value, service: service, account: account, key: key)
    }

    private func setData(_ value: Data, service: String, account: String, key: APISecretKey) throws {
        let query = baseQuery(service: service, account: account)
        let updateAttributes: [String: Any] = [
            kSecValueData as String: value,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecAttrLabel as String: label(for: key),
        ]

        let status = SecItemUpdate(query as CFDictionary, updateAttributes as CFDictionary)
        if status == errSecSuccess {
            return
        }
        if status != errSecItemNotFound {
            throw KeychainError.unexpectedStatus(status, "SecItemUpdate(\(service):\(account))")
        }

        var addQuery = query
        addQuery[kSecValueData as String] = value
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        addQuery[kSecAttrLabel as String] = label(for: key)
        if let access = trustedAccess(label: label(for: key)) {
            addQuery[kSecAttrAccess as String] = access
        }
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError.unexpectedStatus(addStatus, "SecItemAdd(\(service):\(account))")
        }
    }

    private func deleteSecretInternal(for key: APISecretKey) throws {
        let status = SecItemDelete(baseQuery(service: service, account: accountName(for: key)) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status, "SecItemDelete(\(key.rawValue))")
        }
    }

    private func deleteData(service: String, account: String) throws {
        let status = SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status, "SecItemDelete(\(service):\(account))")
        }
    }

    private func readData(service: String, account: String, policy: KeychainReadPolicy) throws -> Data? {
        var query = baseQuery(service: service, account: account)
        query[kSecUseAuthenticationUI as String] = policy.secAuthenticationUIValue
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status, "SecItemCopyMatching(\(service):\(account))")
        }
        guard let data = item as? Data else {
            throw KeychainError.decodingFailed
        }
        return data
    }

    private func readStatusOnly(service: String, account: String, policy: KeychainReadPolicy) -> OSStatus {
        var query = baseQuery(service: service, account: account)
        query[kSecUseAuthenticationUI as String] = policy.secAuthenticationUIValue
        query[kSecReturnAttributes as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &item)
    }

    private func trustedAccess(label: String) -> SecAccess? {
        var trustedApplication: SecTrustedApplication?
        let trustedStatus = SecTrustedApplicationCreateFromPath(nil, &trustedApplication)
        guard trustedStatus == errSecSuccess, let trustedApplication else {
            logDiagnostic("SecTrustedApplicationCreateFromPath failed: \(trustedStatus) \(Self.statusDescription(for: trustedStatus))")
            return nil
        }

        var access: SecAccess?
        let trustedList = [trustedApplication] as CFArray
        let accessStatus = SecAccessCreate(label as CFString, trustedList, &access)
        guard accessStatus == errSecSuccess else {
            logDiagnostic("SecAccessCreate failed: \(accessStatus) \(Self.statusDescription(for: accessStatus))")
            return nil
        }
        return access
    }

    private func baseQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
    }

    private func accountName(for key: APISecretKey) -> String {
        accountName(forRef: key.rawValue)
    }

    private func accountName(forRef keyRef: String) -> String {
        let trimmed = keyRef.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return accountDefault
        }
        return trimmed
    }

    private func label(for key: APISecretKey) -> String {
        label(forRef: key.rawValue)
    }

    private func label(forRef keyRef: String) -> String {
        "\(labelPrefix) (\(accountName(forRef: keyRef)))"
    }

    private func currentRuntimeIdentity() -> KeychainRuntimeIdentity {
        let bundleID = Bundle.main.bundleIdentifier ?? "unknown.bundle"
        let executablePath = Bundle.main.executableURL?.path ?? "unknown.executable"
        var signingIdentifier: String?
        var teamIdentifier: String?
        var cdhash: String?
        var sandboxEnabled = false
        var keychainAccessGroups: [String] = []

        if let executableURL = Bundle.main.executableURL {
            var staticCode: SecStaticCode?
            let createStatus = SecStaticCodeCreateWithPath(executableURL as CFURL, [], &staticCode)
            guard createStatus == errSecSuccess, let staticCode else {
                return KeychainRuntimeIdentity(
                    bundleIdentifier: bundleID,
                    executablePath: executablePath,
                    signingIdentifier: signingIdentifier,
                    teamIdentifier: teamIdentifier,
                    cdhash: cdhash,
                    sandboxEnabled: sandboxEnabled,
                    keychainAccessGroups: keychainAccessGroups
                )
            }
            var infoRef: CFDictionary?
            if SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &infoRef) == errSecSuccess,
               let info = infoRef as? [String: Any] {
                signingIdentifier = info[kSecCodeInfoIdentifier as String] as? String
                teamIdentifier = info[kSecCodeInfoTeamIdentifier as String] as? String
                if let hashData = info[kSecCodeInfoUnique as String] as? Data {
                    cdhash = hashData.map { String(format: "%02x", $0) }.joined()
                }
                if let entitlements = info[kSecCodeInfoEntitlementsDict as String] as? [String: Any] {
                    sandboxEnabled = (entitlements["com.apple.security.app-sandbox"] as? Bool) ?? false
                    keychainAccessGroups = (entitlements["keychain-access-groups"] as? [String]) ?? []
                }
            }
        }

        return KeychainRuntimeIdentity(
            bundleIdentifier: bundleID,
            executablePath: executablePath,
            signingIdentifier: signingIdentifier,
            teamIdentifier: teamIdentifier,
            cdhash: cdhash,
            sandboxEnabled: sandboxEnabled,
            keychainAccessGroups: keychainAccessGroups
        )
    }

    private var diagnosticsEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.diagnosticsEnabledDefaultsKey)
    }

    private func logDiagnostic(_ message: String) {
        guard diagnosticsEnabled else { return }
        AppLogger.shared.log("[Keychain] \(message)", type: .debug)
    }

    static func statusDescription(for status: OSStatus) -> String {
        if let message = SecCopyErrorMessageString(status, nil) as String? {
            return message
        }
        switch status {
        case errSecInteractionNotAllowed:
            return "Interaction not allowed (UI required or keychain locked)"
        case errSecAuthFailed:
            return "Authentication failed"
        case errSecItemNotFound:
            return "Item not found"
        default:
            return "Unknown status"
        }
    }
}
