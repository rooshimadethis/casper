import Foundation

enum Tokenizer {

    static func tokenize(_ event: DesktopUserEvent, activeAppName: String? = nil) -> String? {
        switch event {
        case .appActivated(_, let bundleID, _):
            return "a:\(bundleID)"
        case .textCopied:
            let appName = activeAppName ?? "unknown"
            return "c:\(appName)"
        case .mouseClicked(let appName, let elementClicked, _, let selectedText):
            if let selectedText, !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let role = extractRole(from: elementClicked)
                return "s:\(appName):\(role)"
            }
            let role = extractRole(from: elementClicked)
            return "m:\(appName):\(role)"
        case .typingSession(let appName, let targetElement, _, _):
            let elementType = classifyTargetElement(targetElement)
            return "k:\(appName):\(elementType)"
        case .windowTitleChanged(let appName, _):
            return "t:\(appName)"
        case .userHesitated(let appName, let durationSeconds):
            guard durationSeconds >= 3 else { return nil }
            let bucket: String
            if durationSeconds < 5 {
                bucket = "short"
            } else if durationSeconds < 10 {
                bucket = "medium"
            } else {
                bucket = "long"
            }
            return "h:\(appName):\(bucket)"
        case .commandExecuted(_, let exitCode, _):
            let appName = activeAppName ?? "unknown"
            let status = exitCode == 0 ? "success" : "failure"
            return "x:\(appName):\(status)"
        case .appStalled, .customInput, .screenOcrCaptured:
            return nil
        }
    }

    static func classifyTargetElement(_ description: String?) -> String {
        guard let desc = description else { return "unknown" }
        let lower = desc.lowercased()
        if lower.contains("terminal") { return "terminal" }
        if lower.contains("source control") || lower.contains("commit") { return "source_control" }
        if lower.contains("search") || lower.contains("find") { return "search" }
        if lower.contains("youtube") || lower.contains("video player") { return "media" }
        if lower.contains("chat") || lower.contains("message") { return "chat" }
        if lower.contains("address") || lower.contains("url") { return "url_bar" }
        if lower.contains("console") || lower.contains("debug") { return "console" }
        return "text_field"
    }

    private static func extractRole(from elementDescription: String) -> String {
        let prefix = elementDescription
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: CharacterSet(charactersIn: " ("))
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "UnknownRole"
        return prefix.isEmpty ? "UnknownRole" : prefix
    }
}
