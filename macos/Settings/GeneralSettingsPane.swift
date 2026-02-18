import AppKit
import SwiftUI

struct GeneralSettingsPane: View {
    @ObservedObject var engine: EngineConfig
    @ObservedObject var prefs: UserPreferences
    @ObservedObject var runtime: RuntimeState
    @State private var captureMode: WorkflowMode?
    @State private var keyDownMonitor: Any?
    @State private var flagsChangedMonitor: Any?
    @State private var pressedModifierKeyCodes: Set<UInt16> = []
    @State private var pendingModifierShortcut: HotkeyShortcut?
    @State private var captureErrorMessage: String = ""
    @State private var showingCaptureError = false
    @State private var pretranscribeAdvancedExpanded = false

    var body: some View {
        DetailContainer(
            icon: "keyboard.badge.ellipsis",
            title: prefs.ui("快捷键与常规", "Hotkeys & General"),
            subtitle: prefs.ui("录音触发、语言和运行状态", "Recording trigger, language, and runtime status")
        ) {
            Form {
                Section(prefs.ui("运行状态", "Runtime Status")) {
                    LabeledContent(prefs.ui("阶段", "Stage"), value: runtime.stage.title)
                    LabeledContent(
                        prefs.ui("提供者", "Provider"),
                        value: engine.shouldUseLocalProvider
                            ? prefs.ui("本地 MLX", "Local MLX")
                            : (engine.isMixedEngineSelection ? prefs.ui("混合 (本地+云端)", "Hybrid (Local + Cloud)") : prefs.ui("云端 API", "Cloud API"))
                    )
                    LabeledContent(prefs.ui("后端", "Backend"), value: runtime.backendStatus)
                    LabeledContent(prefs.ui("进程", "Process"), value: runtime.processStatus)
                    LabeledContent(prefs.ui("模式", "Mode"), value: runtime.activeModeText)
                    LabeledContent(prefs.ui("ASR 检测语言", "ASR Detected"), value: runtime.lastASRDetectedLanguage)
                    LabeledContent(prefs.ui("LLM 语言策略", "LLM Language Policy"), value: runtime.lastLLMOutputLanguagePolicy)
                    LabeledContent(prefs.ui("预转写", "Pretranscribe"), value: runtime.pretranscribeStatus)
                    LabeledContent(prefs.ui("已转写分块", "Pretranscribed Chunks"), value: "\(runtime.pretranscribeCompletedChunks)")
                    LabeledContent(prefs.ui("预转写队列", "Pretranscribe Queue"), value: "\(runtime.pretranscribeQueueDepth)")
                    LabeledContent(prefs.ui("最后分块延迟", "Last Chunk Latency"), value: runtime.pretranscribeLastLatencyMS > 0 ? String(format: "%.0f ms", runtime.pretranscribeLastLatencyMS) : "N/A")
                    LabeledContent(prefs.ui("插入路径", "Insert Path"), value: runtime.lastInsertPath)
                    LabeledContent(prefs.ui("剪贴板恢复", "Clipboard Restore"), value: runtime.lastClipboardRestoreStatus)
                    if !runtime.lastInsertDebug.isEmpty {
                        Text(runtime.lastInsertDebug)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }

                Section(prefs.ui("智能输入", "Smart Insert")) {
                    Toggle(
                        prefs.ui("优先直写目标输入框（失败后回退粘贴）", "Prefer direct insertion to target input (fallback to paste)"),
                        isOn: $prefs.smartInsertEnabled
                    )
                    Toggle(
                        prefs.ui("粘贴后恢复剪贴板", "Restore clipboard after paste"),
                        isOn: $prefs.restoreClipboardAfterPaste
                    )
                    Text(
                        prefs.ui(
                            "开启后会尝试通过辅助功能直接写入目标输入框；失败时自动复制并粘贴。恢复剪贴板会在检测到用户未改动时执行。",
                            "When enabled, GhostType tries direct AX insertion first and falls back to paste. Clipboard restore runs only if clipboard content has not changed."
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Section(prefs.ui("长录音预转写", "Long Recording Pretranscribe")) {
                    Toggle(
                        prefs.ui("长录音预转写", "Long Recording Pretranscribe"),
                        isOn: $prefs.pretranscribeEnabled
                    )
                    Text(
                        prefs.ui(
                            "录音超过 5 秒后，会在录音过程中分段发送音频到转写服务，提前生成文字。录音结束时通常更快得到最终结果。",
                            "After 5 seconds, audio is sent in chunks during recording so transcription work is done early. Final result is usually faster after stop."
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    DisclosureGroup(
                        isExpanded: $pretranscribeAdvancedExpanded,
                        content: {
                            HStack {
                                Text(prefs.ui("步进秒数", "Step seconds"))
                                Spacer()
                                TextField(
                                    "5.0",
                                    value: $prefs.pretranscribeStepSeconds,
                                    format: .number.precision(.fractionLength(1))
                                )
                                .frame(width: 90)
                            }
                            HStack {
                                Text(prefs.ui("重叠秒数", "Overlap seconds"))
                                Spacer()
                                TextField(
                                    "0.6",
                                    value: $prefs.pretranscribeOverlapSeconds,
                                    format: .number.precision(.fractionLength(1))
                                )
                                .frame(width: 90)
                            }
                            HStack {
                                Text(prefs.ui("最大分块秒数", "Max chunk seconds"))
                                Spacer()
                                TextField(
                                    "10.0",
                                    value: $prefs.pretranscribeMaxChunkSeconds,
                                    format: .number.precision(.fractionLength(1))
                                )
                                .frame(width: 90)
                            }
                            HStack {
                                Text(prefs.ui("最小语音秒数", "Min speech seconds"))
                                Spacer()
                                TextField(
                                    "1.2",
                                    value: $prefs.pretranscribeMinSpeechSeconds,
                                    format: .number.precision(.fractionLength(1))
                                )
                                .frame(width: 90)
                            }
                            HStack {
                                Text(prefs.ui("结束静音 (ms)", "End silence (ms)"))
                                Spacer()
                                TextField(
                                    "240",
                                    value: $prefs.pretranscribeEndSilenceMS,
                                    format: .number
                                )
                                .frame(width: 90)
                            }
                            HStack {
                                Text(prefs.ui("并行 ASR 请求数", "ASR requests in flight"))
                                Spacer()
                                TextField(
                                    "1",
                                    value: $prefs.pretranscribeMaxInFlight,
                                    format: .number
                                )
                                .frame(width: 90)
                            }
                            Picker(prefs.ui("回退策略", "Fallback"), selection: $prefs.pretranscribeFallbackPolicy) {
                                Text(prefs.ui("关闭", "Off")).tag(PretranscribeFallbackPolicyOption.off)
                                Text(prefs.ui("分块失败后完整 ASR", "Chunk failures -> full ASR")).tag(PretranscribeFallbackPolicyOption.fullASROnHighFailure)
                            }
                        },
                        label: {
                            Text(prefs.ui("高级设置", "Advanced"))
                        }
                    )
                }

                Section(prefs.ui("三大工作流快捷键", "Workflow Hotkeys")) {
                    hotkeyField("Dictation", mode: .dictate)
                    hotkeyField("Ask", mode: .ask)
                    hotkeyField("Translate", mode: .translate)
                }

                Section(prefs.ui("语言", "Language")) {
                    Picker(prefs.ui("界面语言", "UI Language"), selection: $prefs.uiLanguage) {
                        ForEach(UILanguageOption.allCases) { option in
                            Text(option.rawValue).tag(option)
                        }
                    }
                    Picker(prefs.ui("输出语言（听写/问答）", "Output Language (Dictation/Ask)"), selection: $prefs.outputLanguage) {
                        ForEach(OutputLanguageOption.allCases) { option in
                            Text(option.displayName(uiLanguage: prefs.uiLanguage)).tag(option)
                        }
                    }
                    Text(
                        prefs.ui(
                            "该设置作用于听写和问答模式。翻译模式仍由“Translate To”决定目标语言。",
                            "This applies to Dictation and Ask. Translate mode still follows the \"Translate To\" target language."
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Picker(prefs.ui("翻译目标", "Translate To"), selection: $prefs.targetLanguage) {
                        ForEach(TargetLanguageOption.allCases) { option in
                            Text(option.rawValue).tag(option)
                        }
                    }
                    Toggle(
                        prefs.ui("去除重复句段", "Remove Repeated Segments"),
                        isOn: $prefs.removeRepeatedTextEnabled
                    )
                }

                Section(prefs.ui("内存策略", "Memory Policy")) {
                    Picker(prefs.ui("空闲后释放模型", "Release Models After Idle"), selection: $prefs.memoryTimeout) {
                        ForEach(MemoryTimeoutOption.allCases) { option in
                            Text(option.rawValue).tag(option)
                        }
                    }
                }

                Section(prefs.ui("语音增强", "Speech Enhancement")) {
                    Toggle(
                        prefs.ui("启用语音增强", "Enable Speech Enhancement"),
                        isOn: $prefs.audioEnhancementEnabled
                    )

                    Group {
                        Picker(prefs.ui("增强模式", "Enhancement Mode"), selection: $prefs.audioEnhancementMode) {
                            ForEach(AudioEnhancementModeOption.allCases) { option in
                                Text(option.rawValue).tag(option)
                            }
                        }

                        Picker(prefs.ui("低音量增强强度", "Low-Volume Boost"), selection: $prefs.lowVolumeBoost) {
                            ForEach(LowVolumeBoostOption.allCases) { option in
                                Text(option.rawValue).tag(option)
                            }
                        }

                        Picker(prefs.ui("噪声抑制强度", "Noise Suppression"), selection: $prefs.noiseSuppressionLevel) {
                            ForEach(NoiseSuppressionLevelOption.allCases) { option in
                                Text(option.rawValue).tag(option)
                            }
                        }

                        Picker(prefs.ui("防截断停顿阈值", "Anti-Cutoff Pause"), selection: $prefs.endpointPauseThreshold) {
                            ForEach(EndpointPauseThresholdOption.allCases) { option in
                                Text(option.rawValue).tag(option)
                            }
                        }
                    }
                    .disabled(!prefs.audioEnhancementEnabled)

                    Toggle(
                        prefs.ui("HUD 显示输入电平与 VAD 状态", "Show input level and VAD status in HUD"),
                        isOn: $prefs.showAudioDebugHUD
                    )

                    Toggle(
                        prefs.ui("听写双通道：先快后精（实验）", "Dictation dual-pass: fast then quality (Experimental)"),
                        isOn: $prefs.dictationDualPassEnabled
                    )
                    .disabled(!prefs.audioEnhancementEnabled)

                    Toggle(
                        prefs.ui("质量路径完成后自动替换刚插入文本（高级）", "Auto-replace just-inserted text after quality pass (Advanced)"),
                        isOn: $prefs.dictationQualityAutoReplaceEnabled
                    )
                    .disabled(!prefs.dictationDualPassEnabled || !prefs.audioEnhancementEnabled)

                    if prefs.dictationDualPassEnabled {
                        Text(
                            prefs.ui(
                                "首轮使用快路径先插入文本；随后后台运行高质量路径。自动替换默认关闭，仅在前台应用未切换时尝试安全替换。",
                                "First pass inserts text with a fast path, then runs a high-quality pass in background. Auto-replace is off by default and only attempts safe replacement when the front app is unchanged."
                            )
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    if prefs.audioEnhancementMode == .systemVoiceProcessing {
                        Text(
                            prefs.ui(
                                "系统语音处理模式偏通话风格，可调参数较少；建议默认使用 WebRTC 模式。",
                                "System voice processing sounds more telephony-like and has fewer tuning knobs. WebRTC mode is recommended."
                            )
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }

                Section(prefs.ui("最近输出", "Latest Output")) {
                    Group {
                        if runtime.lastOutput.isEmpty {
                            Text(prefs.ui("暂无输出。", "No output yet."))
                        } else {
                            Text(runtime.lastOutput)
                        }
                    }
                        .font(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .shadow(radius: 2, y: 1)
                }
            }
            .formStyle(.grouped)
        }
        .onDisappear {
            stopCapture()
        }
        .alert(prefs.ui("快捷键设置失败", "Failed to Set Hotkey"), isPresented: $showingCaptureError) {
            Button(prefs.ui("确定", "OK"), role: .cancel) {}
        } message: {
            Text(captureErrorMessage)
        }
    }

    private func hotkeyField(_ label: String, mode: WorkflowMode) -> some View {
        let isCapturing = captureMode == mode
        let text = isCapturing ? "Press keys..." : prefs.shortcut(for: mode).displayText
        return HStack {
            Text(label)
            Spacer(minLength: 20)
            Button {
                toggleCapture(for: mode)
            } label: {
                Text(text)
                    .font(.body)
                    .frame(width: 280, alignment: .center)
                    .padding(.vertical, 7)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(isCapturing ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: isCapturing ? 2 : 1)
                    )
            }
            .buttonStyle(.plain)
            .help(prefs.ui("点击后直接按键录入快捷键，按 Esc 取消。", "Click and press keys to capture a shortcut; press Esc to cancel."))
        }
    }

    private func toggleCapture(for mode: WorkflowMode) {
        if captureMode == mode {
            stopCapture()
            return
        }
        captureMode = mode
        pressedModifierKeyCodes.removeAll()
        pendingModifierShortcut = nil
        installCaptureMonitorsIfNeeded()
    }

    private func installCaptureMonitorsIfNeeded() {
        if keyDownMonitor == nil {
            keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard captureMode != nil else { return event }
                handleKeyDownCapture(event)
                return nil
            }
        }
        if flagsChangedMonitor == nil {
            flagsChangedMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
                guard captureMode != nil else { return event }
                handleFlagsChangedCapture(event)
                return nil
            }
        }
    }

    private func stopCapture() {
        captureMode = nil
        pendingModifierShortcut = nil
        pressedModifierKeyCodes.removeAll()
        if let keyDownMonitor {
            NSEvent.removeMonitor(keyDownMonitor)
        }
        if let flagsChangedMonitor {
            NSEvent.removeMonitor(flagsChangedMonitor)
        }
        keyDownMonitor = nil
        flagsChangedMonitor = nil
    }

    private func handleKeyDownCapture(_ event: NSEvent) {
        guard let captureMode else { return }
        if event.keyCode == 53 {
            stopCapture()
            return
        }

        let shortcut = HotkeyShortcut(
            keyCode: event.keyCode,
            modifiers: event.modifierFlags.hotkeyRelevant,
            requiredModifierKeyCodes: Array(pressedModifierKeyCodes),
            keyLabel: HotkeyShortcut.displayName(
                for: event.keyCode,
                fallback: event.charactersIgnoringModifiers
            )
        )
        applyCapturedShortcut(shortcut, mode: captureMode)
    }

    private func handleFlagsChangedCapture(_ event: NSEvent) {
        guard HotkeyShortcut.isModifierKey(event.keyCode) else { return }

        let keyCode = event.keyCode
        let flags = event.modifierFlags.hotkeyRelevant
        if let modifier = HotkeyShortcut.modifierFlag(for: keyCode),
           flags.contains(modifier) {
            pressedModifierKeyCodes.insert(keyCode)
        } else {
            pressedModifierKeyCodes.remove(keyCode)
        }

        if !pressedModifierKeyCodes.isEmpty {
            pendingModifierShortcut = HotkeyShortcut(
                keyCode: keyCode,
                modifiers: flags,
                requiredModifierKeyCodes: Array(pressedModifierKeyCodes),
                keyLabel: HotkeyShortcut.displayName(for: keyCode)
            )
            return
        }

        if let pendingModifierShortcut, let mode = captureMode {
            applyCapturedShortcut(pendingModifierShortcut, mode: mode)
        }
    }

    private func applyCapturedShortcut(_ shortcut: HotkeyShortcut, mode: WorkflowMode) {
        stopCapture()
        if let error = prefs.applyHotkey(shortcut, for: mode) {
            captureErrorMessage = error.localizedDescription
            showingCaptureError = true
        }
    }
}
