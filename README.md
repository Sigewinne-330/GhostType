# 👻 GhostType

**The Open-Source, Context-Aware Voice Productivity Tool.**
*An alternative to Typeless — built for privacy, flexibility, and your wallet.*

> **开源、上下文感知的语音效率工具。**
> *Typeless 的开源替代 — 为隐私、灵活性和你的钱包而生。*

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS%20(Apple%20Silicon)-lightgrey.svg)]()
[![Local LLM](https://img.shields.io/badge/Local%20LLM-Beta-orange)]()
[![Status](https://img.shields.io/badge/status-Beta-yellow)]()

---

## 👋 Why GhostType?

I built GhostType for a simple reason: I loved the *concept* of **Typeless** — turning rambly voice notes into structured text is a genuine productivity superpower.

> 我做 GhostType 的原因很简单：我很喜欢 **Typeless** 的理念 — 把语无伦次的语音变成结构化文字，这确实是生产力的超能力。

**But as a student, I had two problems:**

> **但作为一个学生，我遇到了两个问题：**

1. **Cost.** The subscription model was steep for my budget. I kept thinking: *"I just want to dictate into a text field. Why does this cost $10/month?"*
2. **Privacy.** I talk about private ideas, unfinished code, half-baked plans. I wasn't comfortable sending all of that — raw audio included — to someone else's server.

> 1. **价格。** 订阅制对我的预算来说太贵了。我一直在想：*"我只是想对着输入框说话而已，为什么要花 10 美元/月？"*
> 2. **隐私。** 我会说一些私人想法、未完成的代码、不成熟的方案。把这些东西（包括原始音频）全部发送到别人的服务器，我不太放心。

Then I realized: modern Macs with Apple Silicon are *powerful*. Whisper runs locally. LLMs run locally. We don't need the cloud for this anymore.

> 然后我意识到：搭载 Apple Silicon 的 Mac 性能已经很强了。Whisper 可以在本地跑，LLM 也可以在本地跑。这件事不再需要云端了。

So I built **GhostType**. It listens, understands context, rewrites your words, and types the result directly into wherever your cursor is — all without your voice data leaving your machine.

> 所以我做了 **GhostType**。它听你说话、理解你的上下文、改写你的语句，然后把结果直接输入到光标所在的位置 — 全程你的语音数据不会离开你的电脑。

It's free. It's open source. And it's built to be *yours*.

> 它免费、开源，而且完全属于你。

---

## ✨ Features | 功能特性

### 🧠 Context-Aware Dictation | 上下文感知听写

GhostType doesn't just transcribe. It *understands where you are*.

> GhostType 不只是转录文字。它能 *理解你正在哪个应用中工作*。

- Writing code in **VS Code / Xcode**? It formats with code blocks and technical precision.
- Chatting in **Slack / Discord / WeChat**? It keeps the tone casual and brief.
- Drafting in **Notion**? It organizes your thoughts into bullet points and headings.
- Composing in **Gmail / Outlook**? It writes a professional email with proper greeting and closing.
- Talking to **ChatGPT / Claude / Gemini** in the browser? It rewrites your ramble into a clean, structured prompt.

> - 在 **VS Code / Xcode** 里写代码？自动用代码块格式输出。
> - 在 **Slack / Discord / 微信** 里聊天？保持轻松口语的风格。
> - 在 **Notion** 里写笔记？自动整理成项目符号和标题。
> - 在 **Gmail / Outlook** 里写邮件？自动生成带称呼和结尾的专业邮件。
> - 在浏览器里和 **ChatGPT / Claude / Gemini** 对话？把你的碎碎念改写成结构清晰的 Prompt。

This works via automatic app detection (bundle ID, browser URL, window title). You can also define your own routing rules — match any domain, app, or window title regex to any of the 21 built-in prompt presets.

> 这是通过自动检测当前应用（Bundle ID、浏览器 URL、窗口标题）实现的。你也可以自定义路由规则 — 将任意域名、应用或窗口标题正则匹配到 21 个内置提示词预设中的任何一个。

### ⚡️ Three Workflow Modes | 三种工作模式

| Mode | What It Does | Default Hotkey |
|------|-------------|----------------|
| **Dictation** | Speak naturally → polished, structured text inserted at cursor | `Right Option` (hold) |
| **Ask** | Ask a question about selected text → answer inserted | `Right Option + Space` |
| **Translate** | Speak in any language → translated text inserted | `Right Option + Right Cmd` |

> | 模式 | 功能 | 默认快捷键 |
> |------|------|-----------|
> | **听写** | 自然说话 → 精炼的结构化文字插入光标位置 | `右 Option`（按住） |
> | **问答** | 对选中文本提问 → 答案直接插入 | `右 Option + 空格` |
> | **翻译** | 说任何语言 → 翻译后的文字插入 | `右 Option + 右 Cmd` |

**Hold or tap** — hold the hotkey while speaking, or quick-tap to toggle recording on/off. You can even start in Dictation and *promote mid-recording* to Ask (press Space) or Translate (press Cmd) without stopping.

> **按住或轻按** — 按住快捷键说话，或轻按一下切换录音开/关。你甚至可以在听写过程中 *无缝切换* 到问答（按空格）或翻译（按 Cmd），无需停止录音。

All hotkeys are fully configurable in Settings with built-in conflict detection.

> 所有快捷键都可以在设置中自定义，内置冲突检测。

### 🔌 Flexible Engine Architecture | 灵活的引擎架构

GhostType is built on a hybrid architecture. You choose how much stays local.

> GhostType 采用混合架构，你可以自由选择本地和云端的比例。

| Component | Status | What I Recommend |
|:---|:---|:---|
| **ASR (Speech-to-Text)** | ✅ Stable | **Local Whisper** runs beautifully on Apple Silicon. This is the default and it's great. |
| **LLM (Intelligence)** | 🚀 Production-ready | **API Mode** is the daily driver. Fast, smart, and supports all major providers. |
| **Local LLM** | 🧪 Beta | You *can* run LLMs fully on-device via MLX. It works — but expect higher RAM usage and occasional rough edges. |

> | 组件 | 状态 | 我的推荐 |
> |:---|:---|:---|
> | **ASR（语音转文字）** | ✅ 稳定 | **本地 Whisper** 在 Apple Silicon 上表现出色，这是默认选项，非常好用。 |
> | **LLM（智能改写）** | 🚀 可日常使用 | **API 模式** 是目前的主力方案，快速、聪明，支持所有主流服务商。 |
> | **本地 LLM** | 🧪 测试中 | 你 *可以* 通过 MLX 完全在本地跑 LLM。能用，但内存占用较高，偶尔有粗糙的地方。 |

**Supported LLM Providers | 支持的 LLM 服务商：**
- DeepSeek, Google Gemini, OpenAI, Anthropic (Claude), Groq, Azure OpenAI
- **Custom Endpoints** — any OpenAI-compatible API (self-hosted, corporate proxy, etc.)
- **Local MLX** — 50+ models including Qwen2.5, Llama 3.x, Mistral, Gemma 2, Phi-3

> - DeepSeek、Google Gemini、OpenAI、Anthropic (Claude)、Groq、Azure OpenAI
> - **自定义端点** — 任何 OpenAI 兼容 API（自建服务、公司内网代理等）
> - **本地 MLX** — 50+ 模型，包括 Qwen2.5、Llama 3.x、Mistral、Gemma 2、Phi-3

**Supported ASR Providers | 支持的 ASR 服务商：**
- Local: MLX Whisper, whisper.cpp, FunASR, SenseVoice, WeNet, WhisperKit
- Cloud: OpenAI Whisper, Deepgram (Nova-2/3), AssemblyAI, Groq, Gemini Multimodal
- Chinese-specialized: Tencent Cloud, Alibaba NLS, iFlytek, Baidu Speech

> - 本地：MLX Whisper、whisper.cpp、FunASR、SenseVoice、WeNet、WhisperKit
> - 云端：OpenAI Whisper、Deepgram (Nova-2/3)、AssemblyAI、Groq、Gemini Multimodal
> - 中文特化：腾讯云、阿里云 NLS、科大讯飞、百度语音

All API keys are stored in the **macOS Keychain**. No config files with secrets lying around.

> 所有 API 密钥都存储在 **macOS 钥匙串** 中。不会有明文配置文件到处躺着。

### 🎨 21 Built-in Prompt Presets | 21 个内置提示词预设

Not just "transcribe my words." Each preset shapes how GhostType rewrites your speech:

> 不只是"转录我的话"。每个预设都会影响 GhostType 如何改写你的语音：

| Preset | Best For |
|--------|----------|
| Precise Multilingual (Default) | Faithful rewrite with smart formatting |
| IM Natural Chat | Casual chat messages (WeChat, Slack) |
| Email Professional | Emails with proper greeting/closing |
| Prompt Builder | Turning rambles into clean AI prompts |
| Ticket Update | Jira/Linear issue updates |
| Dev Commit Message | Git commit messages in imperative mood |
| Code Review Comment | Constructive review feedback |
| Meeting Minutes | Key points + action items |
| Study Notes | Review-ready study notes |
| ... and 12 more | PRDs, outlines, social posts, customer support, etc. |

> | 预设 | 最适合 |
> |------|--------|
> | 精准多语言（默认） | 忠实改写 + 智能格式化 |
> | IM 自然聊天 | 休闲聊天消息（微信、Slack） |
> | 专业邮件 | 带称呼和结尾的邮件 |
> | Prompt 构建器 | 把碎碎念变成清晰的 AI Prompt |
> | 工单更新 | Jira/Linear 工单内容 |
> | Git Commit 消息 | 祈使句风格的提交说明 |
> | Code Review 评论 | 建设性的审查反馈 |
> | 会议纪要 | 要点 + 行动项 |
> | 学习笔记 | 适合复习的笔记 |
> | ……还有 12 个 | PRD、大纲、社交媒体、客户支持等 |

Every preset is fully editable. Create your own. The context routing system can auto-switch presets based on which app or website you're in.

> 每个预设都完全可编辑。可以创建你自己的。上下文路由系统会根据你当前的应用或网站自动切换预设。

### 🔒 Privacy First | 隐私优先

- **Local ASR by default.** Your raw audio stays on your machine.
- **No telemetry.** Zero analytics, zero tracking, zero data collection.
- **API keys in Keychain.** Not in plaintext config files.
- **Cloud is opt-in.** You choose if and when to use cloud providers.

> - **默认本地 ASR。** 你的原始音频留在本机。
> - **零遥测。** 没有分析、没有追踪、没有数据收集。
> - **密钥存钥匙串。** 不会用明文配置文件。
> - **云端是可选的。** 你自己决定是否使用云服务。

---

## 🤖 Model Insights (My Personal Picks) | 模型推荐（我的个人选择）

I use GhostType every day. Here's my current setup and honest opinions:

> 我每天都在用 GhostType。以下是我目前的配置和真实感受：

**LLM:**
- **DeepSeek-Chat** — my daily driver. The instruction-following and logic are *incredible* for the price. Highly recommended.
- **Gemini 2.0 Flash** — excellent alternative. Very fast, good quality. Close second.
- **Local MLX (Qwen2.5)** — works for basic dictation cleanup. Don't expect cloud-level intelligence, but it's *free* and *private*.

> **LLM：**
> - **DeepSeek-Chat** — 我的日常主力。指令遵循和逻辑能力在这个价位上令人难以置信。强烈推荐。
> - **Gemini 2.0 Flash** — 优秀的替代方案。速度极快，质量很好。紧随其后。
> - **本地 MLX (Qwen2.5)** — 基本的听写整理可以用。别指望云端级别的智能，但它 *免费* 且 *私密*。

**ASR:**
- **Whisper Large v3** (local, MLX) — a beast. Especially for mixed Chinese/English. This is what I use daily.
- **Deepgram Nova-2** — if you want cloud speed and can accept sending audio.

> **ASR：**
> - **Whisper Large v3**（本地，MLX）— 非常强大。尤其是中英混合场景。这是我每天用的。
> - **Deepgram Nova-2** — 如果你想要云端速度并且可以接受发送音频的话。

**Custom endpoints:** GhostType supports any OpenAI-compatible API. If your company runs an internal LLM gateway, or you're self-hosting with vLLM/Ollama — just plug in the base URL.

> **自定义端点：** GhostType 支持任何 OpenAI 兼容 API。如果你的公司有内部 LLM 网关，或者你用 vLLM/Ollama 自建服务 — 填入 Base URL 即可。

---

## 📥 Installation | 安装

### Requirements | 系统要求

- macOS 14.0+ (Sonoma or later)
- Apple Silicon (M1 / M2 / M3 / M4)
- Python 3.10+ (for local MLX inference)
- Xcode Command Line Tools

> - macOS 14.0+（Sonoma 或更高版本）
> - Apple Silicon（M1 / M2 / M3 / M4）
> - Python 3.10+（用于本地 MLX 推理）
> - Xcode 命令行工具

### Download | 下载

Grab the latest `.app.zip` from the [Releases](https://github.com/never13254/GhostType/releases) page. Unzip and drag `GhostType.app` to `/Applications`.

> 从 [Releases](https://github.com/never13254/GhostType/releases) 页面下载最新的 `.app.zip`，解压后将 `GhostType.app` 拖入 `/Applications`。

### Build from Source | 从源码构建

```bash
# Install XcodeGen
brew install xcodegen

# Clone and build
git clone https://github.com/never13254/GhostType.git
cd GhostType
xcodegen generate
xcodebuild -project GhostType.xcodeproj -scheme GhostType \
  -configuration Debug -derivedDataPath ./.build \
  CODE_SIGNING_ALLOWED=NO build

# Run
open .build/Build/Products/Debug/GhostType.app
```

### First Launch | 首次启动

On first launch, GhostType will:

1. Request **Microphone** permission (for voice input).
2. Request **Accessibility** permission (for global hotkeys and text insertion).
3. Automatically create a Python virtual environment and install ML dependencies.
4. Download the default Whisper model (~500 MB) from Hugging Face on first use.

> 首次启动时，GhostType 会：
>
> 1. 请求 **麦克风** 权限（用于语音输入）。
> 2. 请求 **辅助功能** 权限（用于全局快捷键和文本插入）。
> 3. 自动创建 Python 虚拟环境并安装 ML 依赖。
> 4. 首次使用时从 Hugging Face 下载默认 Whisper 模型（约 500 MB）。

---

## ⚙️ Architecture | 架构

| Layer | Technology |
|-------|-----------|
| Frontend | SwiftUI + AppKit (native macOS, menu bar app) |
| Inference Runtime | Python subprocess + local WebSocket IPC |
| ASR | MLX Whisper (local) or cloud providers |
| LLM | API providers or local MLX models |
| Audio | AVFoundation + WebRTC APM noise suppression |
| Context Detection | NSWorkspace + AppleScript + browser extension |
| Security | macOS Keychain for all credentials |

GhostType runs as a **menu bar app** — no Dock icon, always ready. A HUD overlay shows recording status, and results appear briefly before being inserted at your cursor via the Accessibility API.

> GhostType 以 **菜单栏应用** 的形式运行 — 没有 Dock 图标，随时待命。HUD 浮层显示录音状态，结果短暂显示后通过辅助功能 API 插入到光标位置。

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the full system design.

> 完整的系统设计文档见 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)。

---

## 🗺️ Roadmap | 路线图

I'm a student developer maintaining this in my free time, but I have big plans:

> 我是一个学生开发者，利用课余时间维护这个项目，但我有很大的计划：

- [ ] **Windows Version** — High priority. Coming soon.
- [ ] **iOS Version** — Planned.
- [ ] **Stable Local LLM** — Continuing to optimize on-device inference for daily-driver quality.
- [ ] **More prompt presets** — Always adding new ones based on community feedback.

> - [ ] **Windows 版** — 高优先级，即将到来。
> - [ ] **iOS 版** — 已计划。
> - [ ] **稳定的本地 LLM** — 持续优化设备端推理，达到日常可用的质量。
> - [ ] **更多提示词预设** — 根据社区反馈持续添加。

---

## 🤝 Help Wanted: Prompts & Code! | 需要你的帮助：提示词和代码！

**I need your help.** Seriously.

> **我真的需要你的帮助。** 认真的。

I'm a developer, not a prompt engineer. The current system prompts work well enough for my daily use, but I *know* they can be better. If you find a way to make the AI output smarter, less verbose, better formatted, or just more natural — **please submit a PR!**

> 我是开发者，不是 Prompt 工程师。当前的系统提示词在我日常使用中够用了，但我 *知道* 它们还可以更好。如果你能让 AI 输出更聪明、更简洁、格式更好或者更自然 — **请提交 PR！**

Areas where community help would be amazing:

> 社区帮助在以下方面会特别有价值：

- **Prompt optimization** — The 21 built-in presets are my best effort, but they're V1. Tweak them, test them, improve them.
- **New prompt presets** — Got a use case I haven't covered? Add it.
- **Bug fixes & features** — All contributions welcome.
- **Testing on different setups** — I develop on one machine. The more eyes, the better.

> - **提示词优化** — 21 个内置预设是我尽力而为的结果，但它们只是 V1。欢迎调整、测试、改进。
> - **新的提示词预设** — 有我没覆盖到的场景？添加它。
> - **Bug 修复和新功能** — 所有贡献都欢迎。
> - **不同环境测试** — 我只在一台机器上开发。越多人看到越好。

---

## ❤️ Support the Development | 支持开发

I'm a student developer building this in my spare time. If GhostType saves you the cost of a monthly subscription, or just makes your workflow a little smoother, please consider supporting the project.

> 我是一个学生开发者，利用课余时间做这个项目。如果 GhostType 帮你省下了每月的订阅费用，或者让你的工作流程更顺畅，请考虑支持一下这个项目。

Funding will directly help me buy test devices for the **Windows and iOS versions**.

> 资助将直接用于购买测试设备以开发 **Windows 和 iOS 版本**。

- 🚀 [Aifadian (爱发电)](https://afdian.com/a/bennywen) — Supports CNY payments
- 💰 WeChat Pay (微信支付) — Scan the QR code below

> - 🚀 [爱发电](https://afdian.com/a/bennywen) — 支持人民币支付
> - 💰 微信支付 — 扫描下方二维码

<p align="center">
  <img src="assets/wechat-pay.jpg" alt="WeChat Pay QR Code" width="280">
</p>

**Or just give this repo a Star ⭐ — it genuinely keeps me motivated.**

> **或者给这个仓库点个 Star ⭐ — 这真的能让我保持动力。**

---

## 📖 Documentation | 文档

- [Architecture | 架构文档](docs/ARCHITECTURE.md) — System design, data flow, module reference.
- [Troubleshooting | 排障手册](docs/TROUBLESHOOTING.md) — Common issues and fixes.
- [Contributing | 贡献指南](CONTRIBUTING.md) — How to contribute code and prompts.
- [Security | 安全政策](SECURITY.md) — Vulnerability reporting.

---

## 📜 License | 许可证

[MIT License](LICENSE) — do whatever you want with it.

> [MIT 许可证](LICENSE) — 随便用。

## Disclaimer | 免责声明

GhostType is an independent open-source project. It is not affiliated with, endorsed by, or connected to any commercial product. All trademarks belong to their respective owners.

> GhostType 是一个独立的开源项目。它与任何商业产品没有关联、背书或联系。所有商标归其各自所有者所有。

---

<p align="center">
  <b>Built with ❤️ and way too much coffee by a student who just wanted to dictate without going broke.</b>
  <br>
  <b>由一个只想不花冤枉钱就能语音输入的学生，用 ❤️ 和大量咖啡构建。</b>
</p>
