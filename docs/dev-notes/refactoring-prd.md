# GhostType 代码质量改进 PRD

**版本：** 1.0
**日期：** 2026-02-11
**目标读者：** 开发者（含 AI 辅助编程场景）

---

## 背景与目标

GhostType 当前代码架构清晰、有一定工程规范，但随着功能快速堆叠，出现了若干"早期屎山苗头"。如果不主动干预，这些问题会在后续每次新增功能时成倍放大。

本 PRD 的目标不是重写，而是**精准止血**——在不破坏现有功能的前提下，对最危险的几个点做有计划的重构，把技术债控制在可管理范围内。

---

## 问题清单与优先级

| # | 问题 | 风险 | 优先级 |
|---|------|------|--------|
| P1 | `AppState` 是 God Object，持续膨胀中 | 高：每个新功能都往里塞，最终无法理解 | 🔴 必做 |
| P2 | `SettingsView.swift` 接近 2000 行 | 高：UI 逻辑混乱，难以新增设置项 | 🔴 必做 |
| P3 | `AppDelegate` 承担过多职责 | 中：单点故障，难以测试 | 🟡 重要 |
| P4 | 测试覆盖率接近零 | 中：重构本身无安全网 | 🟡 重要 |
| P5 | `CloudInferenceProvider` 碎片化（9 个文件） | 低：可读性差，但功能稳定 | 🟢 可选 |

---

## P1：拆解 AppState（God Object）

### 现状

`AppState.swift` 目前 **1,649 行**，包含：
- 所有 UI 枚举定义（`PipelineStage`、`WorkflowMode`、`UILanguageOption` 等 10+ 个）
- 所有运行时状态（录音、推理、后端进程）
- 所有用户偏好设置（ASR 引擎、LLM 引擎、快捷键、语言、内存策略等）
- 通知名称（`Notification.Name` 扩展）
- 快捷键验证逻辑（`HotkeyValidationError`、`HotkeyShortcut`）
- UserDefaults 持久化逻辑

**症状：** `AppDelegate`、`SettingsView`、`PythonBridge`、`CloudInferenceProvider` 全部直接引用 `AppState.shared`，任何一处修改都可能引发全局副作用。

### 目标

将 `AppState` 拆分为 **4 个职责单一的模块**，通过组合而非继承的方式维持兼容性。

### 具体拆分方案

#### 1.1 新建 `EngineConfig.swift`

职责：保存用户选择的引擎配置（引擎选项、API 端点、模型名称）。

```
EngineConfig（ObservableObject）
├── asrEngine: ASREngineOption
├── asrBaseURL: String
├── asrModelName: String
├── llmEngine: LLMEngineOption
├── llmBaseURL: String
├── llmModelName: String
└── shouldUseLocalProvider: Bool（计算属性）
```

持久化：通过 `UserDefaults` 存储，key 前缀 `engineConfig.*`。

#### 1.2 新建 `UserPreferences.swift`

职责：保存用户偏好（语言、快捷键、内存策略、音频增强等）。

```
UserPreferences（ObservableObject）
├── uiLanguage: UILanguageOption
├── outputLanguage: OutputLanguageOption
├── targetLanguage: TargetLanguageOption
├── memoryTimeout: MemoryTimeoutOption
├── audioEnhancementEnabled: Bool
├── audioEnhancementMode: AudioEnhancementModeOption
├── removeRepeatedTextEnabled: Bool
├── dictationHotkey: HotkeyShortcut
├── askHotkey: HotkeyShortcut
└── translateHotkey: HotkeyShortcut
```

持久化：通过 `UserDefaults` 存储，key 前缀 `prefs.*`。

#### 1.3 新建 `RuntimeState.swift`

职责：保存仅在运行时存在、不需要持久化的状态。

```
RuntimeState（ObservableObject）
├── stage: PipelineStage
├── backendStatus: String
├── processStatus: String
├── activeModeText: String
├── lastASRDetectedLanguage: String
├── lastLLMOutputLanguagePolicy: String
└── currentTranscript: String
```

#### 1.4 保留瘦身后的 `AppState.swift`

`AppState` 保留为一个**组合容器**，持有上述三个对象，同时保留 `AppState.shared` 单例（避免全局改动）：

```swift
// AppState.swift（拆分后）
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    let engine: EngineConfig       // 引擎配置
    let prefs: UserPreferences     // 用户偏好
    let runtime: RuntimeState      // 运行时状态

    // 向后兼容：保留高频访问的计算属性，转发给子模块
    var asrEngine: ASREngineOption {
        get { engine.asrEngine }
        set { engine.asrEngine = newValue }
    }
    // ... 其他高频属性类似处理
}
```

这样现有的 `state.asrEngine` 引用**无需改动**，但内部已分层。

#### 1.5 将枚举定义移出 AppState

将 `AppState.swift` 顶部的所有 enum 定义移到独立文件：

| 移动目标文件 | 内容 |
|------------|------|
| `EngineConfig.swift` | `ASREngineOption`, `LLMEngineOption`, `LocalASRModelOption` |
| `UserPreferences.swift` | `UILanguageOption`, `TargetLanguageOption`, `OutputLanguageOption`, `MemoryTimeoutOption`, `AudioEnhancementModeOption` |
| `HotkeyShortcut.swift`（新建） | `HotkeyShortcut`, `HotkeyValidationError`, `WorkflowMode` |
| `AppNotifications.swift`（新建） | `Notification.Name` 扩展 |
| `RuntimeState.swift` | `PipelineStage` |

### 验收标准

- [ ] `AppState.swift` 行数 < 200 行
- [ ] `EngineConfig`、`UserPreferences`、`RuntimeState` 各自独立文件，各自 < 300 行
- [ ] 现有所有 `AppState.shared.xxx` 访问路径编译通过，不需要改动调用方
- [ ] 现有功能全部正常（手动回归：Dictation、Ask、Translate 三个工作流）

---

## P2：拆解 SettingsView（巨型 View）

### 现状

`SettingsView.swift` **1,973 行**，包含多个 Settings Pane（已有 `GeneralSettingsPane`、`DictionarySettingsView` 等独立文件，但核心仍混杂）。

### 目标

将 SettingsView 拆分为职责明确的 View 组件，每个文件 < 400 行。

### 拆分方案

按设置面板拆分，建立 `Settings/` 目录：

```
macos/
└── Settings/
    ├── SettingsContainerView.swift     # 导航容器，< 100 行
    ├── GeneralSettingsPane.swift       # 快捷键与常规（已存在，迁移过来）
    ├── ASRSettingsPane.swift           # ASR 引擎配置
    ├── LLMSettingsPane.swift           # LLM 引擎配置
    ├── AudioSettingsPane.swift         # 音频增强设置
    ├── HistorySettingsPane.swift       # 历史记录设置
    └── AboutPane.swift                 # 关于页面
```

**关键原则：**

1. **每个 Pane 只接受它需要的状态**，不整体注入 `AppState`：

```swift
// 错误：注入整个 AppState
struct ASRSettingsPane: View {
    @ObservedObject var state: AppState  // ❌ 引入所有状态

// 正确：只注入这个 Pane 需要的状态
struct ASRSettingsPane: View {
    @ObservedObject var engineConfig: EngineConfig  // ✅ 精准依赖
```

2. **UI 相关的局部状态保持在 View 内部**（`@State`），不上浮到 AppState。

3. **复杂的子组件继续拆分**，例如 Provider 选择器：

```swift
// 从 ASRSettingsPane 再拆出：
struct ProviderPickerRow: View { ... }
struct APIKeyInputRow: View { ... }
struct ModelNameInputRow: View { ... }
```

### 验收标准

- [ ] `SettingsView.swift`（或新的容器文件）行数 < 150 行
- [ ] 每个 Pane 文件 < 400 行
- [ ] 每个 Pane 的 `@ObservedObject` 只引用它实际使用的状态模块
- [ ] Settings 窗口所有面板正常显示，数据双向绑定正常

---

## P3：收窄 AppDelegate 职责

### 现状

`AppDelegate` **1,025 行**，承担了：
- 初始化所有组件（hudPanel、audioCapture、cloudProvider 等 10+ 个）
- 全局热键事件路由
- 推理会话生命周期管理（开始、停止、超时、错误处理）
- 粘贴逻辑
- 通知处理

### 目标

`AppDelegate` 只做**启动编排**和**事件路由**，将业务逻辑下沉到专职类。

### 拆分方案

#### 3.1 新建 `InferenceCoordinator.swift`

将推理会话管理逻辑从 `AppDelegate` 中剥离：

```
InferenceCoordinator
├── startInference(mode:audioURL:)
├── stopInference()
├── handleFirstToken()
├── handleStreamToken(_ token: String)
├── handleInferenceComplete()
├── handleInferenceError(_ error: Error)
└── watchdog: InferenceWatchdog（内部类）
```

`AppDelegate` 中的 `handleModeStop`、`runInference`、`handleStreamToken` 等方法整体迁移到这里。

#### 3.2 新建 `PasteCoordinator.swift`

```
PasteCoordinator
├── paste(_ text: String, to app: NSRunningApplication?)
└── scheduleDelayedPaste(_ text: String)
```

#### 3.3 拆分后的 AppDelegate 结构

```swift
// AppDelegate.swift（重构后，约 250 行）
final class AppDelegate: NSObject, NSApplicationDelegate {
    // 持有协调器，不直接持有底层服务
    private let inferenceCoordinator: InferenceCoordinator
    private let pasteCoordinator: PasteCoordinator
    private let monitor: GlobalHotkeyManager

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 纯粹的启动序列，< 50 行
    }

    // 只保留：热键回调路由到 InferenceCoordinator
    // 只保留：通知观察者路由到相应协调器
}
```

### 验收标准

- [ ] `AppDelegate.swift` 行数 < 300 行
- [ ] `InferenceCoordinator` 包含完整的推理生命周期逻辑
- [ ] AppDelegate 中不再直接调用 `audioCapture`、`cloudProvider`、`localProvider`

---

## P4：建立基础测试安全网

### 现状

整个项目只有 2 个测试文件（`KeychainServiceTests.swift`、`DeepgramConfigTests.swift`），覆盖率接近零。

**这是最大的风险**：在没有测试的情况下做上述重构，容易引入隐蔽 Bug。

### 目标

在执行 P1、P2、P3 重构**之前**，先为关键路径补充单元测试，让重构有安全网。

### 优先补充的测试

#### 4.1 EngineConfig 持久化测试

```swift
// Tests/EngineConfigTests.swift
func testASREngineRoundTrip() {
    // 设置 → 持久化 → 重新读取 → 验证一致
}

func testDefaultValues() {
    // 验证首次安装时的默认值正确
}
```

#### 4.2 UserPreferences 快捷键测试

```swift
// Tests/UserPreferencesTests.swift
func testHotkeyShortcutSaveAndLoad() { ... }
func testNoHotkeyConflict() { ... }
func testHotkeyConflictDetection() { ... }
```

#### 4.3 InferenceCoordinator 状态机测试（P3 完成后添加）

```swift
// Tests/InferenceCoordinatorTests.swift
func testStartWhileAlreadyRunning() {
    // 验证不允许并发推理
}
func testWatchdogFiresOnTimeout() { ... }
func testSessionIDTracking() { ... }
```

#### 4.4 HotkeyShortcut 逻辑测试

```swift
// Tests/HotkeyShortcutTests.swift
func testModifierOnlyShortcut() { ... }
func testDisplayText() { ... }
func testEquality() { ... }
```

### 验收标准

- [ ] P1 执行前：EngineConfig、UserPreferences 的持久化测试通过
- [ ] P2 执行前：现有 SettingsView 的快照测试或关键 Binding 测试
- [ ] P3 执行后：InferenceCoordinator 核心状态机有测试覆盖
- [ ] CI 配置中测试自动运行（如已有 `scripts/` 中的脚本，补充测试步骤）

---

## P5：整合 CloudInferenceProvider（可选，低优先级）

### 现状

`CloudInferenceProvider` 被拆成 9 个文件，原意是按功能分层，但造成代码追踪困难。

### 建议

不急于合并文件，而是**在下次修改某个文件时顺手做两件事**：

1. 在每个 extension 文件顶部加一行注释说明职责和入口：

```swift
// MARK: - ASR Runtime
// 负责：从音频 URL 执行 ASR 请求，处理多 provider 路由和错误回退
// 对外入口：transcribe(audioURL:sessionID:)
extension CloudInferenceProvider { ... }
```

2. 保证每个文件只做一件事（目前 `+Support.swift` 992 行，混杂了太多辅助逻辑），在下次改动时拆开。

---

## 执行顺序建议

```
Week 1: P4（先建安全网）
  └─ 补充 EngineConfig、HotkeyShortcut 的单元测试

Week 2: P1（最高价值）
  ├─ 移出枚举定义到独立文件
  ├─ 拆分 EngineConfig、UserPreferences、RuntimeState
  └─ 保留 AppState 作向后兼容的组合容器

Week 3: P2
  ├─ 建立 Settings/ 目录结构
  └─ 按面板拆分 SettingsView，精准注入状态依赖

Week 4: P3（可与 P2 并行）
  ├─ 新建 InferenceCoordinator
  └─ AppDelegate 瘦身

持续: P5（随改随做）
  └─ 每次碰到 CloudInferenceProvider 文件时加注释、整理边界
```

---

## 不要做的事（避坑）

1. **不要整体重写**。分阶段小步替换，每步都能编译运行。
2. **不要改 API 边界**（保持 `AppState.shared.xxx` 的访问路径），减少调用方改动。
3. **不要在重构时顺手加新功能**，重构 PR 和功能 PR 分开。
4. **P1 之前不要动 P2**，因为 SettingsView 深度依赖 AppState，先稳定 AppState 的边界。
5. **不要把 `CloudInferenceProvider` 的 9 个文件合并成 1 个**，那会从碎片化变成单文件怪兽。

---

## 成功标准

完成后，判断是否"止血成功"的指标：

| 指标 | 当前 | 目标 |
|------|------|------|
| AppState.swift 行数 | 1,649 行 | < 200 行 |
| SettingsView 最大单文件 | 1,973 行 | < 400 行 |
| AppDelegate.swift 行数 | 1,025 行 | < 300 行 |
| 测试文件数 | 2 个 | > 8 个 |
| 新增 Provider 时需要改动的文件数 | 5+ 个 | ≤ 3 个 |
