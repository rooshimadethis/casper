import AppKit
import SwiftUI
import Combine

final class PredictionOverlayWindowController: NSObject {
    private var panel: NSPanel?
    private var hostingController: NSHostingController<AnyView>?
    private var cancellables = Set<AnyCancellable>()
    private var currentPredictions: [Prediction] = []
    private var isForciblyHidden = false
    private var isManuallyVisible = false

    var debugLogger: ((DebugLogCategory, String) -> Void)?

    private let predictor: RuntimePredictor

    var isVisible: Bool {
        panel?.isVisible ?? false
    }

    init(predictor: RuntimePredictor) {
        self.predictor = predictor
        super.init()
        subscribe()
    }

    func show() {
        isForciblyHidden = false
        isManuallyVisible = true
        let predictions = predictor.topPredictions
        if !predictions.isEmpty {
            debugLogger?(.prediction, "Overlay shown (manual, \(predictions.count) predictions)")
            showPanel(with: predictions)
        } else {
            debugLogger?(.prediction, "Overlay shown (manual, no predictions - empty state)")
            showEmptyPanel()
        }
    }

    func hide() {
        debugLogger?(.prediction, "Overlay hidden (manual)")
        isForciblyHidden = true
        isManuallyVisible = false
        hidePanel()
    }

    private func subscribe() {
        predictor.$topPredictions
            .receive(on: DispatchQueue.main)
            .sink { [weak self] predictions in
                guard let self else { return }
                let hadPredictions = !currentPredictions.isEmpty
                currentPredictions = predictions
                guard !isForciblyHidden else {
                    if !predictions.isEmpty {
                        debugLogger?(.prediction, "Prediction update ignored (overlay forcibly hidden)")
                    }
                    return
                }
                if !predictions.isEmpty {
                    debugLogger?(.prediction, "Overlay shown with \(predictions.count) predictions")
                    showPanel(with: predictions)
                } else if !isManuallyVisible {
                    if hadPredictions {
                        debugLogger?(.prediction, "Overlay auto-hidden (predictions cleared)")
                    }
                    hidePanel()
                }
            }
            .store(in: &cancellables)
    }

    private func showPanel(with predictions: [Prediction]) {
        let newRoot = AnyView(PredictionOverlayView(
            predictions: predictions,
            onAction: { [weak self] prediction in self?.handleAction(prediction) },
            onDismiss: { [weak self] in self?.handleDismiss() }
        ))

        if let existingPanel = panel {
            hostingController?.rootView = newRoot
            if !existingPanel.isVisible {
                existingPanel.alphaValue = 0
                existingPanel.orderFrontRegardless()
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.2
                    existingPanel.animator().alphaValue = 1
                }
            }
            return
        }

        let hostingController = NSHostingController(rootView: newRoot)
        self.hostingController = hostingController
        configureAndShowPanel(hostingController: hostingController)
    }

    private func showEmptyPanel() {
        let newRoot = AnyView(PredictionOverlayEmptyView(
            onDismiss: { [weak self] in self?.handleDismiss() }
        ))

        if let existingPanel = panel {
            hostingController?.rootView = newRoot
            if !existingPanel.isVisible {
                existingPanel.alphaValue = 0
                existingPanel.orderFrontRegardless()
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.2
                    existingPanel.animator().alphaValue = 1
                }
            }
            return
        }

        let hostingController = NSHostingController(rootView: newRoot)
        self.hostingController = hostingController
        configureAndShowPanel(hostingController: hostingController)
    }

    private func configureAndShowPanel(hostingController: NSHostingController<AnyView>) {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 260),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isFloatingPanel = true
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.contentViewController = hostingController
        positionPanel(panel)

        panel.alphaValue = 0
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            panel.animator().alphaValue = 1
        }

        self.panel = panel
    }

    private func hidePanel() {
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().alphaValue = 0
        } completionHandler: {
            panel.orderOut(nil)
        }
    }

    private func handleAction(_ prediction: Prediction) {
        debugLogger?(.prediction, "Action triggered: \(prediction.token)")
        if prediction.token.hasPrefix("a:") {
            let bundleID = prediction.suggestedContent
            if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                NSWorkspace.shared.open(appURL)
                debugLogger?(.prediction, "Launched app: \(bundleID)")
            } else {
                debugLogger?(.prediction, "Failed to find app for bundle: \(bundleID)")
            }
        }
        predictor.currentPrediction = nil
        currentPredictions = []
        hidePanel()
    }

    private func handleDismiss() {
        debugLogger?(.prediction, "Overlay dismissed by user")
        predictor.currentPrediction = nil
        currentPredictions = []
        hidePanel()
    }

    private func positionPanel(_ panel: NSPanel) {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.main
            ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let panelWidth = panel.frame.width
        let panelHeight = panel.frame.height

        let x = visible.midX - panelWidth / 2
        let y = visible.minY + 40

        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
