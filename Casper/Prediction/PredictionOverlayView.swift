import SwiftUI

struct PredictionOverlayView: View {
    let chains: [ActionChainPrediction]
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Top Chains")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.primary)
                Spacer()
                Button("X", action: onDismiss)
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 6)

            Divider()

            if !chains.isEmpty {
                ForEach(Array(chains.prefix(3).enumerated()), id: \.offset) { index, chain in
                    ChainPreviewView(chain: chain)
                    if index < min(chains.count, 3) - 1 {
                        Divider().padding(.leading, 14)
                    }
                }
            }
        }
        .frame(width: 380)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
        )
    }
}

private struct ChainPreviewView: View {
    let chain: ActionChainPrediction

    private var visibleSteps: ArraySlice<PredictedActionStep> {
        chain.steps.prefix(4)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Likely Chain")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(Int(chain.confidence * 100))%")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }

            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(visibleSteps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text(index == 0 ? "Next" : "Then")
                            .font(.system(size: 10, weight: index == 0 ? .semibold : .regular))
                            .foregroundColor(index == 0 ? .primary : .secondary)
                            .frame(width: 28, alignment: .leading)

                        Text(step.displayText)
                            .font(.system(size: 11, weight: index == 0 ? .semibold : .regular))
                            .foregroundColor(index == 0 ? .primary : .secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

private extension PredictedActionStep {
    var displayText: String {
        switch self {
        case .activateApp(_, let appName):
            return "Switch to \(appName)"
        case .pasteText(let text, let appName):
            return "Paste \"\(Self.preview(text))\" in \(appName)"
        case .typeText(let text, let appName):
            return "Type \"\(Self.preview(text))\" in \(appName)"
        case .clickElement(let description, let appName):
            return "Click \"\(Self.preview(description))\" in \(appName)"
        }
    }

    private static func preview(_ text: String) -> String {
        let cleaned = text.replacingOccurrences(of: "\n", with: " ")
        if cleaned.count <= 42 { return cleaned }
        return String(cleaned.prefix(39)) + "..."
    }
}

struct PredictionOverlayEmptyView: View {
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("No Prediction Available")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)

                Text("Use your Mac normally to generate predictions")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button("X", action: onDismiss)
                .buttonStyle(.borderless)
                .controlSize(.small)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
        )
        .frame(width: 320)
    }
}
