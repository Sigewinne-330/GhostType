import Combine
import Foundation

protocol UserDefaultsBackedObject: AnyObject, ObservableObject where ObjectWillChangePublisher == ObservableObjectPublisher {
    @MainActor var defaults: UserDefaults { get }
}

@propertyWrapper
struct UserDefaultBacked<Value> {
    private let key: String
    private let defaultValue: Value
    private let readValue: (UserDefaults, String, Value) -> Value
    private let writeValue: (UserDefaults, String, Value) -> Void
    private let onSet: ((any UserDefaultsBackedObject, Value) -> Void)?

    init(
        key: String,
        defaultValue: Value,
        readValue: @escaping (UserDefaults, String, Value) -> Value,
        writeValue: @escaping (UserDefaults, String, Value) -> Void,
        onSet: ((any UserDefaultsBackedObject, Value) -> Void)? = nil
    ) {
        self.key = key
        self.defaultValue = defaultValue
        self.readValue = readValue
        self.writeValue = writeValue
        self.onSet = onSet
    }

    @available(*, unavailable, message: "UserDefaultBacked is for class properties only.")
    var wrappedValue: Value {
        get { fatalError("Use enclosing-instance access.") }
        set { fatalError("Use enclosing-instance access.") }
    }

    @MainActor
    static subscript<EnclosingSelf: UserDefaultsBackedObject>(
        _enclosingInstance instance: EnclosingSelf,
        wrapped _: ReferenceWritableKeyPath<EnclosingSelf, Value>,
        storage storageKeyPath: ReferenceWritableKeyPath<EnclosingSelf, UserDefaultBacked<Value>>
    ) -> Value {
        get {
            let wrapper = instance[keyPath: storageKeyPath]
            return wrapper.readValue(instance.defaults, wrapper.key, wrapper.defaultValue)
        }
        set {
            let wrapper = instance[keyPath: storageKeyPath]
            instance.objectWillChange.send()
            wrapper.writeValue(instance.defaults, wrapper.key, newValue)
            wrapper.onSet?(instance, newValue)
        }
    }
}

extension UserDefaultBacked where Value == Bool {
    init(
        key: String,
        defaultValue: Bool,
        onSet: ((any UserDefaultsBackedObject, Bool) -> Void)? = nil
    ) {
        self.init(
            key: key,
            defaultValue: defaultValue,
            readValue: { defaults, key, fallback in
                defaults.object(forKey: key) as? Bool ?? fallback
            },
            writeValue: { defaults, key, value in
                defaults.set(value, forKey: key)
            },
            onSet: onSet
        )
    }
}

extension UserDefaultBacked where Value: RawRepresentable, Value.RawValue == String {
    init(
        key: String,
        defaultValue: Value,
        onSet: ((any UserDefaultsBackedObject, Value) -> Void)? = nil
    ) {
        self.init(
            key: key,
            defaultValue: defaultValue,
            readValue: { defaults, key, fallback in
                guard let raw = defaults.string(forKey: key),
                      let parsed = Value(rawValue: raw) else {
                    return fallback
                }
                return parsed
            },
            writeValue: { defaults, key, value in
                defaults.set(value.rawValue, forKey: key)
            },
            onSet: onSet
        )
    }
}

extension UserDefaultBacked where Value == Int {
    init(
        key: String,
        defaultValue: Int,
        onSet: ((any UserDefaultsBackedObject, Int) -> Void)? = nil
    ) {
        self.init(
            key: key,
            defaultValue: defaultValue,
            readValue: { defaults, key, fallback in
                guard defaults.object(forKey: key) != nil else { return fallback }
                return defaults.integer(forKey: key)
            },
            writeValue: { defaults, key, value in
                defaults.set(value, forKey: key)
            },
            onSet: onSet
        )
    }
}

extension UserDefaultBacked where Value == Double {
    init(
        key: String,
        defaultValue: Double,
        onSet: ((any UserDefaultsBackedObject, Double) -> Void)? = nil
    ) {
        self.init(
            key: key,
            defaultValue: defaultValue,
            readValue: { defaults, key, fallback in
                guard defaults.object(forKey: key) != nil else { return fallback }
                return defaults.double(forKey: key)
            },
            writeValue: { defaults, key, value in
                defaults.set(value, forKey: key)
            },
            onSet: onSet
        )
    }
}

@MainActor
final class UserPreferences: UserDefaultsBackedObject {
    private enum Keys {
        static let uiLanguage = "GhostType.uiLanguage"
        static let targetLanguage = "GhostType.targetLanguage"
        static let outputLanguage = "GhostType.outputLanguage"
        static let memoryTimeout = "GhostType.memoryTimeout"
        static let audioEnhancementEnabled = "GhostType.audioEnhancementEnabled"
        static let audioEnhancementMode = "GhostType.audioEnhancementMode"
        static let lowVolumeBoost = "GhostType.lowVolumeBoost"
        static let noiseSuppressionLevel = "GhostType.noiseSuppressionLevel"
        static let endpointPauseThreshold = "GhostType.endpointPauseThreshold"
        static let showAudioDebugHUD = "GhostType.showAudioDebugHUD"
        static let dictationDualPassEnabled = "GhostType.dictationDualPassEnabled"
        static let dictationQualityAutoReplaceEnabled = "GhostType.dictationQualityAutoReplaceEnabled"
        static let removeRepeatedTextEnabled = "GhostType.removeRepeatedTextEnabled"
        static let smartInsertEnabled = "GhostType.smartInsertEnabled"
        static let restoreClipboardAfterPaste = "GhostType.restoreClipboardAfterPaste"
        static let pretranscribeEnabled = "GhostType.pretranscribeEnabled"
        static let pretranscribeStepSeconds = "GhostType.pretranscribeStepSeconds"
        static let pretranscribeOverlapSeconds = "GhostType.pretranscribeOverlapSeconds"
        static let pretranscribeMaxChunkSeconds = "GhostType.pretranscribeMaxChunkSeconds"
        static let pretranscribeMinSpeechSeconds = "GhostType.pretranscribeMinSpeechSeconds"
        static let pretranscribeEndSilenceMS = "GhostType.pretranscribeEndSilenceMS"
        static let pretranscribeMaxInFlight = "GhostType.pretranscribeMaxInFlight"
        static let pretranscribeFallbackPolicy = "GhostType.pretranscribeFallbackPolicy"
        static let dictateShortcut = "GhostType.dictateShortcut"
        static let askShortcut = "GhostType.askShortcut"
        static let translateShortcut = "GhostType.translateShortcut"
    }

    let defaults: UserDefaults

    @UserDefaultBacked(key: Keys.uiLanguage, defaultValue: .english)
    var uiLanguage: UILanguageOption

    @UserDefaultBacked(key: Keys.targetLanguage, defaultValue: .chinese)
    var targetLanguage: TargetLanguageOption

    @UserDefaultBacked(key: Keys.outputLanguage, defaultValue: .auto)
    var outputLanguage: OutputLanguageOption

    @UserDefaultBacked(key: Keys.memoryTimeout, defaultValue: .fiveMinutes)
    var memoryTimeout: MemoryTimeoutOption

    @UserDefaultBacked(key: Keys.audioEnhancementEnabled, defaultValue: true)
    var audioEnhancementEnabled: Bool

    @UserDefaultBacked(key: Keys.audioEnhancementMode, defaultValue: .webRTC)
    var audioEnhancementMode: AudioEnhancementModeOption

    @UserDefaultBacked(key: Keys.lowVolumeBoost, defaultValue: .medium)
    var lowVolumeBoost: LowVolumeBoostOption

    @UserDefaultBacked(key: Keys.noiseSuppressionLevel, defaultValue: .moderate)
    var noiseSuppressionLevel: NoiseSuppressionLevelOption

    @UserDefaultBacked(key: Keys.endpointPauseThreshold, defaultValue: .ms350)
    var endpointPauseThreshold: EndpointPauseThresholdOption

    @UserDefaultBacked(key: Keys.showAudioDebugHUD, defaultValue: false)
    var showAudioDebugHUD: Bool

    @UserDefaultBacked(key: Keys.dictationDualPassEnabled, defaultValue: false)
    var dictationDualPassEnabled: Bool

    @UserDefaultBacked(
        key: Keys.dictationQualityAutoReplaceEnabled,
        defaultValue: false
    )
    var dictationQualityAutoReplaceEnabled: Bool

    @UserDefaultBacked(key: Keys.removeRepeatedTextEnabled, defaultValue: true)
    var removeRepeatedTextEnabled: Bool

    @UserDefaultBacked(key: Keys.smartInsertEnabled, defaultValue: true)
    var smartInsertEnabled: Bool

    @UserDefaultBacked(key: Keys.restoreClipboardAfterPaste, defaultValue: true)
    var restoreClipboardAfterPaste: Bool

    @UserDefaultBacked(key: Keys.pretranscribeEnabled, defaultValue: false)
    var pretranscribeEnabled: Bool

    @UserDefaultBacked(key: Keys.pretranscribeStepSeconds, defaultValue: 5.0)
    var pretranscribeStepSeconds: Double

    @UserDefaultBacked(key: Keys.pretranscribeOverlapSeconds, defaultValue: 0.6)
    var pretranscribeOverlapSeconds: Double

    @UserDefaultBacked(key: Keys.pretranscribeMaxChunkSeconds, defaultValue: 10.0)
    var pretranscribeMaxChunkSeconds: Double

    @UserDefaultBacked(key: Keys.pretranscribeMinSpeechSeconds, defaultValue: 1.2)
    var pretranscribeMinSpeechSeconds: Double

    @UserDefaultBacked(key: Keys.pretranscribeEndSilenceMS, defaultValue: 240)
    var pretranscribeEndSilenceMS: Int

    @UserDefaultBacked(key: Keys.pretranscribeMaxInFlight, defaultValue: 1)
    var pretranscribeMaxInFlight: Int

    @UserDefaultBacked(
        key: Keys.pretranscribeFallbackPolicy,
        defaultValue: .fullASROnHighFailure
    )
    var pretranscribeFallbackPolicy: PretranscribeFallbackPolicyOption

    @Published var dictateShortcut: HotkeyShortcut {
        didSet {
            persistShortcut(dictateShortcut, forKey: Keys.dictateShortcut)
        }
    }

    @Published var askShortcut: HotkeyShortcut {
        didSet {
            persistShortcut(askShortcut, forKey: Keys.askShortcut)
        }
    }

    @Published var translateShortcut: HotkeyShortcut {
        didSet {
            persistShortcut(translateShortcut, forKey: Keys.translateShortcut)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        dictateShortcut = Self.loadShortcut(from: defaults, forKey: Keys.dictateShortcut, fallback: .defaultDictation)
        askShortcut = Self.loadShortcut(from: defaults, forKey: Keys.askShortcut, fallback: .defaultAsk)
        translateShortcut = Self.loadShortcut(from: defaults, forKey: Keys.translateShortcut, fallback: .defaultTranslate)

        // One-time migration: the old init logic used to force outputLanguage
        // to match uiLanguage (e.g. Chinese UI → Chinese output), which locked
        // users into a single output language.  Reset to .auto so the system
        // follows ASR-detected language instead.
        let migrationKey = "GhostType.outputLanguageAutoMigrationDone"
        if !defaults.bool(forKey: migrationKey) {
            let current = defaults.string(forKey: Keys.outputLanguage)
            if current == nil || current == OutputLanguageOption.chineseSimplified.rawValue || current == OutputLanguageOption.english.rawValue {
                defaults.set(OutputLanguageOption.auto.rawValue, forKey: Keys.outputLanguage)
            }
            defaults.set(true, forKey: migrationKey)
        }
    }

    var memoryTimeoutSeconds: Int? {
        memoryTimeout.seconds
    }

    func ui(_ zh: String, _ en: String) -> String {
        uiLanguage == .english ? en : zh
    }
}
