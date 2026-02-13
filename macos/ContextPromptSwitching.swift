import AppKit
import CoreGraphics
import Foundation

enum ContextBrowserType: String, Codable, CaseIterable, Identifiable {
    case safari
    case chrome
    case edge
    case arc
    case firefox
    case other

    var id: String { rawValue }
}

enum ContextConfidence: String, Codable, CaseIterable, Identifiable {
    case high
    case medium
    case low

    var id: String { rawValue }
}

enum ContextSnapshotSource: String, Codable, CaseIterable, Identifiable {
    case appOnly
    case windowTitle
    case `extension`
    case applescript
    case accessibility

    var id: String { rawValue }
}

struct ContextSnapshot: Codable, Equatable {
    var timestamp: Date
    var frontmostAppBundleId: String
    var frontmostAppName: String
    var browserType: ContextBrowserType?
    var activeDomain: String?
    var activeUrl: String?
    var windowTitle: String?
    var confidence: ContextConfidence
    var source: ContextSnapshotSource
}

enum RoutingMatchType: String, Codable, CaseIterable, Identifiable {
    case domainExact
    case domainSuffix
    case appBundleId
    case windowTitleRegex

    var id: String { rawValue }
}

struct RoutingRule: Codable, Identifiable, Equatable {
    var id: String
    var priority: Int
    var matchType: RoutingMatchType
    var matchValue: String
    var targetPresetId: String
    var enabled: Bool

    init(
        id: String = UUID().uuidString,
        priority: Int,
        matchType: RoutingMatchType,
        matchValue: String,
        targetPresetId: String,
        enabled: Bool = true
    ) {
        self.id = id
        self.priority = priority
        self.matchType = matchType
        self.matchValue = matchValue
        self.targetPresetId = targetPresetId
        self.enabled = enabled
    }
}

struct ContextPromptRoutingDecision {
    let presetId: String
    let matchedRule: RoutingRule?
}

enum ContextPromptRouter {
    static func decide(
        snapshot: ContextSnapshot,
        rules: [RoutingRule],
        defaultPresetId: String
    ) -> ContextPromptRoutingDecision {
        let orderedRules = rules
            .filter(\.enabled)
            .sorted { lhs, rhs in
                let leftRank = matchTypeRank(lhs.matchType)
                let rightRank = matchTypeRank(rhs.matchType)
                if leftRank != rightRank {
                    return leftRank < rightRank
                }
                if lhs.priority != rhs.priority {
                    return lhs.priority < rhs.priority
                }
                return lhs.id < rhs.id
            }

        for rule in orderedRules where matches(rule: rule, snapshot: snapshot) {
            return ContextPromptRoutingDecision(presetId: rule.targetPresetId, matchedRule: rule)
        }

        return ContextPromptRoutingDecision(presetId: defaultPresetId, matchedRule: nil)
    }

    private static func matchTypeRank(_ type: RoutingMatchType) -> Int {
        switch type {
        case .domainExact:
            return 0
        case .domainSuffix:
            return 1
        case .appBundleId:
            return 2
        case .windowTitleRegex:
            return 3
        }
    }

    private static func matches(rule: RoutingRule, snapshot: ContextSnapshot) -> Bool {
        let value = rule.matchValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return false }

        switch rule.matchType {
        case .domainExact:
            guard let domain = snapshot.activeDomain?.lowercased() else { return false }
            return domain == value.lowercased()
        case .domainSuffix:
            guard let domain = snapshot.activeDomain?.lowercased() else { return false }
            let normalizedValue = value.lowercased()
            return domain == normalizedValue || domain.hasSuffix(".\(normalizedValue)")
        case .appBundleId:
            return snapshot.frontmostAppBundleId.caseInsensitiveCompare(value) == .orderedSame
        case .windowTitleRegex:
            guard let title = snapshot.windowTitle, !title.isEmpty else { return false }
            guard let regex = try? NSRegularExpression(pattern: value, options: [.caseInsensitive]) else {
                return false
            }
            let range = NSRange(location: 0, length: title.utf16.count)
            return regex.firstMatch(in: title, options: [], range: range) != nil
        }
    }
}

struct ContextPresetResolution {
    let presetId: String
    let matchedRule: RoutingRule?
    let didAutoSwitch: Bool
}

struct DictationResolvedPreset {
    let id: String
    let title: String
    let dictationPrompt: String
}

struct DictationContextSelection {
    let snapshot: ContextSnapshot
    let preset: DictationResolvedPreset
    let matchedRule: RoutingRule?
}

enum ContextPresetResolver {
    static func resolve(
        mode: WorkflowMode,
        autoSwitchEnabled: Bool,
        lockCurrentPreset: Bool,
        currentPresetId: String,
        defaultPresetId: String,
        rules: [RoutingRule],
        snapshot: ContextSnapshot
    ) -> ContextPresetResolution {
        guard mode == .dictate else {
            return ContextPresetResolution(presetId: currentPresetId, matchedRule: nil, didAutoSwitch: false)
        }
        guard autoSwitchEnabled else {
            return ContextPresetResolution(presetId: currentPresetId, matchedRule: nil, didAutoSwitch: false)
        }
        guard !lockCurrentPreset else {
            return ContextPresetResolution(presetId: currentPresetId, matchedRule: nil, didAutoSwitch: false)
        }

        let decision = ContextPromptRouter.decide(
            snapshot: snapshot,
            rules: rules,
            defaultPresetId: defaultPresetId
        )
        return ContextPresetResolution(
            presetId: decision.presetId,
            matchedRule: decision.matchedRule,
            didAutoSwitch: true
        )
    }
}

enum ContextDetector {
    @MainActor
    static func getSnapshot() -> ContextSnapshot {
        ContextSnapshotService.shared.snapshotNow()
    }
}

@MainActor
final class ContextSnapshotService {
    static let shared = ContextSnapshotService()

    private struct BrowserURLHint {
        let bundleId: String
        let url: String?
        let domain: String?
        let source: ContextSnapshotSource
        let updatedAt: Date
    }

    private struct BrowserContextInboxPayload: Decodable {
        let bundleId: String
        let activeURL: String?
        let activeDomain: String?
        let source: ContextSnapshotSource

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)

            let bundleIdValue = (
                try container.decodeIfPresent(String.self, forKey: .bundleId)
                ?? container.decodeIfPresent(String.self, forKey: .bundle_id)
                ?? ""
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            bundleId = bundleIdValue

            let activeURLValue = (
                try container.decodeIfPresent(String.self, forKey: .activeURL)
                ?? container.decodeIfPresent(String.self, forKey: .active_url)
                ?? container.decodeIfPresent(String.self, forKey: .url)
            )?.trimmingCharacters(in: .whitespacesAndNewlines)
            activeURL = activeURLValue?.isEmpty == true ? nil : activeURLValue

            let activeDomainValue = (
                try container.decodeIfPresent(String.self, forKey: .activeDomain)
                ?? container.decodeIfPresent(String.self, forKey: .active_domain)
                ?? container.decodeIfPresent(String.self, forKey: .domain)
            )?.trimmingCharacters(in: .whitespacesAndNewlines)
            activeDomain = activeDomainValue?.isEmpty == true ? nil : activeDomainValue

            let sourceRaw = (
                try container.decodeIfPresent(String.self, forKey: .source)
                ?? ContextSnapshotSource.extension.rawValue
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            source = ContextSnapshotSource(rawValue: sourceRaw) ?? .extension
        }

        private enum CodingKeys: String, CodingKey {
            case bundleId
            case bundle_id
            case activeURL
            case active_url
            case url
            case activeDomain
            case active_domain
            case domain
            case source
        }
    }

    private let workspace = NSWorkspace.shared
    private var activationObserver: NSObjectProtocol?
    private var latestSnapshot: ContextSnapshot?
    private var browserURLHint: BrowserURLHint?
    private var lastImportedBrowserContextInboxModifiedAt: Date?

    var onSnapshotUpdated: ((ContextSnapshot) -> Void)?

    private init() {}

    func start() {
        guard activationObserver == nil else { return }
        activationObserver = workspace.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                let snapshot = self.captureSnapshot()
                self.latestSnapshot = snapshot
                self.onSnapshotUpdated?(snapshot)
            }
        }

        let initial = captureSnapshot()
        latestSnapshot = initial
        onSnapshotUpdated?(initial)
    }

    func stop() {
        if let activationObserver {
            workspace.notificationCenter.removeObserver(activationObserver)
        }
        activationObserver = nil
    }

    func snapshotNow() -> ContextSnapshot {
        let snapshot = captureSnapshot()
        latestSnapshot = snapshot
        onSnapshotUpdated?(snapshot)
        return snapshot
    }

    func cachedSnapshot() -> ContextSnapshot {
        if let latestSnapshot {
            return latestSnapshot
        }
        return snapshotNow()
    }

    func updateBrowserContextFromExternalChannel(
        bundleId: String,
        activeURL: String,
        source: ContextSnapshotSource = .extension
    ) {
        let cleanedURL = activeURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedURL.isEmpty else { return }
        let domain = Self.extractDomain(from: cleanedURL)
        browserURLHint = BrowserURLHint(
            bundleId: bundleId,
            url: cleanedURL,
            domain: domain,
            source: source,
            updatedAt: Date()
        )
    }

    func updateBrowserContextDomainFromExternalChannel(
        bundleId: String,
        activeDomain: String,
        source: ContextSnapshotSource = .extension
    ) {
        let cleanedDomain = activeDomain
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !cleanedDomain.isEmpty else { return }
        browserURLHint = BrowserURLHint(
            bundleId: bundleId,
            url: nil,
            domain: cleanedDomain,
            source: source,
            updatedAt: Date()
        )
    }

    private func captureSnapshot() -> ContextSnapshot {
        importBrowserContextHintFromInboxIfNeeded()

        let app = workspace.frontmostApplication
        let bundleId = app?.bundleIdentifier ?? ""
        let appName = app?.localizedName ?? "Unknown"
        let browser = browserType(forBundleID: bundleId)

        var windowTitle: String?
        var activeURL: String?
        var activeDomain: String?
        var source: ContextSnapshotSource = .appOnly
        var confidence: ContextConfidence = .low

        if let hint = browserURLHint, hint.bundleId == bundleId {
            let age = Date().timeIntervalSince(hint.updatedAt)
            if age <= 120 {
                activeURL = hint.url
                activeDomain = hint.domain
                source = hint.source
                confidence = .high
            }
        }

        if activeDomain == nil, let browser, let appleScriptURL = activeBrowserURLViaAppleScript(browser: browser) {
            activeURL = appleScriptURL
            activeDomain = Self.extractDomain(from: appleScriptURL)
            source = .applescript
            confidence = activeDomain == nil ? .low : .medium
        }

        if activeDomain == nil, let processIdentifier = app?.processIdentifier {
            windowTitle = frontWindowTitle(for: processIdentifier)
            if let windowTitle, !windowTitle.isEmpty {
                if let inferred = Self.inferDomain(fromWindowTitle: windowTitle) {
                    activeDomain = inferred
                    source = .windowTitle
                    confidence = .medium
                } else {
                    source = .windowTitle
                    confidence = .low
                }
            }
        }

        return ContextSnapshot(
            timestamp: Date(),
            frontmostAppBundleId: bundleId,
            frontmostAppName: appName,
            browserType: browser,
            activeDomain: activeDomain,
            activeUrl: activeURL,
            windowTitle: windowTitle,
            confidence: confidence,
            source: source
        )
    }

    private func importBrowserContextHintFromInboxIfNeeded() {
        let inboxURL = Self.browserContextInboxURL
        let attributes = try? FileManager.default.attributesOfItem(atPath: inboxURL.path)
        guard let modifiedAt = attributes?[.modificationDate] as? Date else { return }
        if let last = lastImportedBrowserContextInboxModifiedAt, modifiedAt <= last {
            return
        }
        lastImportedBrowserContextInboxModifiedAt = modifiedAt

        guard let data = try? Data(contentsOf: inboxURL),
              let payload = try? JSONDecoder().decode(BrowserContextInboxPayload.self, from: data)
        else {
            return
        }

        guard !payload.bundleId.isEmpty else { return }
        if let activeURL = payload.activeURL {
            updateBrowserContextFromExternalChannel(
                bundleId: payload.bundleId,
                activeURL: activeURL,
                source: payload.source
            )
            return
        }
        if let activeDomain = payload.activeDomain {
            updateBrowserContextDomainFromExternalChannel(
                bundleId: payload.bundleId,
                activeDomain: activeDomain,
                source: payload.source
            )
        }
    }

    private static var browserContextInboxURL: URL {
        appSupportDirectoryURL.appendingPathComponent("browser-context-hint.json", isDirectory: false)
    }

    private static var appSupportDirectoryURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("GhostType", isDirectory: true)
    }

    private func frontWindowTitle(for pid: pid_t) -> String? {
        let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]]
        guard let windowList else { return nil }

        for window in windowList {
            guard let ownerPID = window[kCGWindowOwnerPID as String] as? pid_t, ownerPID == pid else {
                continue
            }
            let layer = (window[kCGWindowLayer as String] as? Int) ?? 0
            guard layer == 0 else { continue }
            if let name = window[kCGWindowName as String] as? String {
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }
        return nil
    }

    private func browserType(forBundleID bundleId: String) -> ContextBrowserType? {
        switch bundleId {
        case "com.apple.Safari":
            return .safari
        case "com.google.Chrome":
            return .chrome
        case "com.microsoft.edgemac":
            return .edge
        case "company.thebrowser.Browser":
            return .arc
        case "org.mozilla.firefox":
            return .firefox
        default:
            return nil
        }
    }

    private func activeBrowserURLViaAppleScript(browser: ContextBrowserType) -> String? {
        let script: String
        switch browser {
        case .safari:
            script = """
            tell application "Safari"
                if (count of windows) = 0 then return ""
                try
                    return URL of current tab of front window
                on error
                    return ""
                end try
            end tell
            """
        case .chrome:
            script = """
            tell application "Google Chrome"
                if (count of windows) = 0 then return ""
                try
                    return URL of active tab of front window
                on error
                    return ""
                end try
            end tell
            """
        case .edge:
            script = """
            tell application "Microsoft Edge"
                if (count of windows) = 0 then return ""
                try
                    return URL of active tab of front window
                on error
                    return ""
                end try
            end tell
            """
        case .arc:
            script = """
            tell application "Arc"
                if (count of windows) = 0 then return ""
                try
                    return URL of active tab of front window
                on error
                    return ""
                end try
            end tell
            """
        case .firefox, .other:
            return nil
        }

        guard let url = runAppleScript(script) else { return nil }
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func runAppleScript(_ script: String) -> String? {
        guard let appleScript = NSAppleScript(source: script) else { return nil }
        var executionError: NSDictionary?
        let descriptor = appleScript.executeAndReturnError(&executionError)
        guard executionError == nil else { return nil }
        return descriptor.stringValue
    }

    private static func inferDomain(fromWindowTitle title: String) -> String? {
        let lower = title.lowercased()
        if lower.contains("chat.openai.com") || lower.contains("chatgpt") {
            return "chat.openai.com"
        }
        if lower.contains("gemini.google.com") || lower.contains("google gemini") || lower.contains("gemini") {
            return "gemini.google.com"
        }

        if let explicitURL = extractFirstURL(from: title),
           let domain = extractDomain(from: explicitURL) {
            return domain
        }

        return extractDomain(from: title)
    }

    private static func extractFirstURL(from text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"https?://[^\s]+"#, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(location: 0, length: text.utf16.count)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              let matchedRange = Range(match.range, in: text) else {
            return nil
        }
        return String(text[matchedRange])
    }

    private static func extractDomain(from text: String) -> String? {
        let candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return nil }

        if let components = URLComponents(string: candidate),
           let host = components.host?.lowercased(),
           !host.isEmpty {
            return host
        }

        if let url = URL(string: candidate),
           let host = url.host?.lowercased(),
           !host.isEmpty {
            return host
        }

        guard let regex = try? NSRegularExpression(pattern: #"([a-zA-Z0-9-]+\.)+[a-zA-Z]{2,}"#, options: []) else {
            return nil
        }
        let range = NSRange(location: 0, length: candidate.utf16.count)
        guard let match = regex.firstMatch(in: candidate, options: [], range: range),
              let matchedRange = Range(match.range, in: candidate) else {
            return nil
        }
        return String(candidate[matchedRange]).lowercased()
    }
}
