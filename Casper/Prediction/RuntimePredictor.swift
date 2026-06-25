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

        let rolloutWidth = max(beamWidth, 8)

        for _ in 0..<maxSteps {
            var expanded: [Candidate] = []

            for candidate in candidates {
                for rawPrediction in trie.predict(context: candidate.context).prefix(rolloutWidth) {
                    let combinedConfidence = candidate.confidence * rawPrediction.confidence

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

                    guard predictionMeetsThreshold(prediction) || Self.isActivationAfterSpecificAction(step, existingSteps: candidate.steps) else {
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
                .sorted {
                    let lhsScore = Self.stepUtilityScore($0.steps, confidence: $0.confidence)
                    let rhsScore = Self.stepUtilityScore($1.steps, confidence: $1.confidence)
                    if lhsScore != rhsScore {
                        return lhsScore > rhsScore
                    }
                    return $0.confidence > $1.confidence
                }
                .prefix(beamWidth)
                .map { $0 }

            if candidates.isEmpty { break }
        }

        return completed
            .filter { Self.isUsefulChain($0.steps) }
            .sorted {
                if $0.steps.count != $1.steps.count {
                    return $0.steps.count > $1.steps.count
                }
                let lhsScore = Self.chainUtilityScore($0)
                let rhsScore = Self.chainUtilityScore($1)
                if lhsScore != rhsScore {
                    return lhsScore > rhsScore
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
        var discardedTokens: [String] = []
        for pred in rawPredictions.prefix(8) {
            if let p = buildPrediction(from: pred.token, confidence: pred.confidence, context: slidingWindow) {
                built.append(p)
            } else {
                discardedTokens.append(pred.token)
            }
        }
        built = rankedPredictions(built).prefix(5).map { $0 }
        topPredictions = built
        predictionsSubject.send(built)

        guard let top = built.first, predictionMeetsThreshold(top) else {
            if currentPrediction != nil {
                debugLogger?(.prediction, "Prediction cleared (below threshold)")
                currentPrediction = nil
                lastEmittedPrediction = nil
            } else {
                let topHint = rawPredictions.first.map { " top=\($0.token):\(String(format: "%.2f", $0.confidence))" } ?? ""
                let discardedHint = discardedTokens.isEmpty ? "" : " discarded=[\(discardedTokens.joined(separator: ", "))]"
                debugLogger?(.prediction, "No prediction\(topHint)\(discardedHint) (threshold=\(confidenceThreshold))")
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
        return buildPrediction(from: token, confidence: adjustedConfidence(for: token, confidence: confidence), microValue: micro?.value, microCount: micro?.count ?? 0)
    }

    private func microValue(for token: String, context: [String]) -> (value: String, count: Double)? {
        guard token.hasPrefix("k:") || token.hasPrefix("m:") else { return nil }
        let results = microStore.predict(forContext: context, targetToken: token)
        guard let top = results.first, top.count >= microCountThreshold(for: token) else { return nil }
        return top
    }

    private func microCountThreshold(for token: String) -> Double {
        if token.hasPrefix("k:") {
            return token.contains(":terminal") || token.contains(":search") ? 1 : 3
        }
        return 3
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

    private static func hasSpecificAction(_ steps: [PredictedActionStep]) -> Bool {
        steps.contains { step in
            switch step {
            case .activateApp:
                return false
            case .pasteText, .typeText, .clickElement:
                return true
            }
        }
    }

    private static func isUsefulChain(_ steps: [PredictedActionStep]) -> Bool {
        steps.count >= 2 && hasSpecificAction(steps)
    }

    private static func isActivationAfterSpecificAction(_ step: PredictedActionStep, existingSteps: [PredictedActionStep]) -> Bool {
        guard case .activateApp = step else { return false }
        return hasSpecificAction(existingSteps)
    }

    private static func chainUtilityScore(_ chain: ActionChainPrediction) -> Double {
        let specificActionCount = chain.steps.filter { step in
            switch step {
            case .activateApp:
                return false
            case .pasteText, .typeText, .clickElement:
                return true
            }
        }.count
        let activationCount = chain.steps.count - specificActionCount
        return chain.confidence
            * (1.0 + Double(specificActionCount) * 0.45)
            * (1.0 + Double(chain.steps.count) * 0.12)
            * max(0.4, 1.0 - Double(activationCount) * 0.05)
    }

    private func predictionAppName(from token: String) -> String {
        let rest = String(token.dropFirst(2))
        return rest.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? rest
    }

    private func adjustedConfidence(for token: String, confidence: Double) -> Double {
        guard token.hasPrefix("a:") else { return confidence }
        return confidence * 0.35
    }

    private func predictionMeetsThreshold(_ prediction: Prediction) -> Bool {
        prediction.confidence >= threshold(for: prediction)
    }

    private func threshold(for prediction: Prediction) -> Double {
        if prediction.token.hasPrefix("k:") {
            if prediction.token.contains(":terminal") || prediction.token.contains(":search") {
                return min(confidenceThreshold, 0.18)
            }
            return min(confidenceThreshold, 0.25)
        }

        if prediction.token.hasPrefix("m:") {
            return min(confidenceThreshold, 0.35)
        }

        if prediction.token.hasPrefix("c:") {
            return min(confidenceThreshold, 0.30)
        }

        return confidenceThreshold
    }

    private func rankedPredictions(_ predictions: [Prediction]) -> [Prediction] {
        predictions.sorted {
            let lhsScore = utilityScore(for: $0)
            let rhsScore = utilityScore(for: $1)
            if lhsScore != rhsScore {
                return lhsScore > rhsScore
            }
            return $0.confidence > $1.confidence
        }
    }

    private func utilityScore(for prediction: Prediction) -> Double {
        if prediction.token.hasPrefix("k:") { return prediction.confidence * 1.35 }
        if prediction.token.hasPrefix("c:") { return prediction.suggestedContent.isEmpty ? 0 : prediction.confidence * 1.2 }
        if prediction.token.hasPrefix("m:") { return prediction.confidence * 1.1 }
        if prediction.token.hasPrefix("a:") { return prediction.confidence * 0.75 }
        return prediction.confidence
    }

    private static func stepUtilityScore(_ steps: [PredictedActionStep], confidence: Double) -> Double {
        guard !steps.isEmpty else { return confidence * 0.4 }

        let specificActionCount = steps.filter { step in
            switch step {
            case .activateApp:
                return false
            case .pasteText, .typeText, .clickElement:
                return true
            }
        }.count
        let activationCount = steps.count - specificActionCount

        return confidence
            * (1.0 + Double(specificActionCount) * 0.5)
            * max(0.35, 1.0 - Double(activationCount) * 0.15)
    }

    private func buildPrediction(from token: String, confidence: Double, microValue: String? = nil, microCount: Double = 0) -> Prediction? {
        if token.hasPrefix("k:") {
            guard let microValue else { return nil }
            let appName = predictionAppName(from: token)
            return Prediction(
                token: token,
                confidence: confidence,
                displayTitle: "Type \"\(microValue)\" in \(appName)?",
                displayDescription: "\(Self.formatCount(microCount)) times before",
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

    private static func formatCount(_ count: Double) -> String {
        if count.rounded() == count {
            return String(Int(count))
        }
        return String(format: "%.1f", count)
    }
}
