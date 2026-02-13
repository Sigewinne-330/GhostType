import AppKit

private final class DraggableHUDContainerView: NSVisualEffectView {
    override var mouseDownCanMoveWindow: Bool { true }
}

private final class FocuslessHUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override var acceptsFirstResponder: Bool { false }
}

final class HUDPanelController: NSObject {
    private enum Layout {
        static let width: CGFloat = 210
        static let height: CGFloat = 56
        static let cornerRadius: CGFloat = 14
    }

    private static let panelOriginXKey = "hudPanelOriginX"
    private static let panelOriginYKey = "hudPanelOriginY"

    private let panel: FocuslessHUDPanel
    private let leftButton = NSButton()
    private let iconView = NSImageView()
    private let rightIcon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let waveformLabel = NSTextField(labelWithString: "")
    private let debugLabel = NSTextField(labelWithString: "")
    private var animationTimer: Timer?
    private var animationStep = 0
    private var hasSavedOrigin = false
    private var debugVisible = false
    var onCancelRequested: (() -> Void)?

    var frame: NSRect {
        panel.frame
    }

    override init() {
        panel = FocuslessHUDPanel(
            contentRect: NSRect(x: 0, y: 0, width: Layout.width, height: Layout.height),
            styleMask: [.nonactivatingPanel, .borderless, .hudWindow],
            backing: .buffered,
            defer: false
        )
        super.init()
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false
        panel.isMovable = true
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false

        let container = DraggableHUDContainerView(frame: panel.contentView?.bounds ?? .zero)
        container.translatesAutoresizingMaskIntoConstraints = false
        container.material = .hudWindow
        container.state = .active
        container.blendingMode = .withinWindow
        container.wantsLayer = true
        container.layer?.cornerRadius = Layout.cornerRadius
        container.layer?.masksToBounds = true
        container.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.9).cgColor

        leftButton.translatesAutoresizingMaskIntoConstraints = false
        leftButton.isBordered = false
        leftButton.bezelStyle = .shadowlessSquare
        leftButton.imagePosition = .imageOnly
        leftButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)
        leftButton.contentTintColor = .white
        leftButton.imageScaling = .scaleProportionallyDown
        leftButton.setButtonType(.momentaryChange)
        leftButton.target = self
        leftButton.action = #selector(handleCancelTapped)

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.contentTintColor = .white
        iconView.imageScaling = .scaleProportionallyDown
        iconView.wantsLayer = true

        rightIcon.translatesAutoresizingMaskIntoConstraints = false
        rightIcon.contentTintColor = .white
        rightIcon.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)
        rightIcon.imageScaling = .scaleProportionallyDown

        label.translatesAutoresizingMaskIntoConstraints = false
        label.textColor = .white
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.alignment = .left
        label.lineBreakMode = .byTruncatingTail

        waveformLabel.translatesAutoresizingMaskIntoConstraints = false
        waveformLabel.textColor = .white
        waveformLabel.font = .monospacedSystemFont(ofSize: 8, weight: .regular)
        waveformLabel.alignment = .left
        waveformLabel.alphaValue = 0.85
        waveformLabel.lineBreakMode = .byTruncatingTail

        debugLabel.translatesAutoresizingMaskIntoConstraints = false
        debugLabel.textColor = .white.withAlphaComponent(0.75)
        debugLabel.font = .monospacedSystemFont(ofSize: 7, weight: .regular)
        debugLabel.alignment = .left
        debugLabel.lineBreakMode = .byTruncatingTail
        debugLabel.stringValue = ""
        debugLabel.isHidden = true

        let content = panel.contentView ?? NSView(frame: panel.frame)
        panel.contentView = content
        content.addSubview(container)
        container.addSubview(leftButton)
        container.addSubview(iconView)
        container.addSubview(rightIcon)
        container.addSubview(label)
        container.addSubview(waveformLabel)
        container.addSubview(debugLabel)

        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            container.topAnchor.constraint(equalTo: content.topAnchor),
            container.bottomAnchor.constraint(equalTo: content.bottomAnchor),

            leftButton.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 6),
            leftButton.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            leftButton.widthAnchor.constraint(equalToConstant: 11),
            leftButton.heightAnchor.constraint(equalToConstant: 11),

            iconView.leadingAnchor.constraint(equalTo: leftButton.trailingAnchor, constant: 6),
            iconView.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 10),
            iconView.heightAnchor.constraint(equalToConstant: 10),

            rightIcon.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            rightIcon.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            rightIcon.widthAnchor.constraint(equalToConstant: 8),
            rightIcon.heightAnchor.constraint(equalToConstant: 8),

            label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: rightIcon.leadingAnchor, constant: -6),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 7),

            waveformLabel.leadingAnchor.constraint(equalTo: label.leadingAnchor),
            waveformLabel.trailingAnchor.constraint(equalTo: label.trailingAnchor),
            waveformLabel.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 1),

            debugLabel.leadingAnchor.constraint(equalTo: label.leadingAnchor),
            debugLabel.trailingAnchor.constraint(equalTo: label.trailingAnchor),
            debugLabel.topAnchor.constraint(equalTo: waveformLabel.bottomAnchor, constant: 1)
        ])

        restorePanelOriginIfAvailable()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePanelDidMove),
            name: NSWindow.didMoveNotification,
            object: panel
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self, name: NSWindow.didMoveNotification, object: panel)
    }

    @objc private func handleCancelTapped() {
        onCancelRequested?()
    }

    func showRecording(mode: WorkflowMode) {
        stopAnimation()
        waveformLabel.stringValue = "|||| || ||||"
        if !debugVisible {
            debugLabel.stringValue = ""
            debugLabel.isHidden = true
        }
        update(symbol: "mic.fill", text: "\(mode.title) Recording")
        startWaveAnimation()
        show()
    }

    func showProcessing(mode: WorkflowMode) {
        stopAnimation()
        waveformLabel.stringValue = "..."
        debugVisible = false
        debugLabel.stringValue = ""
        debugLabel.isHidden = true
        update(symbol: "sparkles", text: "\(mode.title) Processing")
        startSpinnerAnimation()
        show()
    }

    func showDone() {
        stopAnimation()
        waveformLabel.stringValue = "Done"
        debugVisible = false
        debugLabel.stringValue = ""
        debugLabel.isHidden = true
        update(symbol: "checkmark.circle.fill", text: "Inserted")
        show()
    }

    func showAskReady() {
        stopAnimation()
        waveformLabel.stringValue = "Ready"
        debugVisible = false
        debugLabel.stringValue = ""
        debugLabel.isHidden = true
        update(symbol: "bubble.left.and.bubble.right.fill", text: "Ask Ready")
        show()
    }

    func showCopied() {
        stopAnimation()
        waveformLabel.stringValue = "Clipboard"
        debugVisible = false
        debugLabel.stringValue = ""
        debugLabel.isHidden = true
        update(symbol: "doc.on.doc.fill", text: "Copied")
        show()
    }

    func showError(message: String) {
        stopAnimation()
        waveformLabel.stringValue = "Failed"
        debugVisible = false
        debugLabel.stringValue = ""
        debugLabel.isHidden = true
        update(symbol: "xmark.circle.fill", text: message)
        show()
    }

    func updateAudioDebugTelemetry(
        rmsDBFS: Float,
        peakDBFS: Float,
        vadSpeech: Bool,
        enabled: Bool
    ) {
        guard panel.isVisible else { return }
        guard label.stringValue.contains("Recording") else { return }
        if !enabled {
            if debugVisible {
                debugVisible = false
                debugLabel.stringValue = ""
                debugLabel.isHidden = true
            }
            return
        }

        debugVisible = true
        debugLabel.isHidden = false
        let vadText = vadSpeech ? "Speech" : "Silence"
        debugLabel.stringValue = String(
            format: "%@  RMS %.1f dB  Peak %.1f dB",
            vadText,
            rmsDBFS,
            peakDBFS
        )
    }

    func showInferenceTimingTelemetry(_ summary: String, enabled: Bool) {
        guard panel.isVisible else { return }
        guard enabled else {
            if debugVisible {
                debugVisible = false
                debugLabel.stringValue = ""
                debugLabel.isHidden = true
            }
            return
        }
        debugVisible = true
        debugLabel.isHidden = false
        debugLabel.stringValue = summary
    }

    func hide(after delay: TimeInterval = 0.0) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.stopAnimation()
            self?.panel.orderOut(nil)
        }
    }

    private func show() {
        if hasSavedOrigin {
            positionAtSavedOrigin()
        } else {
            positionAtBottomCenter()
        }
        panel.orderFrontRegardless()
    }

    private func update(symbol: String, text: String) {
        iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        label.stringValue = text
    }

    private func positionAtBottomCenter() {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let x = visible.midX - panel.frame.width / 2
        let y = visible.minY + 20
        persistPanelOrigin(NSPoint(x: x, y: y))
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func positionAtSavedOrigin() {
        guard let visible = (panel.screen ?? NSScreen.main)?.visibleFrame else { return }
        let clamped = clampedOrigin(panel.frame.origin, in: visible)
        persistPanelOrigin(clamped)
        panel.setFrameOrigin(clamped)
    }

    private func clampedOrigin(_ origin: NSPoint, in visible: NSRect) -> NSPoint {
        let minX = visible.minX
        let maxX = max(minX, visible.maxX - panel.frame.width)
        let minY = visible.minY
        let maxY = max(minY, visible.maxY - panel.frame.height)

        return NSPoint(
            x: min(max(origin.x, minX), maxX),
            y: min(max(origin.y, minY), maxY)
        )
    }

    private func restorePanelOriginIfAvailable() {
        let defaults = UserDefaults.standard
        guard
            let storedX = defaults.object(forKey: Self.panelOriginXKey) as? Double,
            let storedY = defaults.object(forKey: Self.panelOriginYKey) as? Double
        else {
            return
        }

        let restored = NSPoint(x: storedX, y: storedY)
        panel.setFrameOrigin(restored)
        hasSavedOrigin = true
    }

    @objc private func handlePanelDidMove(_ notification: Notification) {
        persistPanelOrigin(panel.frame.origin)
    }

    private func persistPanelOrigin(_ origin: NSPoint) {
        hasSavedOrigin = true
        let defaults = UserDefaults.standard
        defaults.set(Double(origin.x), forKey: Self.panelOriginXKey)
        defaults.set(Double(origin.y), forKey: Self.panelOriginYKey)
    }

    private func startWaveAnimation() {
        animationStep = 0
        animationTimer = Timer.scheduledTimer(withTimeInterval: 0.18, repeats: true) { [weak self] _ in
            guard let self else { return }
            let frames = [
                "| ||| || ||||",
                "|| |||| ||| |",
                "||| || |||| ||",
                "|| ||| || ||||",
            ]
            self.waveformLabel.stringValue = frames[self.animationStep % frames.count]
            let scale = 1.0 + (0.08 * sin(Double(self.animationStep) * 0.8))
            self.iconView.layer?.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale))
            self.iconView.alphaValue = 0.78 + CGFloat((sin(Double(self.animationStep) * 0.9) + 1) * 0.11)
            self.animationStep += 1
        }
    }

    private func startSpinnerAnimation() {
        animationStep = 0
        animationTimer = Timer.scheduledTimer(withTimeInterval: 0.16, repeats: true) { [weak self] _ in
            guard let self else { return }
            let frames = ["...", ".. ", ".  ", "   "]
            self.waveformLabel.stringValue = "Loading\(frames[self.animationStep % frames.count])"
            self.animationStep += 1
        }
    }

    private func stopAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil
        animationStep = 0
        iconView.layer?.setAffineTransform(.identity)
        iconView.alphaValue = 1
    }
}
