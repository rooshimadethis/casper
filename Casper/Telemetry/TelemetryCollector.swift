import AppKit
import Foundation
import CoreGraphics
import ApplicationServices

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
    
    // Click tracking state
    private var pendingClickTimer: Timer?
    private var pendingClickEvent: (appName: String, element: String, clickCount: Int, recordedAt: Date)?
    
    // App stall tracking
    private var stalledAppName: String?
    private var stallStartTime: Date?

    // Typing tracking state
    private var activeTypingAppName = ""
    private var activeTypingStartTime: Date?
    private var activeTypingLastTime: Date?
    private enum TypingToken {
        case character(Character)
        case special(String)
        case backspace(count: Int)
    }
    private var activeTypingTokens: [TypingToken] = []
    private var activeTypingTargetElement: String? = nil
    private var typingDebounceTimer: Timer?
    private var keyboardMonitor: Any?
    private var localKeyboardMonitor: Any?

    var onEvent: ((DesktopUserEvent) -> Void)?
    var debugLogger: ((DebugLogCategory, String) -> Void)?

    private func recordEvent(_ event: DesktopUserEvent, recordedAt: Date = Date()) {
        try? storage.appendEvent(event, recordedAt: recordedAt)
        debugLogger?(.prediction, "Collected: \(event.shortDescription)")
        onEvent?(event)
    }

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
            MainActor.assumeIsolated {
                self?.pollWorkspaceState()
            }
        }

        // Global mouse click observer
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                self?.handleMouseClick(event)
            }
        }

        // Global keyboard observer (requires Accessibility or Input Monitoring permissions)
        keyboardMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            MainActor.assumeIsolated {
                self?.handleKeyPress(event)
            }
        }

        // Local keyboard observer (captures when Casper window is active)
        localKeyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            MainActor.assumeIsolated {
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
        flushPendingClick()
    }

    /// Public endpoint for shell integrations to forward executed command logs.
    func logCommandExecuted(command: String, exitCode: Int, output: String?) {
        flushActiveTypingSession()
        flushPendingClick()
        let event = DesktopUserEvent.commandExecuted(command: command, exitCode: exitCode, output: output)
        recordEvent(event)
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
            flushPendingClick()
            // Log Hesitation if user was looking at last focus and paused
            triggerHesitationCheckIfNeeded(now: now)
            
            // Log App Activation
            let event = DesktopUserEvent.appActivated(appName: appName, bundleID: bundleID, windowTitle: activeTitle)
            recordEvent(event)
            
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
            flushPendingClick()
            // Log Window Title Change
            let event = DesktopUserEvent.windowTitleChanged(appName: appName, windowTitle: activeTitle)
            recordEvent(event)
            
            lastWindowTitle = activeTitle
            recordUserInteraction()
        }

        // 2. Continuous App Stall Polling
        handleStallStatus(for: frontmost, appName: appName, now: now)

        // 3. Clipboard copy monitoring
        let pasteboard = NSPasteboard.general
        if pasteboard.changeCount != lastChangeCount {
            flushActiveTypingSession()
            flushPendingClick()
            lastChangeCount = pasteboard.changeCount
            if let text = pasteboard.string(forType: .string) {
                let processedText: String
                if text.count > 500 {
                    processedText = "[Truncated Copy]: " + text.prefix(500) + "..."
                } else {
                    processedText = text
                }
                let event = DesktopUserEvent.textCopied(text: processedText)
                recordEvent(event)
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
                    recordEvent(event)
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
            let label = resolveElementLabel(for: clicked)
            
            let appName = lastAppName
            let clickCount = event.clickCount
            let now = Date()
            
            pendingClickTimer?.invalidate()
            
            if clickCount > 1, let pending = pendingClickEvent, pending.element == label {
                pendingClickEvent = (appName: appName, element: label, clickCount: clickCount, recordedAt: pending.recordedAt)
            } else {
                flushPendingClick()
                pendingClickEvent = (appName: appName, element: label, clickCount: clickCount, recordedAt: now)
            }
            
            let delay = NSEvent.doubleClickInterval
            pendingClickTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    self?.flushPendingClick()
                }
            }
        }
    }

    private func resolveElementLabel(for element: AXUIElement) -> String {
        var current: AXUIElement = element
        var depth = 0
        let maxDepth = 7
        
        while depth < maxDepth {
            var roleValue: CFTypeRef?
            var titleValue: CFTypeRef?
            var valueValue: CFTypeRef?
            var descValue: CFTypeRef?
            var placeholderValue: CFTypeRef?
            var identifierValue: CFTypeRef?
            
            AXUIElementCopyAttributeValue(current, kAXRoleAttribute as CFString, &roleValue)
            AXUIElementCopyAttributeValue(current, kAXTitleAttribute as CFString, &titleValue)
            AXUIElementCopyAttributeValue(current, kAXValueAttribute as CFString, &valueValue)
            AXUIElementCopyAttributeValue(current, kAXDescriptionAttribute as CFString, &descValue)
            AXUIElementCopyAttributeValue(current, "AXPlaceholderValue" as CFString, &placeholderValue)
            AXUIElementCopyAttributeValue(current, kAXIdentifierAttribute as CFString, &identifierValue)
            
            let role = (roleValue as? String) ?? "UnknownRole"
            let title = (titleValue as? String) ?? ""
            
            var valueStr = ""
            if let val = valueValue {
                if let str = val as? String {
                    valueStr = str
                } else if let attrStr = val as? NSAttributedString {
                    valueStr = attrStr.string
                }
            }
            
            let desc = (descValue as? String) ?? ""
            let placeholder = (placeholderValue as? String) ?? ""
            let identifier = (identifierValue as? String) ?? ""
            
            var details: [String] = []
            if !title.isEmpty { details.append("Title: \(title)") }
            if !valueStr.isEmpty {
                let cleanVal = valueStr.trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleanVal.isEmpty {
                    let truncated = cleanVal.count > 120 ? cleanVal.prefix(120) + "..." : cleanVal
                    details.append("Value: \(truncated)")
                }
            }
            if !desc.isEmpty { details.append("Description: \(desc)") }
            if !placeholder.isEmpty { details.append("Placeholder: \(placeholder)") }
            if !identifier.isEmpty { details.append("ID: \(identifier)") }
            
            if !details.isEmpty {
                return "\(role) (\(details.joined(separator: ", ")))"
            }
            
            // For group-like containers with no direct label, probe children for AXStaticText
            let groupRoles: Set<String> = ["AXGroup", "AXSplitGroup", "AXLayoutArea", "AXLayoutItem"]
            if groupRoles.contains(role) {
                if let childLabel = findChildLabel(in: current, role: role) {
                    return childLabel
                }
            }
            
            // Go to parent if details are empty
            var parentValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parentValue) == .success,
               let parent = parentValue,
               CFGetTypeID(parent) == AXUIElementGetTypeID() {
                current = unsafeBitCast(parent, to: AXUIElement.self)
                depth += 1
            } else {
                break
            }
        }
        
        // Fallback to role of the original element
        var originalRole: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &originalRole)
        return (originalRole as? String) ?? "UnknownRole"
    }
    
    private func findChildLabel(in element: AXUIElement, role: String) -> String? {
        var childrenValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue) == .success,
              let children = childrenValue as? [AXUIElement] else {
            return nil
        }
        
        for child in children.prefix(15) {
            var childRole: CFTypeRef?
            var childValue: CFTypeRef?
            var childTitle: CFTypeRef?
            
            AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &childRole)
            AXUIElementCopyAttributeValue(child, kAXValueAttribute as CFString, &childValue)
            AXUIElementCopyAttributeValue(child, kAXTitleAttribute as CFString, &childTitle)
            
            let childRoleStr = (childRole as? String) ?? ""
            let value = (childValue as? String) ?? ""
            let title = (childTitle as? String) ?? ""
            
            if childRoleStr == "AXStaticText" || childRoleStr == "AXButton" {
                let label = value.isEmpty ? title : value
                if !label.isEmpty {
                    let clean = label.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !clean.isEmpty {
                        let truncated = clean.count > 120 ? clean.prefix(120) + "..." : clean
                        return "\(role) > \(childRoleStr) (Value: \(truncated))"
                    }
                }
            }
        }
        
        return nil
    }

    private func flushPendingClick() {
        pendingClickTimer?.invalidate()
        pendingClickTimer = nil
        
        guard let pending = pendingClickEvent else { return }
        pendingClickEvent = nil
        
        var selectedText: String? = nil
        
        if pending.clickCount > 1 {
            if PermissionChecker.checkAccessibility(),
               let frontmost = NSWorkspace.shared.frontmostApplication {
                let pid = frontmost.processIdentifier
                let appElement = AXUIElementCreateApplication(pid)
                var focusedElementValue: CFTypeRef?
                
                if AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedElementValue) == .success,
                   let val = focusedElementValue,
                   CFGetTypeID(val) == AXUIElementGetTypeID() {
                    let focusedElement = unsafeBitCast(val, to: AXUIElement.self)
                    var selectedTextValue: CFTypeRef?
                    if AXUIElementCopyAttributeValue(focusedElement, kAXSelectedTextAttribute as CFString, &selectedTextValue) == .success,
                       let text = selectedTextValue as? String,
                       !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        selectedText = text
                    }
                }
            }
        }
        
        let clickEvent = DesktopUserEvent.mouseClicked(
            appName: pending.appName,
            elementClicked: pending.element,
            clickCount: pending.clickCount,
            selectedText: selectedText
        )
        recordEvent(clickEvent, recordedAt: pending.recordedAt)
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
                    recordEvent(event)
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
                recordEvent(event)
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

    private func handleBackspaceToken() {
        if let lastToken = activeTypingTokens.last {
            if case .special(let str) = lastToken,
               str.lowercased() == "<cmd+a>" || str.lowercased() == "<cmd+shift+a>" {
                activeTypingTokens.removeLast()
                activeTypingTokens = activeTypingTokens.filter { token in
                    if case .character = token { return false }
                    return true
                }
                return
            }
        }
        
        if let lastCharIndex = activeTypingTokens.lastIndex(where: { token in
            if case .character = token { return true }
            return false
        }) {
            activeTypingTokens.remove(at: lastCharIndex)
            return
        }
        
        if let lastToken = activeTypingTokens.last, case .backspace(let count) = lastToken {
            activeTypingTokens.removeLast()
            activeTypingTokens.append(.backspace(count: count + 1))
        } else {
            activeTypingTokens.append(.backspace(count: 1))
        }
    }

    private func compileTypingTokens() -> String {
        var result = ""
        for token in activeTypingTokens {
            switch token {
            case .character(let char):
                result.append(char)
            case .special(let str):
                result.append(str)
            case .backspace(let count):
                if count == 1 {
                    result.append("<Backspace>")
                } else {
                    result.append("<Backspace x \(count)>")
                }
            }
        }
        return result
    }

    func handleKeyPress(_ event: NSEvent) {
        flushPendingClick()
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
        
        let isSpecialKey = event.keyCode == 36 || event.keyCode == 48 || event.keyCode == 51 || event.keyCode == 53 || event.keyCode == 117
        if hasShift {
            let hasOtherModifiers = hasCmd || hasCtrl || hasOpt
            if hasOtherModifiers || isSpecialKey {
                modifierStr += "Shift+"
            }
        }

        if !modifierStr.isEmpty {
            representation = "<\(modifierStr)\(representation)>"
        }

        let isCmdA = representation.lowercased() == "<cmd+a>" || representation.lowercased() == "<cmd+shift+a>"
        let isShortcut = (hasCmd || hasCtrl || hasOpt) && !isCmdA

        if isShortcut {
            if !activeTypingTokens.isEmpty {
                flushActiveTypingSession()
            }
            
            let locator = FocusedElementLocator()
            activeTypingTargetElement = locator.focusedElementDescription()
            
            activeTypingAppName = appName
            activeTypingStartTime = now
            activeTypingLastTime = now
            activeTypingTokens = [.special(representation)]
            
            flushActiveTypingSession()
        } else {
            if activeTypingAppName.isEmpty {
                activeTypingAppName = appName
                activeTypingStartTime = now
                activeTypingTokens = []
                
                let locator = FocusedElementLocator()
                activeTypingTargetElement = locator.focusedElementDescription()
            }
            activeTypingLastTime = now
            recordUserInteraction()

            let isEnterOrTab = event.keyCode == 36 || event.keyCode == 48 || representation == "<Enter>" || representation == "<Tab>"
            
            if isEnterOrTab {
                activeTypingTokens.append(.special(representation))
                flushActiveTypingSession()
            } else if event.keyCode == 51 || representation == "<Backspace>" {
                handleBackspaceToken()
            } else {
                if representation.count == 1, let char = representation.first {
                    activeTypingTokens.append(.character(char))
                } else {
                    activeTypingTokens.append(.special(representation))
                }
            }

            if !activeTypingAppName.isEmpty {
                typingDebounceTimer?.invalidate()
                typingDebounceTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
                    Task { @MainActor in
                        self?.flushActiveTypingSession()
                    }
                }
            }
        }
    }

    func flushActiveTypingSession() {
        typingDebounceTimer?.invalidate()
        typingDebounceTimer = nil

        guard !activeTypingAppName.isEmpty,
              let startTime = activeTypingStartTime,
              let lastTime = activeTypingLastTime,
              !activeTypingTokens.isEmpty else {
            activeTypingAppName = ""
            activeTypingStartTime = nil
            activeTypingLastTime = nil
            activeTypingTargetElement = nil
            activeTypingTokens = []
            return
        }

        let rawDuration = lastTime.timeIntervalSince(startTime)
        let duration = (rawDuration * 10).rounded() / 10.0
        
        let typedText = compileTypingTokens()
        
        let event = DesktopUserEvent.typingSession(
            appName: activeTypingAppName,
            targetElement: activeTypingTargetElement,
            typedText: typedText,
            durationSeconds: duration
        )

        recordEvent(event)

        activeTypingAppName = ""
        activeTypingStartTime = nil
        activeTypingLastTime = nil
        activeTypingTargetElement = nil
        activeTypingTokens = []
    }
}
