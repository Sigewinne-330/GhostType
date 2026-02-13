import Foundation

enum ASREngineOption: String, CaseIterable, Identifiable, Codable {
    case localMLX = "Local Apple Silicon (MLX)"
    case localHTTPOpenAIAudio = "Local HTTP (OpenAI Audio API compatible)"
    case openAIWhisper = "Cloud OpenAI Whisper API"
    case deepgram = "Cloud Deepgram API"
    case assemblyAI = "Cloud AssemblyAI API"
    case groq = "Cloud Groq API"
    case geminiMultimodal = "Gemini Multimodal"
    case customOpenAICompatible = "Cloud Custom OpenAI-Compatible ASR"

    var id: String { rawValue }

    var defaultBaseURL: String {
        switch self {
        case .localMLX:
            return ""
        case .localHTTPOpenAIAudio:
            return LocalASRModelCatalog.defaultLocalHTTPBaseURL
        case .openAIWhisper:
            return "https://api.openai.com/v1"
        case .deepgram:
            return "https://api.deepgram.com"
        case .assemblyAI:
            return "https://api.assemblyai.com"
        case .groq:
            return "https://api.groq.com/openai/v1"
        case .geminiMultimodal:
            return "https://generativelanguage.googleapis.com"
        case .customOpenAICompatible:
            return "https://api.openai.com/v1"
        }
    }

    var defaultModelName: String {
        switch self {
        case .localMLX:
            return ""
        case .localHTTPOpenAIAudio:
            return LocalASRModelCatalog.defaultLocalHTTPModelName
        case .openAIWhisper:
            return "whisper-1"
        case .deepgram:
            return "nova-2"
        case .assemblyAI:
            return "best"
        case .groq:
            return "whisper-large-v3-turbo"
        case .geminiMultimodal:
            return "gemini-2.0-flash"
        case .customOpenAICompatible:
            return "whisper-1"
        }
    }
}

enum LLMEngineOption: String, CaseIterable, Identifiable, Codable {
    case localMLX = "Local Apple Silicon (MLX)"
    case openAI = "Cloud OpenAI API"
    case openAICompatible = "Cloud OpenAI-Compatible API"
    case customOpenAICompatible = "Cloud Custom OpenAI-Compatible LLM"
    case azureOpenAI = "Cloud Azure OpenAI API"
    case anthropic = "Cloud Anthropic API"
    case gemini = "Cloud Google Gemini API"
    case deepSeek = "Cloud DeepSeek API"
    case groq = "Cloud Groq API"

    var id: String { rawValue }

    var defaultBaseURL: String {
        switch self {
        case .localMLX:
            return ""
        case .openAI:
            return "https://api.openai.com/v1"
        case .openAICompatible:
            return "https://api.openai.com/v1"
        case .customOpenAICompatible:
            return "https://api.openai.com/v1"
        case .azureOpenAI:
            return "https://YOUR_RESOURCE_NAME.openai.azure.com"
        case .anthropic:
            return "https://api.anthropic.com"
        case .gemini:
            return "https://generativelanguage.googleapis.com"
        case .deepSeek:
            return "https://api.deepseek.com/v1"
        case .groq:
            return "https://api.groq.com/openai/v1"
        }
    }

    var defaultModelName: String {
        switch self {
        case .localMLX:
            return "mlx-community/Qwen2.5-1.5B-Instruct-4bit"
        case .openAI:
            return "gpt-4o-mini"
        case .openAICompatible:
            return "gpt-4o-mini"
        case .customOpenAICompatible:
            return "gpt-4o-mini"
        case .azureOpenAI:
            return "gpt-4o-mini"
        case .anthropic:
            return "claude-3-5-haiku-latest"
        case .gemini:
            return "gemini-2.0-flash"
        case .deepSeek:
            return "deepseek-chat"
        case .groq:
            return "llama-3.1-70b-versatile"
        }
    }
}
