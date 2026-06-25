import Foundation

struct Prediction: Sendable, Equatable {
    let token: String
    let confidence: Double
    let displayTitle: String
    let displayDescription: String
    let suggestedContent: String
}

struct ActionChainPrediction: Sendable, Equatable {
    let confidence: Double
    let steps: [PredictedActionStep]
}

enum PredictedActionStep: Sendable, Equatable {
    case activateApp(bundleID: String, appName: String)
    case pasteText(text: String, appName: String)
    case typeText(text: String, appName: String)
    case clickElement(description: String, appName: String)
}

enum MicroValueNormalizer {
    static func normalizeTypedText(_ text: String, token: String) -> String? {
        let trimmed = cleaned(text)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.count <= 160 else { return nil }

        if token.contains(":terminal") {
            return normalizeCommand(trimmed)
        }

        guard trimmed.count <= 80 else { return nil }
        guard !trimmed.contains("\n") else { return nil }
        return trimmed
    }

    static func normalizeClickTarget(_ elementDescription: String) -> String? {
        let trimmed = cleaned(elementDescription)
        guard !trimmed.isEmpty else { return nil }

        if let title = extractParenthesizedValue(named: "Title", from: trimmed) {
            return title
        }
        if let description = extractParenthesizedValue(named: "Description", from: trimmed) {
            return description
        }
        if let value = extractParenthesizedValue(named: "Value", from: trimmed) {
            return value
        }

        let structuralRoles: Set<String> = [
            "AXGroup",
            "AXScrollArea",
            "AXImage",
            "AXLayoutArea",
            "AXSplitGroup",
            "AXUnknown",
        ]
        let role = trimmed.components(separatedBy: CharacterSet(charactersIn: " (")).first ?? trimmed
        guard !structuralRoles.contains(role) else { return nil }
        return role
    }

    static func normalizeCommand(_ command: String) -> String? {
        let command = cleaned(command)
        guard !command.isEmpty else { return nil }

        let parts = command.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard let executable = parts.first else { return nil }

        switch executable {
        case "git", "gh", "brew", "npm", "pnpm", "yarn", "swift", "xcodebuild":
            if parts.count >= 2 {
                return "\(executable) \(parts[1])"
            }
            return executable
        default:
            return command.count <= 80 ? command : nil
        }
    }

    private static func extractParenthesizedValue(named name: String, from text: String) -> String? {
        let pattern = "\(name):"
        guard let range = text.range(of: pattern) else { return nil }

        let start = range.upperBound
        let suffix = text[start...]
        let end = suffix.firstIndex(of: ")") ?? suffix.endIndex
        let value = suffix[..<end]
            .trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func cleaned(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\u{8}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
