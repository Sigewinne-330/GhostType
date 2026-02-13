import Foundation

@MainActor
final class DeepgramSettings: ObservableObject {
    private enum Keys {
        static let mode = "GhostType.deepgram.mode"
        static let region = "GhostType.deepgram.region"
        static let endpointingEnabled = "GhostType.deepgram.endpointingEnabled"
        static let endpointingMS = "GhostType.deepgram.endpointingMS"
        static let interimResults = "GhostType.deepgram.interimResults"
        static let smartFormat = "GhostType.deepgram.smartFormat"
        static let punctuate = "GhostType.deepgram.punctuate"
        static let paragraphs = "GhostType.deepgram.paragraphs"
        static let diarize = "GhostType.deepgram.diarize"
        static let keywords = "GhostType.deepgram.keywords"
        static let keyterm = "GhostType.deepgram.keyterm"
    }

    private let defaults: UserDefaults
    var onChange: (() -> Void)?

    @Published var transcriptionMode: DeepgramTranscriptionMode {
        didSet {
            defaults.set(transcriptionMode.rawValue, forKey: Keys.mode)
            onChange?()
        }
    }

    @Published var region: DeepgramRegionOption {
        didSet {
            defaults.set(region.rawValue, forKey: Keys.region)
            onChange?()
        }
    }

    @Published var endpointingEnabled: Bool {
        didSet {
            defaults.set(endpointingEnabled, forKey: Keys.endpointingEnabled)
            onChange?()
        }
    }

    @Published var endpointingMS: Int {
        didSet {
            let clamped = max(10, min(10_000, endpointingMS))
            if endpointingMS != clamped {
                endpointingMS = clamped
                return
            }
            defaults.set(endpointingMS, forKey: Keys.endpointingMS)
            onChange?()
        }
    }

    @Published var interimResults: Bool {
        didSet {
            defaults.set(interimResults, forKey: Keys.interimResults)
            onChange?()
        }
    }

    @Published var smartFormat: Bool {
        didSet {
            defaults.set(smartFormat, forKey: Keys.smartFormat)
            onChange?()
        }
    }

    @Published var punctuate: Bool {
        didSet {
            defaults.set(punctuate, forKey: Keys.punctuate)
            onChange?()
        }
    }

    @Published var paragraphs: Bool {
        didSet {
            defaults.set(paragraphs, forKey: Keys.paragraphs)
            onChange?()
        }
    }

    @Published var diarize: Bool {
        didSet {
            defaults.set(diarize, forKey: Keys.diarize)
            onChange?()
        }
    }

    @Published var keywords: String {
        didSet {
            defaults.set(keywords, forKey: Keys.keywords)
            onChange?()
        }
    }

    @Published var keyterm: String {
        didSet {
            defaults.set(keyterm, forKey: Keys.keyterm)
            onChange?()
        }
    }

    init(defaults: UserDefaults, initialBaseURL: String) {
        self.defaults = defaults

        transcriptionMode = DeepgramTranscriptionMode(
            rawValue: defaults.string(forKey: Keys.mode) ?? ""
        ) ?? .batch

        region = DeepgramRegionOption(
            rawValue: defaults.string(forKey: Keys.region) ?? ""
        ) ?? Self.inferredRegion(from: initialBaseURL)

        endpointingEnabled = defaults.object(forKey: Keys.endpointingEnabled) as? Bool ?? true

        let storedEndpointingMS = defaults.integer(forKey: Keys.endpointingMS)
        endpointingMS = storedEndpointingMS > 0 ? storedEndpointingMS : DeepgramConfig.defaultEndpointingMS

        interimResults = defaults.object(forKey: Keys.interimResults) as? Bool ?? true
        smartFormat = defaults.object(forKey: Keys.smartFormat) as? Bool ?? true
        punctuate = defaults.object(forKey: Keys.punctuate) as? Bool ?? true
        paragraphs = defaults.object(forKey: Keys.paragraphs) as? Bool ?? true
        diarize = defaults.object(forKey: Keys.diarize) as? Bool ?? false
        keywords = defaults.string(forKey: Keys.keywords) ?? ""
        keyterm = defaults.string(forKey: Keys.keyterm) ?? ""
    }

    private static func inferredRegion(from baseURLRaw: String) -> DeepgramRegionOption {
        let trimmed = baseURLRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .standard }
        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let host = URLComponents(string: candidate)?.host?.lowercased() else {
            return .standard
        }
        if host == DeepgramRegionOption.eu.host {
            return .eu
        }
        return .standard
    }
}
