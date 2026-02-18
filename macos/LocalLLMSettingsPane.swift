import SwiftUI

// MARK: - Filter & Sort

enum LocalLLMSortOrder: String, CaseIterable, Identifiable {
    case name = "Name"
    case size = "Size"
    case paramScale = "Parameters"
    case recent = "Recently Used"
    var id: String { rawValue }
}

// MARK: - Inline Form-compatible Local LLM Configuration View
// Designed to match the ASR section's flat-list-in-Form style.

@MainActor
struct LocalLLMInlineConfigView: View {
    @ObservedObject var catalog: LocalLLMCatalogStore
    @ObservedObject var engine: EngineConfig
    @ObservedObject var prefs: UserPreferences
    
    // Shared ViewModel from parent for download state
    @ObservedObject var viewModel: EnginesSettingsPaneViewModel

    @State private var searchText = ""
    @State private var showAdvancedQuantization: Bool = false
    @State private var showAdvancedInference = false
    @State private var showQuantizationAlert = false
    @State private var alertTargetQuantization = ""

    var body: some View {
        // MARK: - Active Configuration Section
        Text("Active Configuration")
            .font(.headline.weight(.semibold))
        
        if installedLLMModels.isEmpty {
            Text("No installed models. Use Model Manager below to download.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Picker("Select Model (installed only)", selection: $engine.llmModel) {
                ForEach(installedLLMModels, id: \.repoId) { entry in
                    Text(entry.displayName).tag(entry.repoId)
                }
            }
            .pickerStyle(.menu)
        }
        
        // Quantization Menu
        let currentQuant = localLLMQuantizationTag(for: engine.llmModel)
        Menu {
            ForEach(quantizationChoices, id: \.value) { choice in
                Button {
                    applyQuantization(choice.value)
                } label: {
                    if choice.value == currentQuant {
                        Label(choice.displayName, systemImage: "checkmark")
                    } else {
                        Text(choice.displayName)
                    }
                }
            }
        } label: {
            HStack {
                Text("Choose quantization:")
                Text(quantizationDisplayName(currentQuant))
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
            }
        }
        .menuStyle(.borderlessButton)
        .alert(
            prefs.ui("未找到对应量化版本", "Quantization variant not found"),
            isPresented: $showQuantizationAlert
        ) {
            Button(prefs.ui("选最近可用版本", "Use Closest Available")) {
                applyClosestQuantization(target: alertTargetQuantization)
            }
            Button(prefs.ui("取消", "Cancel"), role: .cancel) {}
        } message: {
            Text(prefs.ui(
                "当前模型没有 \(alertTargetQuantization) 的变体，将切换到最接近的可用量化。",
                "No \(alertTargetQuantization) variant found. The closest available will be selected."
            ))
        }
        
        // Inference Parameters Disclosure
        DisclosureGroup(
            prefs.ui("推理参数", "Inference Parameters"),
            isExpanded: $showAdvancedInference
        ) {
            inferenceParametersContent
        }
        
        // Status Box
        statusBox
        
        // MARK: - Model Manager Section
        Text("Model Manager")
            .font(.headline.weight(.semibold))
        
        TextField("Search Local LLM Models", text: $searchText)
            .textFieldStyle(.roundedBorder)
        
        HStack {
            Button("Refresh List") {
                searchText = ""
            }
            .buttonStyle(.bordered)
            
            Spacer()
            
            Toggle("Show advanced models (2bit / fp16 / fp32)", isOn: $engine.localLLMShowAdvancedQuantization)
                .toggleStyle(.checkbox)
        }
        
        // Download New Model - separate from active model selection
        Picker("Download New Model", selection: $viewModel.pendingDownloadLLMModelID) {
            ForEach(downloadableLLMModels, id: \.repoId) { entry in
                HStack {
                    Text(entry.displayName)
                    if hasLLMCache(for: entry.repoId) {
                        Text("(installed)")
                    }
                }.tag(entry.repoId)
            }
        }
        .pickerStyle(.menu)
        .onAppear {
            if viewModel.pendingDownloadLLMModelID.isEmpty {
                viewModel.pendingDownloadLLMModelID = downloadableLLMModels.first?.repoId ?? ""
            }
        }
        
        HStack(spacing: 8) {
            Button(
                viewModel.llmDownloadProgress.isDownloading
                    ? "Downloading..."
                    : "Download Model"
            ) {
                Task {
                    await downloadPendingLocalLLMModel()
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.llmDownloadProgress.isDownloading || viewModel.probes.isClearingLocalLLMModelCache || viewModel.pendingDownloadLLMModelID.isEmpty)
        }
        
        // Download Progress UI - always show during download
        if viewModel.llmDownloadProgress.isDownloading || viewModel.llmDownloadProgress.status == "verifying" || viewModel.llmDownloadProgress.isComplete || viewModel.llmDownloadProgress.isFailed {
            llmDownloadProgressView
        }
        
        // Local Cache List
        Text("Local Cache:")
            .font(.headline.weight(.semibold))
        
        ForEach(installedLLMModels, id: \.repoId) { entry in
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.displayName)
                    if let size = entry.sizeBytesEstimate {
                        Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Delete") {
                    Task {
                        engine.llmModel = entry.repoId
                        await clearSelectedLocalLLMModelCache()
                    }
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.llmDownloadProgress.isDownloading || viewModel.probes.isClearingLocalLLMModelCache)
            }
        }
        
        // Cache Actions
        HStack(spacing: 8) {
            Button("Reveal Cache in Finder") {
                revealLLMCacheInFinder()
            }
            .buttonStyle(.bordered)
            .disabled(viewModel.llmDownloadProgress.isDownloading || viewModel.probes.isClearingLocalLLMModelCache)
            
            Button("Clear Model Cache") {
                Task {
                    await clearSelectedLocalLLMModelCache()
                }
            }
            .buttonStyle(.bordered)
            .disabled(viewModel.llmDownloadProgress.isDownloading || viewModel.probes.isClearingLocalLLMModelCache)
        }
        
        Button(
            catalog.isRefreshing
                ? "Refreshing..."
                : "Refresh Catalog (Hugging Face)"
        ) {
            Task {
                await catalog.refreshFromHuggingFace()
            }
        }
        .buttonStyle(.bordered)
        .disabled(catalog.isRefreshing)
        
        if !catalog.catalogStatus.isEmpty {
            Text(catalog.catalogStatus)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
    
    // MARK: - Status Box
    
    @ViewBuilder
    private var statusBox: some View {
        let entry = catalog.entries.first(where: { $0.repoId == engine.llmModel })
        
        GroupBox {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Circle()
                        .fill(llmStatusColor(for: entry))
                        .frame(width: 8, height: 8)
                    Text("Status: \(llmStatus(for: entry))")
                        .font(.caption)
                }
                Text("Repo: \(engine.llmModel)")
                    .font(.caption)
                    .textSelection(.enabled)
                
                if let entry = entry {
                    if let paramScale = entry.paramScale {
                        Text("Parameters: \(paramScale)")
                            .font(.caption)
                    }
                    
                    let sizeStr = entry.sizeBytesEstimate != nil 
                        ? ByteCountFormatter.string(fromByteCount: entry.sizeBytesEstimate!, countStyle: .file)
                        : "Size unknown - refresh catalog"
                    Text("Est. disk usage: \(sizeStr)")
                        .font(.caption)
                    
                    if let license = entry.license {
                        Text("License: \(license)")
                            .font(.caption)
                    }
                    
                    if let hasCT = entry.hasChatTemplate {
                        Text(hasCT ? "Chat Template: Available" : "Chat Template: Not detected")
                            .font(.caption)
                    }
                } else {
                    // Fallback for models not in catalog
                    Text("Parameters: Unknown")
                        .font(.caption)
                    Text("Est. disk usage: Size unknown - refresh catalog")
                        .font(.caption)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
    }
    
    // MARK: - Inference Parameters
    
    @ViewBuilder
    private var inferenceParametersContent: some View {
        // Temperature
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Temperature")
                Spacer()
                Text(String(format: "%.2f", engine.llmTemperature))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: $engine.llmTemperature, in: 0...2, step: 0.05)
            Text(prefs.ui(
                "低值（如 0.2）输出更确定，高值（如 1.0）更有创意。",
                "Lower values (e.g. 0.2) produce more deterministic output; higher (e.g. 1.0) more creative."
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        // Top-P
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Top-P")
                Spacer()
                Text(String(format: "%.2f", engine.llmTopP))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: $engine.llmTopP, in: 0...1, step: 0.05)
            Text(prefs.ui(
                "控制 nucleus sampling，通常保持 0.9–1.0。",
                "Controls nucleus sampling. Typically kept at 0.9–1.0."
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        // Max Tokens
        HStack(spacing: 8) {
            Text(prefs.ui("最大 Token 数", "Max Tokens"))
            Spacer()
            TextField("", value: $engine.llmMaxTokens, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 100)
                .multilineTextAlignment(.trailing)
            Stepper("", value: $engine.llmMaxTokens, in: 1...32768, step: 256)
                .labelsHidden()
        }

        // Repetition penalty
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(prefs.ui("重复惩罚", "Repetition Penalty"))
                Spacer()
                Text(String(format: "%.2f", engine.llmRepetitionPenalty))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: $engine.llmRepetitionPenalty, in: 1.0...2.0, step: 0.05)
            Text(prefs.ui(
                "惩罚重复词汇，1.0 表示无惩罚。",
                "Penalizes repeated tokens; 1.0 = no penalty."
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        // Seed
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Seed")
                Text(prefs.ui("设为 -1 则随机", "Set to -1 for random"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            TextField("", value: $engine.llmSeed, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 100)
                .multilineTextAlignment(.trailing)
        }

        // Stop sequences
        VStack(alignment: .leading, spacing: 4) {
            Text(prefs.ui("Stop Sequences", "Stop Sequences"))
            TextField(
                prefs.ui("用逗号分隔", "Comma-separated"),
                text: $engine.llmStopSequences,
                axis: .vertical
            )
            .textFieldStyle(.roundedBorder)
            .lineLimit(2...3)
        }

        // Memory saving
        Toggle(
            prefs.ui("内存节省模式（减少 KV Cache 占用）", "Memory Saving Mode (reduce KV cache usage)"),
            isOn: $engine.llmMemorySavingMode
        )
    }
    
    // MARK: - Download Progress View
    
    @ViewBuilder
    private var llmDownloadProgressView: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Status text with icon
            HStack {
                if viewModel.llmDownloadProgress.status == "verifying" {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("Verifying files...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if viewModel.llmDownloadProgress.isDownloading {
                    if viewModel.llmDownloadProgress.downloadedBytes > 0 {
                        Image(systemName: "arrow.down.circle.fill")
                            .foregroundStyle(.blue)
                    } else {
                        ProgressView()
                            .scaleEffect(0.7)
                    }
                    Text(viewModel.llmDownloadProgress.currentFile.isEmpty ? "Downloading..." : viewModel.llmDownloadProgress.currentFile)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else if viewModel.llmDownloadProgress.isComplete {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Download complete!")
                        .font(.caption)
                        .foregroundStyle(.green)
                } else if viewModel.llmDownloadProgress.isFailed {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.red)
                    Text(viewModel.llmDownloadProgress.errorMessage.isEmpty ? "Download failed" : viewModel.llmDownloadProgress.errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            
            // Progress bar
            if viewModel.llmDownloadProgress.isDownloading || viewModel.llmDownloadProgress.status == "verifying" {
                VStack(alignment: .leading, spacing: 4) {
                    if viewModel.llmDownloadProgress.status == "verifying" {
                        ProgressView()
                            .progressViewStyle(.linear)
                        Text("Verifying integrity...")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else if viewModel.llmDownloadProgress.downloadedBytes == 0 {
                        ProgressView()
                            .progressViewStyle(.linear)
                        Text("Connecting to Hugging Face...")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else {
                        FakeDownloadProgressView(downloadedBytes: viewModel.llmDownloadProgress.downloadedBytes)
                        
                        HStack(spacing: 16) {
                            Text(viewModel.llmDownloadProgress.formattedDownloadedSize)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            
                            if viewModel.llmDownloadProgress.speedMbps > 0 {
                                Text(viewModel.llmDownloadProgress.formattedSpeed)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            
                            Spacer()
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.15))
        )
    }
    
    // MARK: - Helpers
    
    private var filteredModels: [LocalLLMModelEntry] {
        let allowedQuantizations: Set<String> = engine.localLLMShowAdvancedQuantization
            ? ["default", "8bit", "4bit", "2bit", "fp16", "fp32", "q8", "q4", "int8", "int4"]
            : ["default", "8bit", "4bit", "q8", "q4", "int8", "int4"]

        var models = catalog.entries.filter {
            allowedQuantizations.contains($0.quantization.lowercased())
        }

        if !searchText.isEmpty {
            let q = searchText.lowercased()
            models = models.filter { 
                $0.repoId.lowercased().contains(q) || $0.displayName.lowercased().contains(q) 
            }
        }

        // Make sure the currently selected model is always present
        let current = engine.llmModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !current.isEmpty, !models.contains(where: { $0.repoId.caseInsensitiveCompare(current) == .orderedSame }) {
            models.insert(LocalLLMModelEntry.from(repoId: current), at: 0)
        }

        return models
    }
    
    private var downloadableLLMModels: [LocalLLMModelEntry] {
        let allowedQuantizations: Set<String> = engine.localLLMShowAdvancedQuantization
            ? ["default", "8bit", "4bit", "2bit", "fp16", "fp32", "q8", "q4", "int8", "int4"]
            : ["default", "8bit", "4bit", "q8", "q4", "int8", "int4"]
        
        return catalog.entries.filter {
            allowedQuantizations.contains($0.quantization.lowercased())
        }
    }
    
    private var installedLLMModels: [LocalLLMModelEntry] {
        catalog.entries.filter { entry in
            hasLLMCache(for: entry.repoId)
        }
    }
    
    private func hasLLMCache(for repoId: String) -> Bool {
        let cacheDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub/models--\(repoId.replacingOccurrences(of: "/", with: "--"))")
        return FileManager.default.fileExists(atPath: cacheDir.path)
    }
    
    private func llmStatusColor(for entry: LocalLLMModelEntry?) -> Color {
        guard let entry = entry else { return .gray }
        if hasLLMCache(for: entry.repoId) {
            return .green
        }
        return .gray
    }
    
    private func llmStatus(for entry: LocalLLMModelEntry?) -> String {
        guard let entry = entry else { return "Unknown" }
        if catalog.downloadingRepos.contains(entry.repoId) {
            return "Downloading"
        }
        if hasLLMCache(for: entry.repoId) {
            return "Ready"
        }
        return "Not downloaded (MLX will fetch on first use)"
    }

    private func shortModelName(_ repoId: String) -> String {
        let parts = repoId.split(separator: "/", maxSplits: 1)
        return parts.count == 2 ? String(parts[1]) : repoId
    }

    private func localLLMQuantizationTag(for model: String) -> String {
        let lower = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let suffixes: [(String, String)] = [
            ("-8bit", "8bit"), ("-4bit", "4bit"), ("-2bit", "2bit"),
            ("-fp16", "fp16"), ("-fp32", "fp32"),
            ("-q8", "q8"), ("-q4", "q4"), ("-int8", "int8"), ("-int4", "int4"),
        ]
        for (suffix, tag) in suffixes {
            if lower.hasSuffix(suffix) { return tag }
        }
        return "default"
    }

    private func quantizationDisplayName(_ tag: String) -> String {
        switch tag {
        case "8bit", "int8", "q8": return "8-bit"
        case "4bit", "int4", "q4": return "4-bit"
        case "2bit": return "2-bit"
        case "fp16": return "FP16"
        case "fp32": return "FP32"
        default: return "Default"
        }
    }

    private struct QuantChoice {
        let value: String
        let displayName: String
    }

    private var quantizationChoices: [QuantChoice] {
        let current = engine.llmModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !current.isEmpty else { return [] }

        let familyBase = familyKey(for: current)
        let sameFamily = filteredModels.filter {
            familyKey(for: $0.repoId).caseInsensitiveCompare(familyBase) == .orderedSame
        }

        var seen = Set<String>()
        var choices: [QuantChoice] = []
        for entry in sameFamily {
            let tag = localLLMQuantizationTag(for: entry.repoId)
            guard seen.insert(tag).inserted else { continue }
            choices.append(QuantChoice(value: tag, displayName: quantizationDisplayName(tag)))
        }
        if choices.isEmpty {
            let tag = localLLMQuantizationTag(for: current)
            choices = [QuantChoice(value: tag, displayName: quantizationDisplayName(tag))]
        }
        return choices
    }

    private func familyKey(for model: String) -> String {
        var name = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Strip publisher prefix
        if let slashIdx = name.firstIndex(of: "/") {
            name = String(name[name.index(after: slashIdx)...])
        }
        // Strip quantization suffix
        let suffixes = ["-8bit", "-4bit", "-2bit", "-fp16", "-fp32", "-q8", "-q4", "-int8", "-int4"]
        for suffix in suffixes {
            if name.hasSuffix(suffix) {
                name = String(name.dropLast(suffix.count))
                break
            }
        }
        return name
    }

    private func applyQuantization(_ quantization: String) {
        let current = engine.llmModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !current.isEmpty else { return }

        let familyBase = familyKey(for: current)
        if let match = filteredModels.first(where: {
            familyKey(for: $0.repoId).caseInsensitiveCompare(familyBase) == .orderedSame &&
            localLLMQuantizationTag(for: $0.repoId).lowercased() == quantization.lowercased()
        }) {
            engine.llmModel = match.repoId
        } else {
            alertTargetQuantization = quantizationDisplayName(quantization)
            showQuantizationAlert = true
        }
    }

    private func applyClosestQuantization(target: String) {
        let current = engine.llmModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let familyBase = familyKey(for: current)
        let sameFamily = filteredModels.filter {
            familyKey(for: $0.repoId).caseInsensitiveCompare(familyBase) == .orderedSame
        }
        let preference = ["4bit", "8bit", "default", "fp16", "fp32", "2bit"]
        for pref in preference {
            if let match = sameFamily.first(where: {
                localLLMQuantizationTag(for: $0.repoId).lowercased() == pref
            }) {
                engine.llmModel = match.repoId
                return
            }
        }
        if let first = sameFamily.first {
            engine.llmModel = first.repoId
        }
    }
    
    // MARK: - Download and Cache Actions
    
    private func downloadPendingLocalLLMModel() async {
        guard !viewModel.llmDownloadProgress.isDownloading else { return }
        let repoID = viewModel.pendingDownloadLLMModelID
        guard !repoID.isEmpty else { return }
        
        viewModel.probes.isDownloadingLocalLLMModel = true
        viewModel.probes.localLLMModelActionStatusIsError = false
        
        // Reset progress with downloading status
        viewModel.llmDownloadProgress = ModelDownloadProgress(
            repoID: repoID,
            status: "downloading",
            currentFile: "Starting download..."
        )
        
        defer {
            viewModel.probes.isDownloadingLocalLLMModel = false
        }

        do {
            // Start SSE download
            let encodedRepoID = repoID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? repoID
            guard let url = URL(string: "http://127.0.0.1:8765/models/download?repo_id=\(encodedRepoID)") else {
                throw URLError(.badURL)
            }
            
            var request = URLRequest(url: url, timeoutInterval: 3600)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                throw URLError(.badServerResponse)
            }
            
            // Parse SSE events
            for try await line in bytes.lines {
                print("[llm-download] Received line: \(line)", terminator: "")
                if line.hasPrefix("data: ") {
                    let jsonString = String(line.dropFirst(6))
                    if let data = jsonString.data(using: .utf8),
                       let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        print("[llm-download] Parsed event: \(event)")
                        await MainActor.run {
                            handleLLMDownloadEvent(event, repoID: repoID)
                        }
                    }
                }
            }
            
            print("[llm-download] SSE stream ended")
            
            // Only check cache if not already in error state
            guard !viewModel.llmDownloadProgress.isFailed else {
                // Error was already handled by SSE event
                return
            }
            
            // Check if download was successful
            let downloaded = hasLLMCache(for: repoID)
            if downloaded || viewModel.llmDownloadProgress.isComplete {
                viewModel.llmDownloadProgress.status = "complete"
                viewModel.llmDownloadProgress.progress = 100.0
                viewModel.probes.localLLMModelActionStatus = "Model downloaded: \(repoID)"
                
                // Show success for 3 seconds, then reset
                Task {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    if viewModel.llmDownloadProgress.status == "complete" {
                        viewModel.llmDownloadProgress = ModelDownloadProgress()
                    }
                }
            } else {
                viewModel.llmDownloadProgress.status = "error"
                viewModel.llmDownloadProgress.errorMessage = "Download completed, but local cache not detected."
                viewModel.probes.localLLMModelActionStatus = "Download completed, but local cache not detected."
                viewModel.probes.localLLMModelActionStatusIsError = true
            }
        } catch {
            print("[llm-download] Error: \(error)")
            viewModel.llmDownloadProgress.status = "error"
            viewModel.llmDownloadProgress.errorMessage = error.localizedDescription
            viewModel.probes.localLLMModelActionStatusIsError = true
            viewModel.probes.localLLMModelActionStatus = "Download failed: \(error.localizedDescription)"
        }
    }
    
    private func handleLLMDownloadEvent(_ event: [String: Any], repoID: String) {
        guard let eventType = event["event"] as? String else { return }
        print("[llm-download] Handling event: \(eventType) - \(event)")
        
        switch eventType {
        case "start":
            viewModel.llmDownloadProgress.status = "downloading"
            viewModel.llmDownloadProgress.repoID = event["repo_id"] as? String ?? repoID
            viewModel.llmDownloadProgress.currentFile = "Starting download..."
            
        case "info":
            viewModel.llmDownloadProgress.currentFile = "Discovering files..."
            
        case "progress":
            if let progress = event["progress"] as? Double, progress > viewModel.llmDownloadProgress.progress {
                viewModel.llmDownloadProgress.progress = progress
            }
            if let downloaded = event["downloaded_bytes"] as? Int {
                viewModel.llmDownloadProgress.downloadedBytes = downloaded
            }
            if let total = event["total_bytes"] as? Int, total > 0 {
                viewModel.llmDownloadProgress.totalBytes = total
            }
            if let file = event["current_file"] as? String, !file.isEmpty {
                viewModel.llmDownloadProgress.currentFile = file
            }
            if let speed = event["speed_mbps"] as? Double {
                viewModel.llmDownloadProgress.speedMbps = speed
            }
            if let eta = event["eta_seconds"] as? Int {
                viewModel.llmDownloadProgress.etaSeconds = eta
            }
            
        case "verifying":
            viewModel.llmDownloadProgress.status = "verifying"
            viewModel.llmDownloadProgress.currentFile = "Verifying files..."
            
        case "complete":
            viewModel.llmDownloadProgress.status = "complete"
            viewModel.llmDownloadProgress.progress = 100.0
            viewModel.probes.localLLMModelActionStatus = "Model downloaded: \(repoID)"
            print("[llm-download] Complete event received")
            // Set the downloaded model as active
            engine.llmModel = repoID
            
        case "error":
            viewModel.llmDownloadProgress.status = "error"
            viewModel.llmDownloadProgress.errorMessage = event["message"] as? String ?? "Unknown error"
            viewModel.probes.localLLMModelActionStatusIsError = true
            viewModel.probes.localLLMModelActionStatus = "Download failed: \(viewModel.llmDownloadProgress.errorMessage)"
            
        default:
            print("[llm-download] Unknown event type: \(eventType)")
            break
        }
    }
    
    private func clearSelectedLocalLLMModelCache() async {
        guard !viewModel.probes.isClearingLocalLLMModelCache else { return }
        let repoID = engine.llmModel
        viewModel.probes.isClearingLocalLLMModelCache = true
        viewModel.probes.localLLMModelActionStatusIsError = false
        viewModel.probes.localLLMModelActionStatus = prefs.ui(
            "正在清理模型缓存：\(repoID)",
            "Clearing model cache: \(repoID)"
        )
        defer { viewModel.probes.isClearingLocalLLMModelCache = false }

        do {
            // Delete via backend API
            let url = URL(string: "http://127.0.0.1:8765/local_llm/delete")!
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONEncoder().encode(["repo_id": repoID])
            let (_, response) = try await URLSession.shared.data(for: req)
            
            if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                viewModel.probes.localLLMModelActionStatus = prefs.ui(
                    "模型缓存已清理。",
                    "Model cache cleared."
                )
            } else {
                throw NSError(domain: "LocalLLM", code: -1, userInfo: [NSLocalizedDescriptionKey: "Backend returned error"])
            }
        } catch {
            viewModel.probes.localLLMModelActionStatusIsError = true
            viewModel.probes.localLLMModelActionStatus = prefs.ui(
                "清理失败：\(error.localizedDescription)",
                "Failed to clear cache: \(error.localizedDescription)"
            )
        }
    }
    
    private func revealLLMCacheInFinder() {
        let hfCachePath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub")
        NSWorkspace.shared.open(hfCachePath)
    }
}