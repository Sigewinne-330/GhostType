# GhostType Agent Guide

## 目录
- [1. 文档目的](#1-文档目的)
- [2. 项目介绍](#2-项目介绍)
- [3. 问题排障手册](#3-问题排障手册)
- [4. 维护规则](#4-维护规则)

## 1. 文档目的
本文件只保留两类信息：
- 项目整体介绍（给协作者快速建立上下文）
- 常见问题的标准排障方案（优先可执行步骤）

不在本文件中维护路线图、功能设计细节或阶段性开发指令。

## 2. 项目介绍
GhostType 是一个 macOS 原生语音效率工具，定位是“跨应用语音输入总线”：
- 用全局快捷键在任意前台应用触发语音工作流
- 统一完成录音、转写、改写/问答/翻译
- 将结果自动粘贴回目标输入位置

### 2.1 三条核心工作流
- Dictation（听写整理）：语音转文字并按提示词做结构化重写。
- Ask（语音问答）：读取当前选中文本作为上下文，再用语音提问。
- Translate（语音翻译）：语音输入后直接翻译到目标语言。

默认快捷键（可在设置中改）：
- Dictation：`Right Option`
- Ask：`Right Option + Space`
- Translate：`Right Option + Right Cmd`

### 2.2 运行时主链路
1. `GlobalHotkeyManager` 监听全局快捷键并发出开始/结束事件。
2. `AudioCaptureService` 负责录音和音频增强参数应用。
3. `InferenceCoordinator` 作为主编排器，决定调用本地还是云端推理。
4. 推理结果流式回传后，`ResultOverlayController` 展示文本，`HUDPanelController` 展示状态。
5. `PasteCoordinator` 将结果写回前台应用；同时 `HistoryStore` 写入历史数据库。

### 2.3 推理架构与路由
- 路由规则由 `InferenceProviderFactory` 决定：
  - ASR 与 LLM 都是本地（`localMLX`）时走本地 Provider。
  - 其余情况（含混合配置）走云端 Provider。
- 本地链路：
  - Swift 侧：`PythonStreamRunner`
  - Python 侧：`python/service.py`（FastAPI）
  - 主要接口：`/dictate/stream`、`/ask/stream`、`/translate/stream`、`/health`、`/style/clear`
- 云端链路：
  - Swift 侧：`CloudInferenceProvider`（`URLSession` 直连云 API，不依赖本地 Python 服务）

### 2.4 上下文提示词自动切换
- 状态与规则：
  - `ContextRoutingState` 维护开关、默认预设、当前预设、路由规则。
  - `ContextPromptSwitching` 负责快照采集与规则匹配。
- 快照来源：
  - 当前前台 App（bundle id）
  - 浏览器域名/窗口标题
  - 外部通道写入的 `browser-context-hint.json`
- 配置入口：
  - 设置 -> 提示词与预设 -> 自动切换
  - 设置 -> 提示词与预设 -> 管理路由规则

### 2.5 关键模块速查（Swift）
- `macos/AppDelegate.swift`：应用启动编排、权限请求、单实例与生命周期管理。
- `macos/AppState.swift`：全局状态聚合（engine/prefs/runtime/prompts/context）与旧键迁移。
- `macos/InferenceCoordinator.swift`：录音、推理、UI 状态、粘贴、历史写入的主流程。
- `macos/BackendManager.swift`：本地 Python 服务的启动、健康检查、回收与停止。
- `macos/PromptTemplateStore.swift`：提示词预设库、内置模板、迁移与持久化。
- `macos/Settings/*`：设置页分模块实现（常规、引擎、提示词、历史、个性化、开发者、日志）。
- `macos/HistoryStore.swift`：SQLite 历史记录读写。

### 2.6 Python 侧职责
- `python/service.py`：本地推理服务入口，负责 ASR、LLM 推理、流式输出和部分音频后处理。
- `python/inference_pipeline.py`：推理流水线辅助逻辑。
- `python/requirements.txt`：本地服务依赖。

### 2.7 数据落盘与配置位置
- `~/Library/Application Support/GhostType/history.sqlite`：历史记录数据库。
- `~/Library/Application Support/GhostType/state/style_profile.json`：风格配置。
- `~/Library/Application Support/GhostType/dictionary.json`：词典。
- `UserDefaults`：`GhostType.*` 前缀键（已包含从 `LocalTypeless.*` 到 `GhostType.*` 的迁移逻辑）。
- macOS Keychain：云厂商 API Key（不落盘明文到 UserDefaults）。

### 2.8 设置页面信息架构
- 快捷键与常规（Hotkeys & General）
- 引擎与模型（Engines & Models）
- 提示词与预设（Prompts & Presets）
- 历史记录（History）
- 个性化与词典（Personalization & Dictionary）
- 开发者与支持（Developer & Support）
- 运行日志（Runtime Logs）

### 2.9 开发环境与依赖前提
- 平台：macOS（当前工程部署目标为 macOS 14+）。
- 架构：Apple Silicon 优先（本地 MLX 推理链路依赖 Apple Silicon）。
- 权限：
  - 麦克风权限（录音）
  - 辅助功能权限（全局快捷键与模拟输入）

### 2.10 运行与命名约束
- 应用统一命名为 `GhostType`。
- 目标安装路径为 `/Applications/GhostType.app`。
- `Info.plist` 需保持：
  - `CFBundleName = GhostType`
  - `CFBundleDisplayName = GhostType`
  - `LSMultipleInstancesProhibited = YES`

### 2.11 当前代码组织（重构后）
- 提示词：`PromptTemplateStore` 负责状态与持久化；`PromptLibraryBuiltins` 负责内置模板；`PromptPresetMigration` 负责旧 ID/名称迁移。
- 引擎：`EngineConfig` 负责主配置；`EngineProviderDefaults` 维护内置 ASR/LLM provider 定义；`DeepgramSettings` 独立承接 Deepgram 参数与持久化。
- 推理编排：`InferenceCoordinator` 保持主流程；文本后处理迁移到 `InferenceTextPostProcessor`；Dictation 会话上下文锁定迁移到 `DictationContextManager`。
- 云端解析：统一收敛到 `CloudInferenceProvider+ResponseParsing.swift`，避免 `EngineProbeClient` 与 Runtime 重复解析实现。

### 2.12 详细文档
- 详细项目文档见：`docs/PROJECT_GUIDE.md`

## 3. 问题排障手册

### 3.0 调试产物保护红线（此次错误强制修正）
背景：
- 本次已发生过“为处理双图标/双条目，误删 `DerivedData` 与 `./.build` 下 `GhostType.app`，导致 Debug 构建丢失并造成‘改动没了’误判”的错误。

强制规则：
- 未经确认，禁止执行任何针对以下路径的删除：`~/Library/Developer/Xcode/DerivedData/**/GhostType.app`、`./.build/**/GhostType.app`、`./build/**/GhostType.app`。
- 看到两个 GhostType 条目时，先按 3.4 判断是否只是 Spotlight/LaunchServices 索引重复，不能直接清理构建产物。
- 必须先按 3.2 完成“重新构建 + 覆盖安装 `/Applications/GhostType.app`”，确认可运行后，才允许清理旧调试包路径。
- 如需删除调试产物，先向用户明确说明影响并获得确认，再执行删除。

### 3.1 同时出现多个 App 副本（高优先级）
现象：
- Dock/Spotlight/Finder 中出现多个 GhostType 或历史名称副本
- 启动后行为不一致（有时新功能存在，有时不存在）

⚠️ 本次错误复盘（必须遵守）：
- **不要在未确认场景前直接删除 `DerivedData` / `./.build` 里的 `GhostType.app`**。
- 这些目录里的 `GhostType.app` 可能正是当前开发调试构建；误删会导致“Debug 构建丢失”，并引发“改动没了”的误判。
- 若用户仍在开发态，优先执行 3.2 的“重新构建 + 覆盖安装”。

检查命令：
```bash
find /Applications -maxdepth 2 \( -iname "*GhostType*.app" -o -iname "*Typeless*.app" \)
find ~/Library/Developer/Xcode/DerivedData -type d -name "GhostType.app"
find ./build ./.build ./dist/dmg-staging -type d -name "GhostType.app" 2>/dev/null
pgrep -laf "GhostType|Typeless"
```

处理命令：
```bash
pkill -x GhostType || true
rm -rf /Applications/LocalTypeless.app
# 默认只清理发布/安装冲突副本，不删开发构建产物
rm -rf ./dist/dmg-staging/**/GhostType.app
open /Applications/GhostType.app
```

仅在确认“Spotlight 索引残留且不再需要旧 Debug 产物”时，才允许额外清理：
```bash
# 先执行 3.2 保证最新 Debug 产物可恢复，再清理旧索引来源
rm -rf ~/Library/Developer/Xcode/DerivedData/**/Build/Products/**/GhostType.app
rm -rf ./build/**/GhostType.app
rm -rf ./.build/**/GhostType.app
```

验收命令：
```bash
find /Applications -maxdepth 2 -name "GhostType.app"
pgrep -laf "GhostType"
```

通过标准：
- 系统中仅存在一个可启动副本：`/Applications/GhostType.app`
- 运行进程路径指向 `/Applications/GhostType.app/Contents/MacOS/GhostType`

### 3.2 代码更新后，App 看起来没有更新
现象：
- 已编译成功，但 UI/功能仍是旧版本

根因（常见）：
- 实际启动了构建目录内的旧副本
- `/Applications/GhostType.app` 未被最新构建覆盖
- Debug 构建下只比对主可执行文件，误判版本一致

检查命令：
```bash
TARGET_BUILD_DIR="$(xcodebuild -project GhostType.xcodeproj -scheme GhostType -showBuildSettings | awk -F' = ' '/TARGET_BUILD_DIR/{print $2; exit}')"
echo "$TARGET_BUILD_DIR"
shasum -a 256 /Applications/GhostType.app/Contents/MacOS/GhostType.debug.dylib "$TARGET_BUILD_DIR/GhostType.app/Contents/MacOS/GhostType.debug.dylib"
pgrep -laf "GhostType"
```

处理命令：
```bash
xcodebuild -project GhostType.xcodeproj -scheme GhostType -configuration Debug build
TARGET_BUILD_DIR="$(xcodebuild -project GhostType.xcodeproj -scheme GhostType -showBuildSettings | awk -F' = ' '/TARGET_BUILD_DIR/{print $2; exit}')"
pkill -x GhostType || true
ditto "$TARGET_BUILD_DIR/GhostType.app" /Applications/GhostType.app
open /Applications/GhostType.app
```

验收命令：
```bash
shasum -a 256 /Applications/GhostType.app/Contents/MacOS/GhostType.debug.dylib "$TARGET_BUILD_DIR/GhostType.app/Contents/MacOS/GhostType.debug.dylib"
pgrep -laf "GhostType"
```

### 3.3 退出 App 后 Python 进程残留
现象：
- 关闭 App 后，仍有 `service.py` 或 `pip` 相关进程常驻

检查命令：
```bash
pgrep -laf "service.py|pip install -r .*GhostType.app/Contents/Resources/requirements.txt|GhostType"
```

处理命令：
```bash
pkill -x GhostType || true
pkill -f "GhostType.app/Contents/Resources/service.py" || true
pkill -f "pip install -r .*GhostType.app/Contents/Resources/requirements.txt" || true
open /Applications/GhostType.app
```

验收命令：
```bash
pgrep -laf "service.py|pip install -r .*GhostType.app/Contents/Resources/requirements.txt|GhostType"
```

### 3.4 Spotlight 出现 `GhostType` 与 `GhostType (Debug)` 两个应用条目
现象：
- Spotlight 同时显示 `GhostType`（应用程序）和 `GhostType`（Debug）
- Dock/运行进程通常只有一个，但搜索结果有两个“应用”

根因（常见）：
- LaunchServices/Spotlight 收录了 `DerivedData`、`./.build`、`/private/tmp/...` 下的调试包路径
- 这通常是“索引重复”，不等于“真的有两个运行实例”

禁止操作（红线）：
- 未确认前，禁止直接删除 `DerivedData` 或 `./.build` 的 `GhostType.app`

标准处理：
```bash
# 1) 先确认运行实例是否只有 /Applications
pgrep -laf "GhostType|Typeless"
lsappinfo list | rg -i "GhostType|Typeless"

# 2) 若在开发态，先重建并覆盖安装，确保调试产物可恢复
xcodebuild -project GhostType.xcodeproj -scheme GhostType -configuration Debug build
TARGET_BUILD_DIR="$(xcodebuild -project GhostType.xcodeproj -scheme GhostType -showBuildSettings | awk -F' = ' '/TARGET_BUILD_DIR/{print $2; exit}')"
ditto "$TARGET_BUILD_DIR/GhostType.app" /Applications/GhostType.app

# 3) 仅反注册 Debug 路径，不先删文件
LSREG="/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister"
$LSREG -dump | rg -n "GhostType.app|com.codeandchill.ghosttype"
# 对非 /Applications 的 GhostType.app 路径逐条执行：
$LSREG -u "<非 /Applications 的 GhostType.app 路径>"
$LSREG -f /Applications/GhostType.app
```

验收命令：
```bash
mdfind "kMDItemFSName == 'GhostType.app'c"
lsappinfo list | rg -i "GhostType|Typeless"
```

通过标准：
- Spotlight 中 `GhostType.app` 仅指向 `/Applications/GhostType.app`
- 运行进程仅指向 `/Applications/GhostType.app/Contents/MacOS/GhostType`

### 3.5 本地 ASR 报错 `ffmpeg not found` 或音频解码失败
现象：
- 本地 ASR 返回 4xx，`error_code` 为：
  - `asr_decoder_unavailable`
  - `asr_ffmpeg_not_found`
  - `asr_wav_format_unsupported`

结论（当前默认行为）：
- 主链路录音会先归一化为 `16kHz 单声道 PCM16 WAV`，本地 ASR 优先走 WAV 直读，不依赖外部 `ffmpeg`。
- 仅当输入不是合规 WAV（或传入非 WAV 文件）时，才需要 `ffmpeg` 解码兜底。

检查命令：
```bash
curl -s http://127.0.0.1:8765/health | jq '.asr_capabilities'
file ~/Library/Application\\ Support/GhostType/AudioCaptures/latest_capture.wav
```

处理建议：
```bash
# 1) 优先确认录音输出是否合规 WAV（16k mono pcm_s16le）
afinfo ~/Library/Application\\ Support/GhostType/AudioCaptures/latest_capture.wav

# 2) 若业务确实要输入非 WAV，提供 ffmpeg（可内置或系统安装）
which ffmpeg
```

通过标准：
- 合规 WAV 在无系统 `ffmpeg` 环境下仍可完成本地 ASR。
- 非合规 WAV/非 WAV 输入时返回可读 4xx 错误，不出现 500。

## 4. 维护规则
- 新增内容时，只允许补充“项目介绍”或“排障 SOP”。
- 新需求、产品方案、阶段任务请写入其他文档（如 `README.md`、`docs/`），不要回填到本文件。
