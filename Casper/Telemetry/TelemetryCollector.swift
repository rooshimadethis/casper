import AppKit
import Foundation
import CoreGraphics

/// Passive telemetry collector that monitors window titles, application focus,
/// clipboard copies, user clicks, and app stalls on macOS.
@MainActor
final class TelemetryCollector: ObservableObject {
    private let storage: TelemetryStorage
    private let powerMonitor: any TelemetryPowerMonitoring
    private let ocrService: FrontmostWindowOCRService
    
    private var pollTimer: Timer?
    private var clickMonitor: Any?
    
    // Tracking state
    private var lastAppName = ""
    private var lastBundleID = ""
    private var lastWindowTitle = ""
    private var lastChangeCount = 0
    private var lastEventTime = Date()
    private var lastFocusChangeTime = Date()
    private var didLogHesitationForCurrentFocus = false
    
    // App stall tracking
    private var stalledAppName: String?
    private var stallStartTime: Date?

    // Typing tracking state
    private var activeTypingAppName = ""
    private var activeTypingStartTime: Date?
    private var activeTypingLastTime: Date?
    private var activeTypingText = ""
    private var typingDebounceTimer: Timer?
    private var keyboardMonitor: Any?
    private var localKeyboardMonitor: Any?

    init(
        storage: TelemetryStorage,
        powerMonitor: any TelemetryPowerMonitoring,
        ocrService: FrontmostWindowOCRService
    ) {
        self.storage = storage
        self.powerMonitor = powerMonitor
        self.ocrService = ocrService
    }

    /// Starts passive monitoring of macOS workspace events.
    func start() {
        guard pollTimer == nil else { return }

        // Core polling timer runs every 2.0 seconds
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pollWorkspaceState()
            }
        }

        // Global mouse click observer
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            Task { @MainActor in
                self?.handleMouseClick(event)
            }
        }

        // Global keyboard observer (requires Accessibility or Input Monitoring permissions)
        keyboardMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            Task { @MainActor in
                self?.handleKeyPress(event)
            }
        }

        // Local keyboard observer (captures when Casper window is active)
        localKeyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            Task { @MainActor in
                self?.handleKeyPress(event)
            }
            return event
        }
        
        // Record starting state
        pollWorkspaceState()
    }

    /// Stops passive monitoring.
    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        
        if let monitor = clickMonitor {
            NSEvent.removeMonitor(monitor)
            clickMonitor = nil
        }

        if let monitor = keyboardMonitor {
            NSEvent.removeMonitor(monitor)
            keyboardMonitor = nil
        }
        if let monitor = localKeyboardMonitor {
            NSEvent.removeMonitor(monitor)
            localKeyboardMonitor = nil
        }
        flushActiveTypingSession()
    }

    /// Public endpoint for shell integrations to forward executed command logs.
    func logCommandExecuted(command: String, exitCode: Int, output: String?) {
        flushActiveTypingSession()
        let event = DesktopUserEvent.commandExecuted(command: command, exitCode: exitCode, output: output)
        try? storage.appendEvent(event)
        recordUserInteraction()
    }

    // MARK: - Core Polling & Event Detection

    func pollWorkspaceState() {
        guard let frontmost = NSWorkspace.shared.frontmostApplication,
              let bundleID = frontmost.bundleIdentifier else {
            return
        }

        let appName = frontmost.localizedName ?? "Unknown"
        let windowTitles = AccessibilityWindowTitles.all(for: frontmost)
        let activeTitle = windowTitles.first ?? fetchWindowTitleFallback(for: frontmost) ?? ""

        let now = Date()

        // 1. Detect App Activation or Window Title Changes
        if bundleID != lastBundleID {
            flushActiveTypingSession()
            // Log Hesitation if user was looking at last focus and paused
            triggerHesitationCheckIfNeeded(now: now)
            
            // Log App Activation
            let event = DesktopUserEvent.appActivated(appName: appName, bundleID: bundleID, windowTitle: activeTitle)
            try? storage.appendEvent(event)
            
            lastAppName = appName
            lastBundleID = bundleID
            lastWindowTitle = activeTitle
            lastFocusChangeTime = now
            didLogHesitationForCurrentFocus = false
            recordUserInteraction()
            
            // Check App Stall status on activation
            handleStallStatus(for: frontmost, appName: appName, now: now)
            
        } else if activeTitle != lastWindowTitle {
            flushActiveTypingSession()
            // Log Window Title Change
            let event = DesktopUserEvent.windowTitleChanged(appName: appName, windowTitle: activeTitle)
            try? storage.appendEvent(event)
            
            lastWindowTitle = activeTitle
            recordUserInteraction()
        }

        // 2. Continuous App Stall Polling
        handleStallStatus(for: frontmost, appName: appName, now: now)

        // 3. Clipboard copy monitoring
        let pasteboard = NSPasteboard.general
        if pasteboard.changeCount != lastChangeCount {
            flushActiveTypingSession()
            lastChangeCount = pasteboard.changeCount
            if let text = pasteboard.string(forType: .string) {
                let event = DesktopUserEvent.textCopied(text: text)
                try? storage.appendEvent(event)
                recordUserInteraction()
            }
        }

        // 4. Periodic OCR Capture trigger (run when user is active but on a 10 min window)
        // Note: Check if 10 mins elapsed since focus change to take a text snapshot.
        let timeSinceFocus = now.timeIntervalSince(lastFocusChangeTime)
        if timeSinceFocus > 600 && timeSinceFocus < 605 { // small window to trigger once
            Task {
                if let ocrContext = await ocrService.captureContext(customWords: []) {
                    let event = DesktopUserEvent.screenOcrCaptured(text: ocrContext.windowContents)
                    try? storage.appendEvent(event)
                }
            }
        }
    }

    func handleMouseClick(_ event: NSEvent) {
        flushActiveTypingSession()
        recordUserInteraction()
        
        let screenLocation = NSEvent.mouseLocation
        let mainScreenHeight = NSScreen.screens.first?.frame.height ?? 1080
        
        // Convert screen coordinates to Carbon coordinates (Y-inverted)
        let cgX = Float(screenLocation.x)
        let cgY = Float(mainScreenHeight - screenLocation.y)
        
        var element: AXUIElement?
        let systemWide = AXUIElementCreateSystemWide()
        
        if AXUIElementCopyElementAtPosition(systemWide, cgX, cgY, &element) == .success, let clicked = element {
            var titleValue: CFTypeRef?
            var roleValue: CFTypeRef?
            
            AXUIElementCopyAttributeValue(clicked, kAXTitleAttribute as CFString, &titleValue)
            AXUIElementCopyAttributeValue(clicked, kAXRoleAttribute as CFString, &roleValue)
            
            let title = (titleValue as? String) ?? ""
            let role = (roleValue as? String) ?? "UnknownRole"
            let label = title.isEmpty ? role : "\(role): \(title)"
            
            let clickEvent = DesktopUserEvent.mouseClicked(
                appName: lastAppName,
                elementClicked: label
            )
            try? storage.appendEvent(clickEvent)
        }
    }

    private func isApplicationResponding(_ app: NSRunningApplication) -> Bool {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.2)
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value)
        return result != .cannotComplete
    }

    private func handleStallStatus(for app: NSRunningApplication, appName: String, now: Date) {
        if !isApplicationResponding(app) {
            if stalledAppName == nil {
                stalledAppName = appName
                stallStartTime = now
            }
        } else {
            if let stalledApp = stalledAppName, let start = stallStartTime {
                let rawDuration = now.timeIntervalSince(start)
                if rawDuration >= 2.0 {
                    let duration = (rawDuration * 10).rounded() / 10.0
                    let event = DesktopUserEvent.appStalled(appName: stalledApp, durationSeconds: duration)
                    try? storage.appendEvent(event)
                }
                stalledAppName = nil
                stallStartTime = nil
            }
        }
    }

    private func triggerHesitationCheckIfNeeded(now: Date) {
        if !didLogHesitationForCurrentFocus {
            let elapsedSinceInteraction = now.timeIntervalSince(lastEventTime)
            if elapsedSinceInteraction >= 3.0 && elapsedSinceInteraction <= 8.0 {
                let roundedElapsed = (elapsedSinceInteraction * 10).rounded() / 10.0
                let event = DesktopUserEvent.userHesitated(appName: lastAppName, durationSeconds: roundedElapsed)
                try? storage.appendEvent(event)
                didLogHesitationForCurrentFocus = true
            }
        }
    }

    private func recordUserInteraction() {
        lastEventTime = Date()
    }

    /// Fallback to list window titles using CoreGraphics window list if Accessibility APIs are restricted.
    private func fetchWindowTitleFallback(for app: NSRunningApplication) -> String? {
        let processID = app.processIdentifier
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        for windowInfo in windowList {
            guard let ownerProcessID = windowInfo[kCGWindowOwnerPID as String] as? pid_t,
                  ownerProcessID == processID else {
                continue
            }
            let layer = windowInfo[kCGWindowLayer as String] as? Int ?? 0
            let alpha = windowInfo[kCGWindowAlpha as String] as? Double ?? 1
            guard layer == 0, alpha > 0 else {
                continue
            }
            if let title = windowInfo[kCGWindowName as String] as? String, !title.isEmpty {
                return title
            }
        }
        return nil
    }

    // MARK: - Typing Session Management

    func handleKeyPress(_ event: NSEvent) {
        guard let characters = event.characters, !characters.isEmpty else {
            return
        }

        guard let frontmost = NSWorkspace.shared.frontmostApplication else {
            return
        }
        let appName = frontmost.localizedName ?? "Unknown"

        let now = Date()

        if !activeTypingAppName.isEmpty && appName != activeTypingAppName {
            flushActiveTypingSession()
        }

        if activeTypingAppName.isEmpty {
            activeTypingAppName = appName
            activeTypingStartTime = now
            activeTypingText = ""
        }

        var representation = characters
        
        switch event.keyCode {
        case 36:
            representation = "<Enter>"
        case 48:
            representation = "<Tab>"
        case 51:
            representation = "<Backspace>"
        case 53:
            representation = "<Esc>"
        case 117:
            representation = "<Delete>"
        default:
            if characters == "\r" || characters == "\n" {
                representation = "<Enter>"
            } else if characters == "\u{0009}" {
                representation = "<Tab>"
            } else if characters == "\u{001B}" {
                representation = "<Esc>"
            } else if characters == "\u{007F}" || characters == "\u{0008}" {
                representation = "<Backspace>"
            }
        }

        var modifierStr = ""
        let flags = event.modifierFlags
        let hasCmd = flags.contains(.command)
        let hasCtrl = flags.contains(.control)
        let hasOpt = flags.contains(.option)
        let hasShift = flags.contains(.shift)

        if hasCmd { modifierStr += "Cmd+" }
        if hasCtrl { modifierStr += "Ctrl+" }
        if hasOpt { modifierStr += "Opt+" }
        if hasShift {
            let isLetter = characters.count == 1 && characters.first?.isLetter == true
            let hasOtherModifiers = hasCmd || hasCtrl || hasOpt
            if !isLetter || hasOtherModifiers {
                modifierStr += "Shift+"
            }
        }

        if !modifierStr.isEmpty {
            representation = "<\(modifierStr)\(representation)>"
        }

        activeTypingText += representation
        activeTypingLastTime = now
        recordUserInteraction()

        typingDebounceTimer?.invalidate()
        typingDebounceTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.flushActiveTypingSession()
            }
        }
    }

    func flushActiveTypingSession() {
        typingDebounceTimer?.invalidate()
        typingDebounceTimer = nil

        guard !activeTypingAppName.isEmpty,
              let startTime = activeTypingStartTime,
              let lastTime = activeTypingLastTime,
              !activeTypingText.isEmpty else {
            activeTypingAppName = ""
            activeTypingStartTime = nil
            activeTypingLastTime = nil
            activeTypingText = ""
            return
        }

        let rawDuration = lastTime.timeIntervalSince(startTime)
        let duration = (rawDuration * 10).rounded() / 10.0
        let event = DesktopUserEvent.typingSession(
            appName: activeTypingAppName,
            typedText: activeTypingText,
            durationSeconds: duration
        )

        try? storage.appendEvent(event)

        activeTypingAppName = ""
        activeTypingStartTime = nil
        activeTypingLastTime = nil
        activeTypingText = ""
    }
}
