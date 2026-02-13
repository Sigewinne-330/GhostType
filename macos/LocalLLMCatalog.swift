import AppKit
import Combine
import Foundation

// MARK: - Data Types

enum LocalLLMDownloadStatus: String, Codable, Equatable {
    case notDownloaded
    case downloading
    case ready
    case error
}

enum LocalLLMQuantizationMode: String, CaseIterable, Identifiable, Codable {
    case auto = "auto"
    case default_ = "default"
    case eightBit = "8bit"
    case fourBit = "4bit"
    case twoBit = "2bit"
    case fp16 = "fp16"
    case fp32 = "fp32"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: return "Auto"
        case .default_: return "Default"
        case .eightBit: return "8-bit"
        case .fourBit: return "4-bit"
        case .twoBit: return "2-bit"
        case .fp16: return "FP16"
        case .fp32: return "FP32"
        }
    }
}

struct LocalLLMModelEntry: Identifiable, Equatable {
    let id: String           // repoId, e.g. "mlx-community/Qwen2.5-1.5B-Instruct-4bit"
    let repoId: String
    let displayName: String  // short name
    let publisher: String
    let quantization: String // "4bit", "8bit", "fp16", etc.
    let sizeBytesEstimate: Int64?   // estimated disk bytes
    let paramScale: String?  // e.g. "1.5B", "7B"
    let license: String?
    let contextLength: Int?
    let hasChatTemplate: Bool?
    let languages: [String]

    var downloadStatus: LocalLLMDownloadStatus = .notDownloaded
    var downloadProgress: Double = 0  // 0..1
    var downloadedBytes: Int64 = 0
    var downloadError: String?
    var isPinned: Bool = false
    var lastUsedAt: Date?

    var sizeDisplayString: String {
        guard let bytes = sizeBytesEstimate else { return "Unknown size" }
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        let mb = Double(bytes) / 1_048_576
        return String(format: "%.0f MB", mb)
    }

    var quantizationDisplayName: String {
        switch quantization.lowercased() {
        case "4bit", "int4", "q4": return "4-bit"
        case "8bit", "int8", "q8": return "8-bit"
        case "2bit": return "2-bit"
        case "fp16": return "FP16"
        case "fp32": return "FP32"
        case "default": return "Default"
        default: return quantization.isEmpty ? "Default" : quantization
        }
    }

    var paramScaleDisplay: String {
        paramScale ?? ""
    }

    static func from(repoId: String) -> LocalLLMModelEntry {
        let parts = repoId.split(separator: "/", maxSplits: 1)
        let publisher = parts.count == 2 ? String(parts[0]) : "mlx-community"
        let fullName = parts.count == 2 ? String(parts[1]) : repoId
        let quant = Self.extractQuantization(from: fullName)
        let paramScale = Self.extractParamScale(from: fullName)
        let displayName = Self.makeDisplayName(fullName: fullName)
        return LocalLLMModelEntry(
            id: repoId,
            repoId: repoId,
            displayName: displayName,
            publisher: publisher,
            quantization: quant,
            sizeBytesEstimate: nil,
            paramScale: paramScale,
            license: nil,
            contextLength: nil,
            hasChatTemplate: nil,
            languages: []
        )
    }

    static func extractQuantization(from name: String) -> String {
        let lower = name.lowercased()
        let patterns: [(String, String)] = [
            ("-8bit", "8bit"), ("-4bit", "4bit"), ("-2bit", "2bit"),
            ("-fp16", "fp16"), ("-fp32", "fp32"),
            ("-q8", "8bit"), ("-q4", "4bit"), ("-int8", "8bit"), ("-int4", "4bit"),
        ]
        for (suffix, tag) in patterns {
            if lower.hasSuffix(suffix) { return tag }
        }
        return "default"
    }

    static func extractParamScale(from name: String) -> String? {
        // Look for patterns like 0.5B, 1.5B, 3B, 7B, 8B, 9B, 14B, 32B, 70B
        let pattern = #"(\d+\.?\d*)[Bb]"#
        if let range = name.range(of: pattern, options: .regularExpression) {
            return String(name[range]).uppercased()
        }
        return nil
    }

    static func makeDisplayName(fullName: String) -> String {
        // Strip publisher prefix and quantization suffix for a cleaner name
        var name = fullName
        let quantSuffixes = ["-8bit", "-4bit", "-2bit", "-fp16", "-fp32", "-q8", "-q4", "-int8", "-int4"]
        for suffix in quantSuffixes {
            if name.lowercased().hasSuffix(suffix.lowercased()) {
                name = String(name.dropLast(suffix.count))
                break
            }
        }
        return name
    }

    // Model "family key" for matching across quantizations
    var familyKey: String {
        let lower = displayName.lowercased()
        return lower
    }
}

// MARK: - HuggingFace Metadata

struct HFModelInfo: Decodable {
    let id: String
    let author: String?
    let tags: [String]?
    let license: String?
    let siblings: [HFSibling]?
    let cardData: HFCardData?

    struct HFSibling: Decodable {
        let rfilename: String
        let size: Int64?
    }

    struct HFCardData: Decodable {
        let license: String?
        let language: [String]?
        let contextLength: Int?

        enum CodingKeys: String, CodingKey {
            case license
            case language
            case contextLength = "context_length"
        }
    }

    enum CodingKeys: String, CodingKey {
        case id
        case author
        case tags
        case license
        case siblings
        case cardData = "cardData"
    }

    var estimatedSizeBytes: Int64? {
        guard let siblings = siblings else { return nil }
        let total = siblings.compactMap(\.size).reduce(0, +)
        return total > 0 ? total : nil
    }

    var contextLength: Int? {
        cardData?.contextLength
    }

    var languages: [String] {
        cardData?.language ?? []
    }

    var hasChatTemplate: Bool {
        guard let siblings = siblings else { return false }
        return siblings.contains { $0.rfilename == "tokenizer_config.json" }
    }
}

// MARK: - Download Task

struct LocalLLMDownloadTask {
    let repoId: String
    var urlSessionTask: URLSessionDownloadTask?
    var progress: Double = 0
    var downloadedBytes: Int64 = 0
    var totalBytes: Int64?
    var error: String?
}

// MARK: - Catalog Store

@MainActor
final class LocalLLMCatalogStore: ObservableObject {
    static let cacheURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("GhostType/local_llm_catalog.json")
    }()

    @Published private(set) var entries: [LocalLLMModelEntry] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var catalogStatus = ""
    @Published private(set) var lastRefreshed: Date?

    // Download state per repoId
    @Published private(set) var downloadProgress: [String: Double] = [:]
    @Published private(set) var downloadErrors: [String: String] = [:]
    @Published private(set) var downloadingRepos: Set<String> = []

    // Pinned and last-used tracking
    @Published var pinnedRepos: Set<String> {
        didSet { savePinnedRepos() }
    }
    @Published private(set) var lastUsed: [String: Date] = [:]

    private let defaults = UserDefaults.standard
    private let backendBaseURL = URL(string: "http://127.0.0.1:8765")!

    init() {
        let saved = defaults.stringArray(forKey: "GhostType.localLLMPinnedRepos") ?? []
        self.pinnedRepos = Set(saved)
        self.entries = Self.loadFromPresets()
        Task { await loadCachedCatalog() }
    }

    // MARK: - Preset Catalog

    static func loadFromPresets() -> [LocalLLMModelEntry] {
        return EngineSettingsCatalog.localLLMModelPresets.map { repoId in
            LocalLLMModelEntry.from(repoId: repoId)
        }
    }

    // MARK: - Refresh from HuggingFace

    func refreshFromHuggingFace() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        catalogStatus = "Refreshing catalog…"

        // We fetch metadata for each model in our preset list concurrently
        let repoIds = EngineSettingsCatalog.localLLMModelPresets
        var updated: [LocalLLMModelEntry] = []

        await withTaskGroup(of: LocalLLMModelEntry?.self) { group in
            for repoId in repoIds {
                group.addTask {
                    await self.fetchHFMetadata(for: repoId)
                }
            }
            for await result in group {
                if let entry = result {
                    updated.append(entry)
                }
            }
        }

        // Sort to preserve preset order
        let order = Dictionary(uniqueKeysWithValues: repoIds.enumerated().map { ($1, $0) })
        updated.sort { (order[$0.repoId] ?? Int.max) < (order[$1.repoId] ?? Int.max) }

        if !updated.isEmpty {
            entries = updated
            lastRefreshed = Date()
            catalogStatus = "Updated \(updated.count) models"
            saveCatalogCache(entries: updated)
        } else {
            catalogStatus = "No models returned — check network"
        }

        isRefreshing = false
    }

    private func fetchHFMetadata(for repoId: String) async -> LocalLLMModelEntry? {
        var base = LocalLLMModelEntry.from(repoId: repoId)
        let encoded = repoId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? repoId
        let url = URL(string: "https://huggingface.co/api/models/\(encoded)")!
        do {
            var req = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 15)
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, _) = try await URLSession.shared.data(for: req)
            if let info = try? JSONDecoder().decode(HFModelInfo.self, from: data) {
                // license from cardData or top-level
                let license = info.cardData?.license ?? info.license
                let contextLength = info.cardData?.contextLength
                let languages = info.cardData?.language ?? []
                let hasChatTemplate = info.hasChatTemplate
                let sizeBytes = info.estimatedSizeBytes
                base = LocalLLMModelEntry(
                    id: base.id,
                    repoId: base.repoId,
                    displayName: base.displayName,
                    publisher: base.publisher,
                    quantization: base.quantization,
                    sizeBytesEstimate: sizeBytes,
                    paramScale: base.paramScale,
                    license: license,
                    contextLength: contextLength,
                    hasChatTemplate: hasChatTemplate,
                    languages: languages,
                    downloadStatus: base.downloadStatus,
                    downloadProgress: base.downloadProgress,
                    downloadedBytes: base.downloadedBytes,
                    downloadError: base.downloadError,
                    isPinned: base.isPinned,
                    lastUsedAt: base.lastUsedAt
                )
            }
        } catch {
            // silently ignore — use base entry
        }
        return base
    }

    // MARK: - Cache persistence

    private struct CachedEntry: Codable {
        let repoId: String
        let sizeBytesEstimate: Int64?
        let paramScale: String?
        let license: String?
        let contextLength: Int?
        let hasChatTemplate: Bool?
        let languages: [String]
    }

    private func saveCatalogCache(entries: [LocalLLMModelEntry]) {
        let cached = entries.map { e in
            CachedEntry(
                repoId: e.repoId,
                sizeBytesEstimate: e.sizeBytesEstimate,
                paramScale: e.paramScale,
                license: e.license,
                contextLength: e.contextLength,
                hasChatTemplate: e.hasChatTemplate,
                languages: e.languages
            )
        }
        if let data = try? JSONEncoder().encode(cached) {
            try? FileManager.default.createDirectory(
                at: Self.cacheURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? data.write(to: Self.cacheURL, options: .atomic)
        }
    }

    private func loadCachedCatalog() async {
        guard let data = try? Data(contentsOf: Self.cacheURL),
              let cached = try? JSONDecoder().decode([CachedEntry].self, from: data) else { return }
        let byRepo = Dictionary(uniqueKeysWithValues: cached.map { ($0.repoId, $0) })
        entries = entries.map { e in
            guard let c = byRepo[e.repoId] else { return e }
            return LocalLLMModelEntry(
                id: e.id,
                repoId: e.repoId,
                displayName: e.displayName,
                publisher: e.publisher,
                quantization: e.quantization,
                sizeBytesEstimate: c.sizeBytesEstimate ?? e.sizeBytesEstimate,
                paramScale: c.paramScale ?? e.paramScale,
                license: c.license ?? e.license,
                contextLength: c.contextLength ?? e.contextLength,
                hasChatTemplate: c.hasChatTemplate ?? e.hasChatTemplate,
                languages: c.languages.isEmpty ? e.languages : c.languages,
                downloadStatus: e.downloadStatus,
                downloadProgress: e.downloadProgress,
                downloadedBytes: e.downloadedBytes,
                downloadError: e.downloadError,
                isPinned: pinnedRepos.contains(e.repoId),
                lastUsedAt: e.lastUsedAt
            )
        }
    }

    // MARK: - Pinned

    func togglePin(repoId: String) {
        if pinnedRepos.contains(repoId) {
            pinnedRepos.remove(repoId)
        } else {
            pinnedRepos.insert(repoId)
        }
        updateEntryPinState(repoId: repoId)
    }

    private func updateEntryPinState(repoId: String) {
        if let idx = entries.firstIndex(where: { $0.repoId == repoId }) {
            entries[idx].isPinned = pinnedRepos.contains(repoId)
        }
    }

    private func savePinnedRepos() {
        defaults.set(Array(pinnedRepos), forKey: "GhostType.localLLMPinnedRepos")
    }

    // MARK: - Download via backend

    func startDownload(repoId: String) async {
        guard !downloadingRepos.contains(repoId) else { return }
        downloadingRepos.insert(repoId)
        downloadErrors.removeValue(forKey: repoId)
        updateDownloadStatus(repoId: repoId, status: .downloading, progress: 0)

        do {
            let url = backendBaseURL.appendingPathComponent("local_llm/download")
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONEncoder().encode(["repo_id": repoId])
            req.timeoutInterval = 3600
            let (_, response) = try await URLSession.shared.data(for: req)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw NSError(domain: "LocalLLM", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "Backend returned HTTP \(http.statusCode)"])
            }
            updateDownloadStatus(repoId: repoId, status: .ready, progress: 1.0)
        } catch {
            downloadErrors[repoId] = error.localizedDescription
            updateDownloadStatus(repoId: repoId, status: .error, progress: 0)
        }
        downloadingRepos.remove(repoId)
    }

    func cancelDownload(repoId: String) async {
        let url = backendBaseURL.appendingPathComponent("local_llm/cancel_download")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONEncoder().encode(["repo_id": repoId])
        _ = try? await URLSession.shared.data(for: req)
        downloadingRepos.remove(repoId)
        updateDownloadStatus(repoId: repoId, status: .notDownloaded, progress: 0)
    }

    func deleteModel(repoId: String) async {
        let url = backendBaseURL.appendingPathComponent("local_llm/delete")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONEncoder().encode(["repo_id": repoId])
        _ = try? await URLSession.shared.data(for: req)
        updateDownloadStatus(repoId: repoId, status: .notDownloaded, progress: 0)
    }

    func openCacheDirectory() {
        let hfCachePath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub")
        NSWorkspace.shared.open(hfCachePath)
    }

    private func updateDownloadStatus(repoId: String, status: LocalLLMDownloadStatus, progress: Double) {
        if let idx = entries.firstIndex(where: { $0.repoId == repoId }) {
            entries[idx].downloadStatus = status
            entries[idx].downloadProgress = progress
        }
        downloadProgress[repoId] = progress
    }

    // MARK: - Quantization switching

    /// Find the best matching model in the catalog for a given base model and target quantization
    func findVariant(for repoId: String, quantization: String) -> LocalLLMModelEntry? {
        let base = LocalLLMModelEntry.from(repoId: repoId)
        let familyName = base.displayName.lowercased()
        let publisher = base.publisher

        return entries.first { entry in
            entry.publisher == publisher &&
            entry.displayName.lowercased() == familyName &&
            entry.quantization.lowercased() == quantization.lowercased()
        }
    }

    // MARK: - Computed helpers

    var totalModelCount: Int { entries.count }
    var downloadedCount: Int { entries.filter { $0.downloadStatus == .ready }.count }
}
