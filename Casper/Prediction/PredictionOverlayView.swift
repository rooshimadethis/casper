import SwiftUI

struct PredictionOverlayView: View {
    let predictions: [Prediction]
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
        .frame(width: 340)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
        )
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
