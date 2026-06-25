import Foundation

struct Prediction: Sendable, Equatable {
    let token: String
    let confidence: Double
    let displayTitle: String
    let displayDescription: String
    let suggestedContent: String
}
