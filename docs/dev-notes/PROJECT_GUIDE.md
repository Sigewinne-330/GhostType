# GhostType 项目全景文档

## 1. 项目定位
GhostType 是一个 macOS 原生语音效率工具，目标是把“录音 -> 转写 -> 文本处理 -> 回填输入框”做成跨应用统一能力。

核心特性：
- 全局快捷键触发，支持任意前台应用。
- 三种模式：`Dictation`（听写整理）、`Ask`（语音问答）、`Translate`（语音翻译）。
- 同时支持本地推理（Python/MLX）与云端推理（多厂商 API）。
- 支持上下文路由与提示词预设自动切换。
- 支持 Smart Insert（直写优先、失败回退粘贴、剪贴板恢复）。

## 2. 高层架构

### 2.1 Swift 侧（macOS App）
- UI 层：SwiftUI + AppKit（设置页、HUD、结果浮层）。
- 编排层：`InferenceCoordinator`。
- 音频层：`AudioCaptureService`。
- 推理层：
  - 本地：`PythonStreamRunner` + `BackendManager`
  - 云端：`CloudInferenceProvider`
- 回填层：`TextInserter` + `PasteCoordinator` + `TargetResolver`
- 状态层：`AppState` 聚合 `EngineConfig`、`UserPreferences`、`RuntimeState`、`ContextRoutingState`、`PromptTemplateStore`。

### 2.2 Python 侧（本地服务）
- 入口：`python/service.py`。
- 角色：本地 ASR/LLM 推理、流式输出、健康检查、部分风格化能力。

## 3. 运行链路
1. `GlobalHotkeyManager` 监听快捷键开始/结束。
2. `AudioCaptureService` 开始录音并采集音频。
3. `InferenceCoordinator` 锁定会话上下文，路由到本地或云端 provider。
4. provider 流式返回 token，更新 HUD/Overlay。
5. 结束时写入历史，并通过 `TextInserter` 将结果写回目标应用。

## 4. 关键模块与职责

### 4.1 提示词与上下文
- `PromptTemplateStore.swift`：提示词 CRUD、持久化。
- `PromptLibraryBuiltins.swift`：内置预设库。
- `PromptPresetMigration.swift`：旧预设 ID/名称迁移。
- `ContextRoutingState.swift` + `ContextPromptSwitching.swift`：上下文快照、规则匹配、决策应用。

### 4.2 引擎配置
- `EngineConfig.swift`：主引擎配置对象。
- `EngineProviderDefaults.swift`：ASR/LLM 内置 provider 默认定义。
- `DeepgramConfig.swift`（`DeepgramSettings`）：Deepgram 专属参数与持久化。

### 4.3 推理与解析
- `CloudInferenceProvider+ASRRuntime.swift` / `+LLMRuntime.swift`：云端执行。
- `CloudInferenceProvider+ResponseParsing.swift`：统一 JSON/Text 响应解析。
- `CloudInferenceProvider+Support.swift`：重试、HTTP 公共逻辑、Probe 客户端。
- `InferenceTextPostProcessor.swift`：去重与场景后处理。
- `DictationContextManager.swift`：Dictation 会话上下文锁定。

### 4.4 设置页
主要位于 `macos/Settings/`：
- `GeneralSettingsPane`（常规）
- `EnginesSettingsPane*`（引擎与模型）
- `PromptTemplatesPane`（提示词与预设）
- `HistoryPane`（历史）
- `PersonalizationPane`（个性化）
- `DeveloperSupportPane` / `ConsolePane`（开发与日志）

## 5. 数据与持久化
- `UserDefaults`：`GhostType.*` 前缀配置项。
- Keychain：云端凭证。
- `~/Library/Application Support/GhostType/history.sqlite`：历史记录。
- `~/Library/Application Support/GhostType/provider_registry.json`：自定义 provider 列表。
- `~/Library/Application Support/GhostType/state/`：词典/风格等状态文件。

## 6. 当前重构状态（对应 REFACTOR_PRD）
- 已完成：
  - PromptTemplateStore 拆分（builtins + migration）。
  - EngineConfig provider 默认定义抽离。
  - 自定义 provider 归一化泛型收敛。
  - InferenceCoordinator 后处理与上下文管理拆分。
  - CloudInferenceProvider 解析逻辑去重。
  - optionalAPIKey 缺失日志补齐。
  - ASR chunk size 常量化。
  - 死代码候选文件验证（均仍在使用）。
- 已知遗留：
  - 若切换到 Swift 6 严格并发模式，`PromptPresetMigration.swift` 存在 main actor 隔离 warning，需要额外清理。

## 7. 本地开发与验证

### 7.1 构建
```bash
xcodegen generate
xcodebuild -project GhostType.xcodeproj -scheme GhostType -configuration Debug -destination 'platform=macOS,arch=arm64' build
```

### 7.2 测试
```bash
xcodebuild -project GhostType.xcodeproj -scheme GhostType -configuration Debug -destination 'platform=macOS,arch=arm64' test
```

### 7.3 运行注意
- 需要麦克风与辅助功能权限。
- 推荐始终从 `/Applications/GhostType.app` 启动，避免多副本混淆。

## 8. 扩展建议
- 新增云厂商时优先扩展 `EngineProviderDefaults` + `CloudInferenceProvider+*Runtime`，并把解析逻辑放入 `CloudInferenceProvider+ResponseParsing.swift`。
- 涉及 Dictation 文本清洗时优先放入 `InferenceTextPostProcessor.swift`，避免把逻辑再塞回 `InferenceCoordinator`。
- 涉及 Deepgram 专属配置时优先改 `DeepgramSettings`，保持 `EngineConfig` 轻量。
