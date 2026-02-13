import Foundation

enum UILanguageOption: String, CaseIterable, Identifiable {
    case english = "English"
    case chineseSimplified = "Chinese (Simplified)"

    var id: String { rawValue }
}

enum TargetLanguageOption: String, CaseIterable, Identifiable {
    case chinese = "Chinese"
    case english = "English"

    var id: String { rawValue }
}

enum OutputLanguageOption: String, CaseIterable, Identifiable {
    case auto = "Auto"
    case chineseSimplified = "Simplified Chinese"
    case chineseTraditional = "Traditional Chinese"
    case english = "English"
    case japanese = "Japanese"
    case korean = "Korean"
    case spanish = "Spanish"
    case french = "French"
    case german = "German"
    case portugueseBrazil = "Portuguese (Brazil)"
    case russian = "Russian"
    case arabic = "Arabic"
    case hindi = "Hindi"

    var id: String { rawValue }

    var forcedLanguageTag: String? {
        switch self {
        case .auto:
            return nil
        case .chineseSimplified:
            return "zh-Hans"
        case .chineseTraditional:
            return "zh-Hant"
        case .english:
            return "en"
        case .japanese:
            return "ja"
        case .korean:
            return "ko"
        case .spanish:
            return "es"
        case .french:
            return "fr"
        case .german:
            return "de"
        case .portugueseBrazil:
            return "pt-BR"
        case .russian:
            return "ru"
        case .arabic:
            return "ar"
        case .hindi:
            return "hi"
        }
    }

    var promptLanguageName: String {
        switch self {
        case .auto:
            return "Auto"
        case .chineseSimplified:
            return "Simplified Chinese"
        case .chineseTraditional:
            return "Traditional Chinese"
        case .english:
            return "English"
        case .japanese:
            return "Japanese"
        case .korean:
            return "Korean"
        case .spanish:
            return "Spanish"
        case .french:
            return "French"
        case .german:
            return "German"
        case .portugueseBrazil:
            return "Portuguese (Brazil)"
        case .russian:
            return "Russian"
        case .arabic:
            return "Arabic"
        case .hindi:
            return "Hindi"
        }
    }

    func displayName(uiLanguage: UILanguageOption) -> String {
        switch uiLanguage {
        case .english:
            return promptLanguageName
        case .chineseSimplified:
            switch self {
            case .auto:
                return "自动（跟随输入语言）"
            case .chineseSimplified:
                return "简体中文"
            case .chineseTraditional:
                return "繁体中文"
            case .english:
                return "英语"
            case .japanese:
                return "日语"
            case .korean:
                return "韩语"
            case .spanish:
                return "西班牙语"
            case .french:
                return "法语"
            case .german:
                return "德语"
            case .portugueseBrazil:
                return "葡萄牙语（巴西）"
            case .russian:
                return "俄语"
            case .arabic:
                return "阿拉伯语"
            case .hindi:
                return "印地语"
            }
        }
    }
}

enum MemoryTimeoutOption: String, CaseIterable, Identifiable {
    case oneMinute = "1 minute"
    case fiveMinutes = "5 minutes"
    case tenMinutes = "10 minutes"
    case fifteenMinutes = "15 minutes"
    case halfHour = "30 minutes"
    case oneHour = "1 hour"
    case twelveHours = "12 hours"
    case never = "Never"

    var id: String { rawValue }

    var seconds: Int? {
        switch self {
        case .oneMinute:
            return 60
        case .fiveMinutes:
            return 300
        case .tenMinutes:
            return 600
        case .fifteenMinutes:
            return 900
        case .halfHour:
            return 1800
        case .oneHour:
            return 3600
        case .twelveHours:
            return 43200
        case .never:
            return nil
        }
    }
}

enum AudioEnhancementModeOption: String, CaseIterable, Identifiable {
    case webRTC = "WebRTC Enhancement"
    case systemVoiceProcessing = "System Voice Processing"
    case off = "Off"

    var id: String { rawValue }

    var requestValue: String {
        switch self {
        case .webRTC:
            return "webrtc"
        case .systemVoiceProcessing:
            return "system_voice_processing"
        case .off:
            return "off"
        }
    }
}

enum LowVolumeBoostOption: String, CaseIterable, Identifiable {
    case low = "Low"
    case medium = "Medium"
    case high = "High"

    var id: String { rawValue }

    var requestValue: String {
        rawValue.lowercased()
    }
}

enum NoiseSuppressionLevelOption: String, CaseIterable, Identifiable {
    case low = "Low"
    case moderate = "Moderate"
    case high = "High"
    case veryHigh = "VeryHigh"

    var id: String { rawValue }

    var requestValue: String {
        switch self {
        case .veryHigh:
            return "very_high"
        default:
            return rawValue.lowercased()
        }
    }
}

enum EndpointPauseThresholdOption: String, CaseIterable, Identifiable {
    case ms200 = "200 ms"
    case ms350 = "350 ms"
    case ms500 = "500 ms"

    var id: String { rawValue }

    var milliseconds: Int {
        switch self {
        case .ms200:
            return 200
        case .ms350:
            return 350
        case .ms500:
            return 500
        }
    }
}

enum PretranscribeFallbackPolicyOption: String, CaseIterable, Identifiable, Sendable {
    case off = "Off"
    case fullASROnHighFailure = "Full ASR On High Failure"

    var id: String { rawValue }
}
