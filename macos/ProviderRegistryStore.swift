import Foundation

struct ProviderRegistryDocument: Codable {
    var schemaVersion: Int
    var customASRProviders: [ASRProviderProfile]
    var customLLMProviders: [LLMProviderProfile]
}

final class ProviderRegistryStore {
    static let shared = ProviderRegistryStore()
    private let fileURL: URL
    private let appLogger = AppLogger.shared

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        let directory = appSupport.appendingPathComponent("GhostType", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            appLogger.log("Failed to create provider registry directory: \(error.localizedDescription)", type: .error)
        }
        fileURL = directory.appendingPathComponent("provider_registry.json", isDirectory: false)
    }

    func load() -> ProviderRegistryDocument {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return defaultDocument()
        }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            appLogger.log("Failed to read provider registry: \(error.localizedDescription)", type: .warning)
            return defaultDocument()
        }
        do {
            return try JSONDecoder().decode(ProviderRegistryDocument.self, from: data)
        } catch {
            appLogger.log("Failed to decode provider registry JSON: \(error.localizedDescription)", type: .warning)
            return defaultDocument()
        }
    }

    func save(customASRProviders: [ASRProviderProfile], customLLMProviders: [LLMProviderProfile]) {
        let document = ProviderRegistryDocument(
            schemaVersion: 1,
            customASRProviders: customASRProviders,
            customLLMProviders: customLLMProviders
        )
        do {
            let data = try JSONEncoder().encode(document)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            appLogger.log("Failed to persist provider registry: \(error.localizedDescription)", type: .error)
        }
    }

    private func defaultDocument() -> ProviderRegistryDocument {
        ProviderRegistryDocument(
            schemaVersion: 1,
            customASRProviders: [],
            customLLMProviders: []
        )
    }
}
