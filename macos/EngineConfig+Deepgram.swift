import Foundation

extension EngineConfig {
    var isMixedEngineSelection: Bool {
        (asrEngine == .localMLX) != (llmEngine == .localMLX)
    }

    var requiresLocalASR: Bool {
        asrEngine == .localMLX
    }

    var requiresLocalLLM: Bool {
        llmEngine == .localMLX
    }

    var requiresLocalBackend: Bool {
        requiresLocalASR || requiresLocalLLM
    }

    var shouldUseLocalProvider: Bool {
        requiresLocalASR && requiresLocalLLM
    }

    var shouldUseCloudProvider: Bool {
        !requiresLocalASR && !requiresLocalLLM
    }

    var deepgramResolvedLanguage: String {
        DeepgramConfig.normalizedLanguageCode(cloudASRLanguage)
    }

    var deepgramEndpointingValue: Int? {
        deepgram.endpointingEnabled ? max(10, deepgram.endpointingMS) : nil
    }

    var deepgramTerminologyRawValue: String {
        switch DeepgramConfig.terminologyMode(for: cloudASRModelName) {
        case .keywords:
            return deepgram.keywords
        case .keyterm:
            return deepgram.keyterm
        }
    }

    var deepgramQueryConfig: DeepgramQueryConfig {
        let isStreamingMode = deepgram.transcriptionMode == .streaming
        return DeepgramQueryConfig(
            modelName: cloudASRModelName,
            language: deepgramResolvedLanguage,
            endpointingMS: isStreamingMode ? deepgramEndpointingValue : nil,
            interimResults: isStreamingMode ? deepgram.interimResults : false,
            smartFormat: deepgram.smartFormat,
            punctuate: deepgram.punctuate,
            paragraphs: deepgram.paragraphs,
            diarize: deepgram.diarize,
            terminologyRawValue: deepgramTerminologyRawValue,
            mode: deepgram.transcriptionMode
        )
    }
}
