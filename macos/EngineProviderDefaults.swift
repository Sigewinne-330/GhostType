import Foundation

enum EngineProviderDefaults {
    enum ASR {
        static func defaultProviderID(for engine: ASREngineOption) -> String {
            switch engine {
            case .openAIWhisper:
                return "builtin.asr.openai-whisper"
            case .deepgram:
                return "builtin.asr.deepgram"
            case .assemblyAI:
                return "builtin.asr.assemblyai"
            case .groq:
                return "builtin.asr.groq"
            case .geminiMultimodal:
                return "builtin.asr.gemini-multimodal"
            case .customOpenAICompatible:
                return "builtin.asr.codex"
            case .localMLX:
                return "builtin.asr.openai-whisper"
            case .localHTTPOpenAIAudio:
                return "builtin.asr.openai-whisper"
            }
        }

        static let providers: [ASRProviderProfile] = [
            ASRProviderProfile(
                id: "builtin.asr.openai-whisper",
                type: .builtIn,
                displayName: "OpenAI Whisper",
                transport: .http,
                engine: .openAIWhisper,
                baseURL: ASREngineOption.openAIWhisper.defaultBaseURL,
                models: ["whisper-1", "gpt-4o-mini-transcribe", "gpt-4o-transcribe"],
                defaultModel: ASREngineOption.openAIWhisper.defaultModelName,
                authMode: .bearer,
                apiKeyRef: APISecretKey.asrOpenAI.rawValue,
                headers: [],
                request: ASRProviderRequestConfig.openAIDefault
            ),
            ASRProviderProfile(
                id: "builtin.asr.deepgram",
                type: .builtIn,
                displayName: "Deepgram",
                transport: .http,
                engine: .deepgram,
                baseURL: ASREngineOption.deepgram.defaultBaseURL,
                models: ["nova-3", "nova-3-general", "nova-2", "nova-2-general"],
                defaultModel: ASREngineOption.deepgram.defaultModelName,
                authMode: .bearer,
                apiKeyRef: APISecretKey.asrDeepgram.rawValue,
                headers: [],
                request: ASRProviderRequestConfig(
                    path: "/\(DeepgramConfig.endpointPath)",
                    method: "POST",
                    contentType: "binary",
                    extraParamsJSON: "{}"
                )
            ),
            ASRProviderProfile(
                id: "builtin.asr.assemblyai",
                type: .builtIn,
                displayName: "AssemblyAI",
                transport: .http,
                engine: .assemblyAI,
                baseURL: ASREngineOption.assemblyAI.defaultBaseURL,
                models: ["best", "nano"],
                defaultModel: ASREngineOption.assemblyAI.defaultModelName,
                authMode: .bearer,
                apiKeyRef: APISecretKey.asrAssemblyAI.rawValue,
                headers: [],
                request: ASRProviderRequestConfig(
                    path: "/v2/transcript",
                    method: "POST",
                    contentType: "json",
                    extraParamsJSON: "{}"
                )
            ),
            ASRProviderProfile(
                id: "builtin.asr.groq",
                type: .builtIn,
                displayName: "Groq ASR",
                transport: .http,
                engine: .groq,
                baseURL: ASREngineOption.groq.defaultBaseURL,
                models: ["whisper-large-v3-turbo", "distil-whisper-large-v3-en", "whisper-large-v3"],
                defaultModel: ASREngineOption.groq.defaultModelName,
                authMode: .bearer,
                apiKeyRef: APISecretKey.asrGroq.rawValue,
                headers: [],
                request: ASRProviderRequestConfig.openAIDefault
            ),
            ASRProviderProfile(
                id: "builtin.asr.gemini-multimodal",
                type: .builtIn,
                displayName: "Gemini Multimodal",
                transport: .http,
                engine: .geminiMultimodal,
                baseURL: ASREngineOption.geminiMultimodal.defaultBaseURL,
                models: ["gemini-2.0-flash", "gemini-2.0-flash-lite", "gemini-1.5-flash-latest"],
                defaultModel: ASREngineOption.geminiMultimodal.defaultModelName,
                authMode: .bearer,
                apiKeyRef: APISecretKey.llmGemini.rawValue,
                headers: [],
                request: ASRProviderRequestConfig(
                    path: "/v1beta/models/{model}:generateContent",
                    method: "POST",
                    contentType: "json",
                    extraParamsJSON: "{}"
                )
            ),
            ASRProviderProfile(
                id: "builtin.asr.custom-openai-compatible",
                type: .builtIn,
                displayName: "Custom OpenAI Compatible",
                transport: .http,
                engine: .customOpenAICompatible,
                baseURL: ASREngineOption.customOpenAICompatible.defaultBaseURL,
                models: ["whisper-1", "transcribe-1"],
                defaultModel: ASREngineOption.customOpenAICompatible.defaultModelName,
                authMode: .bearer,
                apiKeyRef: "provider.asr.custom.api_key",
                headers: [],
                request: ASRProviderRequestConfig.openAIDefault
            ),
            ASRProviderProfile(
                id: "builtin.asr.tencent",
                type: .builtIn,
                displayName: "Tencent Cloud ASR",
                transport: .http,
                engine: .customOpenAICompatible,
                baseURL: "https://asr.tencentcloudapi.com",
                models: ["16k_zh", "8k_zh", "16k_en", "16k_yue"],
                defaultModel: "16k_zh",
                authMode: .vendorSpecific,
                apiKeyRef: "provider.asr.tencent.secret",
                headers: [],
                request: ASRProviderRequestConfig(
                    path: "/",
                    method: "POST",
                    contentType: "json",
                    extraParamsJSON: "{}"
                )
            ),
            ASRProviderProfile(
                id: "builtin.asr.aliyun-nls",
                type: .builtIn,
                displayName: "Alibaba Cloud NLS",
                transport: .websocket,
                engine: .customOpenAICompatible,
                baseURL: "wss://nls-gateway.aliyuncs.com/ws/v1",
                models: ["16k_general", "8k_call_center"],
                defaultModel: "16k_general",
                authMode: .vendorSpecific,
                apiKeyRef: "provider.asr.aliyun.token",
                headers: [],
                request: ASRProviderRequestConfig(
                    path: "/ws/v1",
                    method: "GET",
                    contentType: "binary",
                    extraParamsJSON: "{}"
                )
            ),
            ASRProviderProfile(
                id: "builtin.asr.xfyun",
                type: .builtIn,
                displayName: "iFlytek ASR",
                transport: .websocket,
                engine: .customOpenAICompatible,
                baseURL: "wss://iat-api.xfyun.cn/v2/iat",
                models: ["mandarin", "cantonese", "english"],
                defaultModel: "mandarin",
                authMode: .vendorSpecific,
                apiKeyRef: "provider.asr.xfyun.secret",
                headers: [],
                request: ASRProviderRequestConfig(
                    path: "/v2/iat",
                    method: "GET",
                    contentType: "binary",
                    extraParamsJSON: "{}"
                )
            ),
            ASRProviderProfile(
                id: "builtin.asr.baidu",
                type: .builtIn,
                displayName: "Baidu Speech",
                transport: .http,
                engine: .customOpenAICompatible,
                baseURL: "http://vop.baidu.com/server_api",
                models: ["1537", "1737", "80001"],
                defaultModel: "1537",
                authMode: .vendorSpecific,
                apiKeyRef: "provider.asr.baidu.token",
                headers: [],
                request: ASRProviderRequestConfig(
                    path: "/server_api",
                    method: "POST",
                    contentType: "json",
                    extraParamsJSON: "{}"
                )
            ),
            ASRProviderProfile(
                id: "builtin.asr.codex",
                type: .builtIn,
                displayName: "Codex",
                transport: .http,
                engine: .customOpenAICompatible,
                baseURL: "",
                models: ["transcribe-1", "whisper-1"],
                defaultModel: "transcribe-1",
                authMode: .bearer,
                apiKeyRef: "provider.asr.codex.api_key",
                headers: [],
                request: ASRProviderRequestConfig.openAIDefault
            ),
        ]
    }

    enum LLM {
        static func defaultProviderID(for engine: LLMEngineOption) -> String {
            switch engine {
            case .openAI:
                return "builtin.llm.openai"
            case .openAICompatible:
                return "builtin.llm.openai-compatible"
            case .customOpenAICompatible:
                return "builtin.llm.custom-openai-compatible"
            case .azureOpenAI:
                return "builtin.llm.azure-openai"
            case .anthropic:
                return "builtin.llm.anthropic"
            case .gemini:
                return "builtin.llm.gemini"
            case .deepSeek:
                return "builtin.llm.deepseek"
            case .groq:
                return "builtin.llm.groq"
            case .localMLX:
                return "builtin.llm.openai"
            }
        }

        static let providers: [LLMProviderProfile] = [
            LLMProviderProfile(
                id: "builtin.llm.openai",
                type: .builtIn,
                displayName: "OpenAI",
                engine: .openAI,
                baseURL: LLMEngineOption.openAI.defaultBaseURL,
                models: ["gpt-4o-mini", "gpt-4.1-mini", "gpt-4.1"],
                defaultModel: LLMEngineOption.openAI.defaultModelName,
                authMode: .bearer,
                apiKeyRef: APISecretKey.llmOpenAI.rawValue,
                headers: [],
                request: LLMProviderRequestConfig.openAIDefault
            ),
            LLMProviderProfile(
                id: "builtin.llm.openai-compatible",
                type: .builtIn,
                displayName: "OpenAI Compatible",
                engine: .openAICompatible,
                baseURL: LLMEngineOption.openAICompatible.defaultBaseURL,
                models: ["gpt-4o-mini", "deepseek-chat", "llama-3.1-70b-versatile"],
                defaultModel: LLMEngineOption.openAICompatible.defaultModelName,
                authMode: .bearer,
                apiKeyRef: APISecretKey.llmOpenAICompatible.rawValue,
                headers: [],
                request: LLMProviderRequestConfig.openAIDefault
            ),
            LLMProviderProfile(
                id: "builtin.llm.custom-openai-compatible",
                type: .builtIn,
                displayName: "Custom OpenAI Compatible",
                engine: .customOpenAICompatible,
                baseURL: LLMEngineOption.customOpenAICompatible.defaultBaseURL,
                models: ["gpt-4o-mini"],
                defaultModel: LLMEngineOption.customOpenAICompatible.defaultModelName,
                authMode: .bearer,
                apiKeyRef: "provider.llm.custom.api_key",
                headers: [],
                request: LLMProviderRequestConfig.openAIDefault
            ),
            LLMProviderProfile(
                id: "builtin.llm.azure-openai",
                type: .builtIn,
                displayName: "Azure OpenAI",
                engine: .azureOpenAI,
                baseURL: LLMEngineOption.azureOpenAI.defaultBaseURL,
                models: ["gpt-4o-mini", "gpt-4.1-mini", "gpt-4.1"],
                defaultModel: LLMEngineOption.azureOpenAI.defaultModelName,
                authMode: .bearer,
                apiKeyRef: APISecretKey.llmAzureOpenAI.rawValue,
                headers: [],
                request: LLMProviderRequestConfig(
                    apiStyle: "custom",
                    path: "/openai/deployments/{deployment}/chat/completions",
                    extraParamsJSON: "{}"
                )
            ),
            LLMProviderProfile(
                id: "builtin.llm.anthropic",
                type: .builtIn,
                displayName: "Anthropic",
                engine: .anthropic,
                baseURL: LLMEngineOption.anthropic.defaultBaseURL,
                models: ["claude-3-5-haiku-latest", "claude-3-7-sonnet-latest"],
                defaultModel: LLMEngineOption.anthropic.defaultModelName,
                authMode: .bearer,
                apiKeyRef: APISecretKey.llmAnthropic.rawValue,
                headers: [],
                request: LLMProviderRequestConfig(
                    apiStyle: "custom",
                    path: "/v1/messages",
                    extraParamsJSON: "{}"
                )
            ),
            LLMProviderProfile(
                id: "builtin.llm.gemini",
                type: .builtIn,
                displayName: "Google Gemini",
                engine: .gemini,
                baseURL: LLMEngineOption.gemini.defaultBaseURL,
                models: ["gemini-2.0-flash", "gemini-2.0-flash-lite", "gemini-1.5-flash"],
                defaultModel: LLMEngineOption.gemini.defaultModelName,
                authMode: .bearer,
                apiKeyRef: APISecretKey.llmGemini.rawValue,
                headers: [],
                request: LLMProviderRequestConfig(
                    apiStyle: "custom",
                    path: "/v1beta/models/{model}:streamGenerateContent",
                    extraParamsJSON: "{}"
                )
            ),
            LLMProviderProfile(
                id: "builtin.llm.deepseek",
                type: .builtIn,
                displayName: "DeepSeek",
                engine: .deepSeek,
                baseURL: LLMEngineOption.deepSeek.defaultBaseURL,
                models: ["deepseek-chat", "deepseek-reasoner"],
                defaultModel: LLMEngineOption.deepSeek.defaultModelName,
                authMode: .bearer,
                apiKeyRef: APISecretKey.llmDeepSeek.rawValue,
                headers: [],
                request: LLMProviderRequestConfig.openAIDefault
            ),
            LLMProviderProfile(
                id: "builtin.llm.groq",
                type: .builtIn,
                displayName: "Groq",
                engine: .groq,
                baseURL: LLMEngineOption.groq.defaultBaseURL,
                models: ["llama-3.1-70b-versatile", "llama-3.3-70b-versatile", "mixtral-8x7b-32768"],
                defaultModel: LLMEngineOption.groq.defaultModelName,
                authMode: .bearer,
                apiKeyRef: APISecretKey.llmGroq.rawValue,
                headers: [],
                request: LLMProviderRequestConfig.openAIDefault
            ),
        ]
    }
}
