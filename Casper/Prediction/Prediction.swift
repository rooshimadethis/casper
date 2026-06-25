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
