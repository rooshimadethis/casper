import Foundation
import Combine

struct Prediction: Sendable, Equatable {
    let token: String
    let confidence: Double
    let displayTitle: String
    let displayDescription: String
    let suggestedContent: String
}

final class RuntimePredictor: ObservableObject {
    @Published var currentPrediction: Prediction?
    @Published var topPredictions: [Prediction] = []

    var debugLogger: ((DebugLogCategory, String) -> Void)?

    let trie: PpmTrie
    let confidenceThreshold: Double
    let microStore: MicroStore

    private var slidingWindow: [String] = []
    private var bundleIDToAppName: [String: String] = [:]
    private var lastCopiedText: String = ""
    private var lastEmittedPrediction: Prediction?
    private var currentAppName: String = ""

    init(trie: PpmTrie, confidenceThreshold: Double = 0.5, microStore: MicroStore = MicroStore()) {
        self.trie = trie
        self.confidenceThreshold = confidenceThreshold
        self.microStore = microStore
    }

    func ingest(event: DesktopUserEvent) {
        updateContext(from: event)

        guard let token = Tokenizer.tokenize(event, activeAppName: currentAppName) else {
            debugLogger?(.prediction, "Ingest: no token for event \(event.shortDescription)")
            return
        }

        slidingWindow.append(token)
        if slidingWindow.count > PpmTrie.maxDepth {
            slidingWindow = Array(slidingWindow.suffix(PpmTrie.maxDepth))
        }

        debugLogger?(.prediction, "Ingest: token=\(token) window=[\(slidingWindow.joined(separator: ", "))]")

        let rawPredictions = trie.predict(context: slidingWindow)

        var built: [Prediction] = []
        for pred in rawPredictions.prefix(5) {
            var microValue: String?
            var microCount = 0
            if pred.token.hasPrefix("k:") || pred.token.hasPrefix("m:") {
                let contextHash = (slidingWindow + [pred.token]).joined(separator: " → ")
                let results = microStore.predict(for: contextHash)
                if let top = results.first, top.count >= 3 {
                    microValue = top.value
                    microCount = top.count
                }
            }
            if let p = buildPrediction(from: pred.token, confidence: pred.confidence, microValue: microValue, microCount: microCount) {
                built.append(p)
            }
        }
        topPredictions = built

        guard let top = built.first, top.confidence >= confidenceThreshold else {
            if currentPrediction != nil {
                debugLogger?(.prediction, "Prediction cleared (below threshold)")
                currentPrediction = nil
                lastEmittedPrediction = nil
            } else {
                let topHint = rawPredictions.first.map { " top=\($0.token):\(String(format: "%.2f", $0.confidence))" } ?? ""
                debugLogger?(.prediction, "No prediction\(topHint) (threshold=\(confidenceThreshold))")
            }
            return
        }

        guard top != lastEmittedPrediction else {
            debugLogger?(.prediction, "Prediction unchanged: \(top.displayTitle) (\(Int(top.confidence * 100))%)")
            return
        }

        debugLogger?(.prediction, "Prediction emitted: \(top.displayTitle) (\(Int(top.confidence * 100))%)")
        currentPrediction = top
        lastEmittedPrediction = top
    }

    private func updateContext(from event: DesktopUserEvent) {
        switch event {
        case .appActivated(let appName, let bundleID, _):
            bundleIDToAppName[bundleID] = appName
            currentAppName = appName
        case .textCopied(let text):
            lastCopiedText = text
        case .typingSession(let appName, _, _, _):
            currentAppName = appName
        case .mouseClicked(let appName, _, _, _):
            currentAppName = appName
        default:
            break
        }
    }

    private func buildPrediction(from token: String, confidence: Double, microValue: String? = nil, microCount: Int = 0) -> Prediction? {
        if token.hasPrefix("k:") {
            guard let microValue else { return nil }
            let appName = String(token.dropFirst(2))
            return Prediction(
                token: token,
                confidence: confidence,
                displayTitle: "Type \"\(microValue)\" in \(appName)?",
                displayDescription: "\(microCount) times before",
                suggestedContent: microValue
            )
        }

        if token.hasPrefix("m:") {
            guard let microValue else { return nil }
            let parts = token.dropFirst(2).split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            let appName = parts.first.map(String.init) ?? ""
            return Prediction(
                token: token,
                confidence: confidence,
                displayTitle: "Click \"\(microValue)\" in \(appName)?",
                displayDescription: "",
                suggestedContent: microValue
            )
        }

        if token.hasPrefix("a:") {
            let bundleID = String(token.dropFirst(2))
            let appName = bundleIDToAppName[bundleID] ?? bundleID
            return Prediction(
                token: token,
                confidence: confidence,
                displayTitle: "Switch to \(appName)",
                displayDescription: "Based on your recent pattern",
                suggestedContent: bundleID
            )
        }

        if token.hasPrefix("c:") {
            let parts = token.dropFirst(2).split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            let appName = parts.first.map(String.init) ?? ""
            let truncatedText = parts.count > 1 ? String(parts[1]) : ""
            let displayText = truncatedText.isEmpty ? "" : " \"\(truncatedText)\""
            return Prediction(
                token: token,
                confidence: confidence,
                displayTitle: "Paste copied text?",
                displayDescription: "You copied\(displayText) in \(appName)",
                suggestedContent: lastCopiedText
            )
        }

        return nil
    }
}
