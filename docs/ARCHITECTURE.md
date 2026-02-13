# Architecture

## System Overview

GhostType is a native macOS voice productivity app with a two-process architecture:

- **Swift Frontend** (SwiftUI + AppKit): UI, global hotkeys, audio capture, workflow orchestration, text insertion.
- **Python Backend** (MLX): Local speech recognition (ASR) and language model (LLM) inference via a FastAPI service.

Communication between Swift and Python happens over a local WebSocket connection (`127.0.0.1:8765`).

## Data Flow

```
User presses hotkey
    → GlobalHotkeyManager fires start event
    → AudioCaptureService begins recording (16kHz mono PCM16 WAV)
    → HUDPanelController shows recording status

User releases hotkey
    → AudioCaptureService stops, normalizes audio
    → InferenceCoordinator selects provider (local or cloud)

Local path:
    → PythonStreamRunner sends audio to Python service
    → service.py: Whisper ASR → raw transcript
    → service.py: Qwen LLM → rewritten/structured text
    → Streaming response back to Swift

Cloud path:
    → CloudInferenceProvider sends audio to cloud ASR API
    → CloudInferenceProvider sends transcript to cloud LLM API
    → Streaming response back to Swift

    → ResultOverlayController displays result
    → PasteCoordinator inserts text into target app
    → HistoryStore saves to SQLite
```

## Three Workflow Modes

| Mode | Description | Default Hotkey |
|------|------------|----------------|
| Dictation | Voice → structured text, inserted at cursor | Right Option |
| Ask | Voice question + selected text context → answer | Right Option + Space |
| Translate | Voice → translation to target language | Right Option + Right Cmd |

## Project Structure

```
GhostType/
├── macos/                          # All Swift source files
│   ├── GhostTypeApp.swift          # App entry point (@main)
│   ├── AppDelegate.swift           # Startup, permissions, lifecycle
│   ├── AppState.swift              # Global state aggregation
│   ├── InferenceCoordinator.swift  # Main workflow orchestrator
│   ├── BackendManager.swift        # Python process management
│   ├── AudioCaptureService.swift   # Microphone recording + normalization
│   ├── GlobalHotkeyManager.swift   # System-wide hotkey listener
│   ├── PasteCoordinator.swift      # Text insertion into target apps
│   ├── HistoryStore.swift          # SQLite history database
│   ├── CloudInferenceProvider*.swift  # Cloud API integration
│   ├── PythonStreamRunner.swift    # Local Python IPC client
│   ├── PromptTemplateStore.swift   # Prompt preset management
│   ├── ContextRoutingState.swift   # App-aware prompt switching
│   └── Settings/                   # Settings UI modules
├── python/
│   ├── service.py                  # FastAPI inference service
│   ├── enhancement_engine.py       # Audio enhancement utilities
│   ├── audio_io.py                 # Audio I/O helpers
│   └── requirements.txt            # Python dependencies
├── tests/                          # Swift unit tests
├── scripts/                        # Build & utility scripts
├── browser/                        # Browser extension for context
├── docs/                           # Documentation
├── GhostType/
│   ├── Info.plist                  # App metadata
│   └── GhostType.entitlements      # Sandbox entitlements
└── project.yml                     # XcodeGen configuration
```

## Key Swift Modules

| Module | Responsibility |
|--------|---------------|
| `AppState` | Aggregates `EngineConfig`, `UserPreferences`, `RuntimeState`, `ContextRoutingState`, `PromptTemplateStore` |
| `InferenceCoordinator` | Orchestrates recording → inference → display → paste → history |
| `BackendManager` | Manages Python venv creation, pip install, process lifecycle, health checks |
| `GlobalHotkeyManager` | Listens for global hotkeys via CGEvent tap |
| `AudioCaptureService` | Records from microphone, applies VAD/enhancement, normalizes to WAV |
| `PasteCoordinator` | Inserts text via Accessibility API (preferred) or clipboard fallback |
| `PromptTemplateStore` | 20+ built-in prompt presets with custom preset support |
| `ContextRoutingState` | Auto-switches prompt presets based on foreground app or browser domain |

## Python Service Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/health` | GET | Health check, model status |
| `/dictate/stream` | POST | ASR + LLM rewrite, streaming response |
| `/ask/stream` | POST | ASR + LLM Q&A with context, streaming |
| `/translate/stream` | POST | ASR + LLM translation, streaming |
| `/style/clear` | POST | Clear style profile cache |

## Data Persistence

| Data | Location |
|------|----------|
| History | `~/Library/Application Support/GhostType/history.sqlite` |
| Style Profile | `~/Library/Application Support/GhostType/state/style_profile.json` |
| Dictionary | `~/Library/Application Support/GhostType/dictionary.json` |
| Audio Captures | `~/Library/Application Support/GhostType/AudioCaptures/` |
| User Preferences | `UserDefaults` (prefix `GhostType.*`) |
| API Keys | macOS Keychain |
| Python venv | `~/Library/Application Support/GhostType/.venv/` |

---

# 架构文档

## 系统概览

GhostType 是一个原生 macOS 语音效率应用，采用双进程架构：

- **Swift 前端**（SwiftUI + AppKit）：UI、全局快捷键、音频采集、工作流编排、文本回填。
- **Python 后端**（MLX）：本地语音识别（ASR）和语言模型（LLM）推理，通过 FastAPI 服务运行。

Swift 与 Python 之间通过本地 WebSocket 连接通信（`127.0.0.1:8765`）。

## 数据流

```
用户按下快捷键
    → GlobalHotkeyManager 触发开始事件
    → AudioCaptureService 开始录音（16kHz 单声道 PCM16 WAV）
    → HUDPanelController 显示录音状态

用户松开快捷键
    → AudioCaptureService 停止并规范化音频
    → InferenceCoordinator 选择推理提供者（本地或云端）

本地路径：
    → PythonStreamRunner 发送音频到 Python 服务
    → service.py: Whisper ASR → 原始转写
    → service.py: Qwen LLM → 重写/结构化文本
    → 流式响应返回 Swift

云端路径：
    → CloudInferenceProvider 发送音频到云端 ASR API
    → CloudInferenceProvider 发送转写文本到云端 LLM API
    → 流式响应返回 Swift

    → ResultOverlayController 显示结果
    → PasteCoordinator 将文本插入目标应用
    → HistoryStore 保存到 SQLite
```

## 三种工作模式

| 模式 | 描述 | 默认快捷键 |
|------|------|-----------|
| 听写 (Dictation) | 语音 → 结构化文本，插入光标位置 | 右 Option |
| 问答 (Ask) | 语音提问 + 选中文本上下文 → 回答 | 右 Option + 空格 |
| 翻译 (Translate) | 语音 → 翻译为目标语言 | 右 Option + 右 Cmd |

## 关键模块

| 模块 | 职责 |
|------|------|
| `AppState` | 聚合 EngineConfig、UserPreferences、RuntimeState、ContextRoutingState、PromptTemplateStore |
| `InferenceCoordinator` | 编排 录音 → 推理 → 显示 → 粘贴 → 历史记录 |
| `BackendManager` | 管理 Python 虚拟环境创建、pip 安装、进程生命周期、健康检查 |
| `PromptTemplateStore` | 20+ 内置提示词预设，支持自定义预设 |
| `ContextRoutingState` | 根据前台应用或浏览器域名自动切换提示词预设 |
