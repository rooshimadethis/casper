import Foundation

enum Tokenizer {

    static func tokenize(_ event: DesktopUserEvent, activeAppName: String? = nil) -> String? {
        switch event {
        case .appActivated(_, let bundleID, _):
            return "a:\(bundleID)"
        case .textCopied(let text):
            guard text.count <= 80 else { return nil }
            let appName = activeAppName ?? "unknown"
            let truncated = text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40)
            return "c:\(appName):\(truncated)"
        case .mouseClicked(let appName, let elementClicked, _, _):
            let role = extractRole(from: elementClicked)
            return "m:\(appName):\(role)"
        case .typingSession(let appName, _, _, _):
            return "k:\(appName)"
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

    private static func extractRole(from elementDescription: String) -> String {
        let prefix = elementDescription
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: CharacterSet(charactersIn: " ("))
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "UnknownRole"
        return prefix.isEmpty ? "UnknownRole" : prefix
    }
}
