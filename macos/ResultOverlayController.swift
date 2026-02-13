import AppKit
import SwiftUI

@MainActor
final class ResultOverlayModel: ObservableObject {
    @Published var markdownText: String = ""
    @Published var statusText: String = ""
    @Published var showsStatus: Bool = false
    @Published var showActions: Bool = false
}

private final class FocuslessOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override var acceptsFirstResponder: Bool { false }
}

private struct ResultOverlayView: View {
    @ObservedObject var model: ResultOverlayModel
    let onCopy: () -> Void
    let onCancel: () -> Void

    private var hasCopyableText: Bool {
        !model.markdownText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        let cardShape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        let renderedText = model.markdownText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? " " : model.markdownText
        let markdownOptions = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )

        VStack(alignment: .leading, spacing: 6) {
            if model.showsStatus || model.showActions {
                HStack(spacing: 8) {
                    if model.showsStatus {
                        Text(model.statusText)
                            .font(.system(size: 11, weight: .semibold))
                            .italic()
                            .foregroundStyle(Color.white.opacity(0.8))
                            .lineLimit(1)
                    }

                    Spacer(minLength: 6)

                    if model.showActions {
                        Button(action: onCopy) {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color.white.opacity(hasCopyableText ? 0.88 : 0.45))
                        }
                        .buttonStyle(.plain)
                        .disabled(!hasCopyableText)
                        .help("Copy")

                        Button(action: onCancel) {
                            Image(systemName: "xmark")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color.white.opacity(0.88))
                        }
                        .buttonStyle(.plain)
                        .help("Cancel")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 10)
            }

            ScrollView {
                Group {
                    if let attributed = try? AttributedString(markdown: renderedText, options: markdownOptions) {
                        Text(attributed)
                            .font(.system(size: 14, weight: .regular, design: .default))
                            .italic()
                    } else {
                        Text(verbatim: renderedText)
                            .font(.system(size: 14, weight: .regular, design: .default))
                            .italic()
                    }
                }
                .foregroundStyle(Color(white: 0.92))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.top, model.showsStatus || model.showActions ? 0 : 10)
                .padding(.bottom, 10)
            }
        }
        .background(
            ZStack {
                cardShape.fill(.ultraThinMaterial)
                cardShape.fill(Color.black.opacity(0.58))
            }
        )
        .clipShape(cardShape)
        .overlay(cardShape.stroke(Color.white.opacity(0.08), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
        .environment(\.colorScheme, .dark)
    }
}

@MainActor
final class ResultOverlayController {
    private enum Layout {
        static let minWidth: CGFloat = 220
        static let maxWidth: CGFloat = 560
        static let minHeight: CGFloat = 56
        static let maxHeight: CGFloat = 300
        static let horizontalPadding: CGFloat = 28
        static let verticalPadding: CGFloat = 20
        static let contentFontSize: CGFloat = 14
        static let finalYOffset: CGFloat = 12
        static let initialYOffset: CGFloat = -10
    }

    private let panel: FocuslessOverlayPanel
    private let model = ResultOverlayModel()
    private var visible = false
    private var pendingHideWorkItem: DispatchWorkItem?
    private var statusCycleTimer: Timer?
    private var statusCycleValues: [String] = []
    private var statusCycleIndex: Int = 0

    var onCopyRequested: ((String) -> Void)?
    var onCancelRequested: (() -> Void)?

    init() {
        panel = FocuslessOverlayPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 92),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.alphaValue = 0
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.appearance = NSAppearance(named: .darkAqua)

        let host = NSHostingView(
            rootView: ResultOverlayView(
                model: model,
                onCopy: { [weak self] in
                    self?.handleCopyTapped()
                },
                onCancel: { [weak self] in
                    self?.handleCancelTapped()
                }
            )
            .environment(\.colorScheme, .dark)
        )
        host.frame = panel.contentView?.bounds ?? .zero
        host.autoresizingMask = [.width, .height]
        host.wantsLayer = true
        panel.contentView = host
        host.layer?.backgroundColor = CGColor.clear
        host.layer?.isOpaque = false
    }

    func reset() {
        cancelPendingHide()
        stopStatusCycle()
        model.markdownText = ""
        model.statusText = ""
        model.showsStatus = false
        model.showActions = false
        panel.ignoresMouseEvents = true
        visible = false
        panel.orderOut(nil)
        panel.alphaValue = 0
    }

    func showAskPending(anchorFrame: NSRect, statusCycle: [String]) {
        cancelPendingHide()
        configureInteraction(enabled: true)
        model.markdownText = ""
        model.showActions = true

        let cleanedStatuses = statusCycle
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let fallback = ["Thinking..."]
        statusCycleValues = cleanedStatuses.isEmpty ? fallback : cleanedStatuses
        statusCycleIndex = 0
        model.statusText = statusCycleValues[0]
        model.showsStatus = true
        startStatusCycleIfNeeded()
        showOrUpdate(above: anchorFrame)
    }

    func append(_ token: String, anchorFrame: NSRect, interactive: Bool = false) {
        guard !token.isEmpty else { return }
        cancelPendingHide()
        configureInteraction(enabled: interactive)
        if interactive {
            model.showActions = true
            stopStatusCycle()
            model.showsStatus = false
        } else {
            model.showActions = false
            model.showsStatus = false
        }
        model.markdownText += token
        showOrUpdate(above: anchorFrame)
    }

    func setFinalText(_ text: String, anchorFrame: NSRect, interactive: Bool) {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        cancelPendingHide()
        configureInteraction(enabled: interactive)
        if interactive {
            model.showActions = true
        } else {
            model.showActions = false
        }
        stopStatusCycle()
        model.showsStatus = false
        model.statusText = ""
        model.markdownText = cleaned
        showOrUpdate(above: anchorFrame)
    }

    func dismiss() {
        hide(after: 0.0)
    }

    func show(above anchorFrame: NSRect, targetSize: NSSize) {
        let startFrame = frame(above: anchorFrame, size: targetSize, yOffset: Layout.initialYOffset)
        panel.setFrame(startFrame, display: true)
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.30
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            let target = frame(above: anchorFrame, size: targetSize, yOffset: Layout.finalYOffset)
            panel.animator().setFrame(target, display: true)
        }
        visible = true
    }

    func hide(after delay: TimeInterval = 1.5) {
        guard visible else { return }
        cancelPendingHide()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.stopStatusCycle()
            NSAnimationContext.runAnimationGroup(
                { context in
                    context.duration = 0.25
                    self.panel.animator().alphaValue = 0
                },
                completionHandler: {
                    self.panel.orderOut(nil)
                    Task { @MainActor in
                        self.visible = false
                        self.model.showsStatus = false
                    }
                }
            )
        }
        pendingHideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func updateLayout(above anchorFrame: NSRect, targetSize: NSSize) {
        let targetFrame = frame(above: anchorFrame, size: targetSize, yOffset: Layout.finalYOffset)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(targetFrame, display: true)
        }
    }

    private func frame(above anchorFrame: NSRect, size: NSSize, yOffset: CGFloat) -> NSRect {
        let targetX = anchorFrame.midX - size.width / 2
        let targetY = anchorFrame.maxY + yOffset
        return NSRect(origin: NSPoint(x: targetX, y: targetY), size: size)
    }

    private func panelSize(for text: String, hasStatus: Bool, showActions: Bool) -> NSSize {
        let compact = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if compact.isEmpty, !hasStatus, !showActions {
            return NSSize(width: 320, height: 92)
        }

        let renderText = compact.isEmpty ? " " : compact
        let nsText = renderText as NSString
        let drawOptions: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: Layout.contentFontSize),
        ]
        let candidateWidths: [CGFloat] = [220, 260, 300, 340, 380, 420, 460, 500, 560]
        let maxPreferredHeight: CGFloat = 170

        var selectedWidth = Layout.maxWidth
        var selectedHeight = Layout.minHeight

        for width in candidateWidths {
            let contentWidth = max(80, width - Layout.horizontalPadding)
            let bounds = nsText.boundingRect(
                with: NSSize(width: contentWidth, height: .greatestFiniteMagnitude),
                options: drawOptions,
                attributes: attributes
            )
            let measuredHeight = ceil(bounds.height) + Layout.verticalPadding
            if measuredHeight <= maxPreferredHeight {
                selectedWidth = width
                selectedHeight = measuredHeight
                break
            }
        }

        if selectedHeight == Layout.minHeight {
            let contentWidth = max(80, selectedWidth - Layout.horizontalPadding)
            let bounds = nsText.boundingRect(
                with: NSSize(width: contentWidth, height: .greatestFiniteMagnitude),
                options: drawOptions,
                attributes: attributes
            )
            selectedHeight = ceil(bounds.height) + Layout.verticalPadding
        }

        if hasStatus || showActions {
            selectedHeight += 22
        }
        if showActions && compact.isEmpty {
            selectedHeight = max(selectedHeight, 86)
        }

        let finalWidth = min(max(selectedWidth, Layout.minWidth), Layout.maxWidth)
        let finalHeight = min(max(selectedHeight, Layout.minHeight), Layout.maxHeight)
        return NSSize(width: finalWidth, height: finalHeight)
    }

    private func showOrUpdate(above anchorFrame: NSRect) {
        let targetSize = panelSize(
            for: model.markdownText,
            hasStatus: model.showsStatus,
            showActions: model.showActions
        )
        if !visible {
            show(above: anchorFrame, targetSize: targetSize)
        } else {
            updateLayout(above: anchorFrame, targetSize: targetSize)
        }
    }

    private func handleCopyTapped() {
        let cleaned = model.markdownText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        onCopyRequested?(cleaned)
    }

    private func handleCancelTapped() {
        onCancelRequested?()
    }

    private func configureInteraction(enabled: Bool) {
        panel.ignoresMouseEvents = !enabled
    }

    private func startStatusCycleIfNeeded() {
        stopStatusCycle()
        guard statusCycleValues.count > 1 else { return }
        statusCycleTimer = Timer.scheduledTimer(withTimeInterval: 1.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.model.showsStatus else { return }
                guard !self.statusCycleValues.isEmpty else { return }
                self.statusCycleIndex = (self.statusCycleIndex + 1) % self.statusCycleValues.count
                self.model.statusText = self.statusCycleValues[self.statusCycleIndex]
            }
        }
    }

    private func stopStatusCycle() {
        statusCycleTimer?.invalidate()
        statusCycleTimer = nil
        statusCycleValues = []
        statusCycleIndex = 0
    }

    private func cancelPendingHide() {
        pendingHideWorkItem?.cancel()
        pendingHideWorkItem = nil
    }
}
