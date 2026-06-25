import Foundation
import Combine

final class RuntimePredictor: PredictionProviding {
    private(set) var currentPrediction: Prediction?
    private(set) var topPredictions: [Prediction] = []

    var debugLogger: ((DebugLogCategory, String) -> Void)?

    private let microStore: MicroStore
    private let trie: PpmTrie
    private let confidenceThreshold: Double
    private let predictionsSubject = CurrentValueSubject<[Prediction], Never>([])

    var predictionsPublisher: AnyPublisher<[Prediction], Never> {
        predictionsSubject.eraseToAnyPublisher()
    }

    var predictionStateDump: String {
        "trie_nodes: \(trie.nodeCount()), threshold: \(confidenceThreshold)"
    }

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

    func consumePrediction() {
        currentPrediction = nil
        topPredictions = []
        predictionsSubject.send([])
        lastEmittedPrediction = nil
    }

    func savePredictionState() throws {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let trieURL = appSupport.appendingPathComponent("Casper/prediction/ppm_trie.json")
        try trie.save(to: trieURL)
    }

    func predictActionChains(maxSteps: Int = 4, beamWidth: Int = 3) -> [ActionChainPrediction] {
        guard maxSteps > 0, beamWidth > 0, !slidingWindow.isEmpty else { return [] }

        struct Candidate {
            let context: [String]
            let confidence: Double
            let steps: [PredictedActionStep]
        }

        var candidates = [Candidate(context: slidingWindow, confidence: 1.0, steps: [])]
        var completed: [ActionChainPrediction] = []

        for _ in 0..<maxSteps {
            var expanded: [Candidate] = []

            for candidate in candidates {
                for rawPrediction in trie.predict(context: candidate.context).prefix(beamWidth) {
                    let combinedConfidence = candidate.confidence * rawPrediction.confidence
                    guard combinedConfidence >= confidenceThreshold else { continue }

                    let nextContext = Self.advanceContext(candidate.context, with: rawPrediction.token)
                    guard let prediction = buildPrediction(
                        from: rawPrediction.token,
                        confidence: combinedConfidence,
                        context: candidate.context
                    ), let step = actionStep(for: prediction) else {
                        expanded.append(Candidate(
                            context: nextContext,
                            confidence: combinedConfidence,
                            steps: candidate.steps
                        ))
                        continue
                    }

                    let nextSteps = candidate.steps + [step]
                    expanded.append(Candidate(
                        context: nextContext,
                        confidence: combinedConfidence,
                        steps: nextSteps
                    ))
                    completed.append(ActionChainPrediction(confidence: combinedConfidence, steps: nextSteps))
                }
            }

            candidates = expanded
                .sorted { $0.confidence > $1.confidence }
                .prefix(beamWidth)
                .map { $0 }

            if candidates.isEmpty { break }
        }

        return completed
            .filter { !$0.steps.isEmpty }
            .sorted {
                if $0.steps.count != $1.steps.count {
                    return $0.steps.count > $1.steps.count
                }
                return $0.confidence > $1.confidence
            }
            .prefix(beamWidth)
            .map { $0 }
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
            if let p = buildPrediction(from: pred.token, confidence: pred.confidence, context: slidingWindow) {
                built.append(p)
            }
        }
        topPredictions = built
        predictionsSubject.send(built)

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

    private static func advanceContext(_ context: [String], with token: String) -> [String] {
        let next = context + [token]
        guard next.count > PpmTrie.maxDepth else { return next }
        return Array(next.suffix(PpmTrie.maxDepth))
    }

    private func buildPrediction(from token: String, confidence: Double, context: [String]) -> Prediction? {
        let micro = microValue(for: token, context: context)
        return buildPrediction(from: token, confidence: confidence, microValue: micro?.value, microCount: micro?.count ?? 0)
    }

    private func microValue(for token: String, context: [String]) -> (value: String, count: Int)? {
        guard token.hasPrefix("k:") || token.hasPrefix("m:") else { return nil }
        let contextHash = (context + [token]).joined(separator: " → ")
        let results = microStore.predict(for: contextHash)
        guard let top = results.first, top.count >= 3 else { return nil }
        return top
    }

    private func actionStep(for prediction: Prediction) -> PredictedActionStep? {
        if prediction.token.hasPrefix("a:") {
            let bundleID = String(prediction.token.dropFirst(2))
            let appName = bundleIDToAppName[bundleID] ?? bundleID
            return .activateApp(bundleID: bundleID, appName: appName)
        }

        if prediction.token.hasPrefix("c:") {
            let appName = String(prediction.token.dropFirst(2))
            guard !prediction.suggestedContent.isEmpty else { return nil }
            return .pasteText(text: prediction.suggestedContent, appName: appName)
        }

        if prediction.token.hasPrefix("k:") {
            let appName = predictionAppName(from: prediction.token)
            return .typeText(text: prediction.suggestedContent, appName: appName)
        }

        if prediction.token.hasPrefix("m:") {
            let appName = predictionAppName(from: prediction.token)
            return .clickElement(description: prediction.suggestedContent, appName: appName)
        }

        return nil
    }

    private func predictionAppName(from token: String) -> String {
        let rest = String(token.dropFirst(2))
        return rest.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? rest
    }

    private func buildPrediction(from token: String, confidence: Double, microValue: String? = nil, microCount: Int = 0) -> Prediction? {
        if token.hasPrefix("k:") {
            guard let microValue else { return nil }
            let appName = predictionAppName(from: token)
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
            let appName = predictionAppName(from: token)
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
            let appName = String(token.dropFirst(2))
            let displayText = lastCopiedText.isEmpty ? "" : " \"\(lastCopiedText.prefix(60))\""
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
