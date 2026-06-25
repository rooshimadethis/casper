import SwiftUI

struct PredictionOverlayView: View {
    let predictions: [Prediction]
    let chain: ActionChainPrediction?
    let onAction: (Prediction) -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Top Predictions")
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

            if let chain, !chain.steps.isEmpty {
                ChainPreviewView(chain: chain)
                Divider()
            }

            ForEach(Array(predictions.enumerated()), id: \.offset) { index, prediction in
                PredictionRowView(
                    prediction: prediction,
                    rank: index + 1,
                    onAction: { onAction(prediction) }
                )
                if index < predictions.count - 1 {
                    Divider().padding(.leading, 14)
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

private struct PredictionRowView: View {
    let prediction: Prediction
    let rank: Int
    let onAction: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text("\(rank).")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
                .frame(width: 16, alignment: .trailing)

            VStack(alignment: .leading, spacing: 1) {
                Text(prediction.displayTitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.primary)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    ConfidenceBarView(confidence: prediction.confidence)
                        .frame(width: 60, height: 6)
                    Text("\(Int(prediction.confidence * 100))%")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }
            }

            Spacer()

            if rank == 1 {
                Button("Go", action: onAction)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
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

private struct ConfidenceBarView: View {
    let confidence: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.quaternary)
                Capsule()
                    .fill(confidenceColor)
                    .frame(width: geo.size.width * confidence)
            }
        }
    }

    private var confidenceColor: Color {
        if confidence >= 0.7 { return .green }
        if confidence >= 0.5 { return .orange }
        return .secondary
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
