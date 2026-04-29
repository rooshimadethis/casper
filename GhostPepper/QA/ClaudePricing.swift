import Foundation

// Hardcoded Anthropic pricing (USD per 1M tokens). Review against
// https://docs.anthropic.com/en/docs/about-claude/pricing each release.
// Cache write is billed at 1.25x input rate; cache read at 0.10x input rate.
// The 1M-context Opus tier (input >200k) is intentionally not modeled here —
// cross-meeting Q&A context stays well below that threshold.
enum ClaudePricing {
    struct Rates {
        let inputPerMTok: Double
        let outputPerMTok: Double
    }

    static let cacheWriteMultiplier: Double = 1.25
    static let cacheReadMultiplier: Double = 0.10

    static func rates(for model: ClaudeAPIModel) -> Rates {
        switch model {
        case .opus:   return Rates(inputPerMTok: 15.00, outputPerMTok: 75.00)
        case .sonnet: return Rates(inputPerMTok:  3.00, outputPerMTok: 15.00)
        case .haiku:  return Rates(inputPerMTok:  1.00, outputPerMTok:  5.00)
        }
    }

    static func estimateCostUSD(
        model: ClaudeAPIModel,
        inputTokens: Int,
        outputTokens: Int,
        cacheReadTokens: Int,
        cacheWriteTokens: Int
    ) -> Double {
        let r = rates(for: model)
        let regularInput = max(0, inputTokens)
        let inputCost = Double(regularInput) * r.inputPerMTok / 1_000_000.0
        let cacheReadCost = Double(cacheReadTokens) * r.inputPerMTok * cacheReadMultiplier / 1_000_000.0
        let cacheWriteCost = Double(cacheWriteTokens) * r.inputPerMTok * cacheWriteMultiplier / 1_000_000.0
        let outputCost = Double(outputTokens) * r.outputPerMTok / 1_000_000.0
        return inputCost + cacheReadCost + cacheWriteCost + outputCost
    }

    /// Pre-flight cost estimate for an index build. Assumes output ≈ 30% of
    /// input (typical for dossier generation) and a single iteration's worth
    /// of context. The agent loop grows context across iterations, so callers
    /// should label this as a lower bound.
    static func estimateBuildCostUSD(model: ClaudeAPIModel, inputTokens: Int) -> Double {
        let r = rates(for: model)
        let inputCost = Double(inputTokens) * r.inputPerMTok / 1_000_000.0
        let outputTokens = Int(Double(inputTokens) * 0.3)
        let outputCost = Double(outputTokens) * r.outputPerMTok / 1_000_000.0
        return inputCost + outputCost
    }
}
