import SwiftUI
import AppKit

/// Renders a single dossier entry. `[[wikilink]]` cross-references and
/// source-meeting links are rendered as tappable buttons. Default click
/// navigates the *current tab* to the link target (browser-style); right-click
/// surfaces "Open in new tab".
struct IndexEntryView: View {
    let entry: IndexEntry
    let saveDir: URL
    var onOpenEntry: (_ kind: IndexKind, _ slug: String) -> Void = { _, _ in }
    var onOpenMeeting: (_ relativePath: String) -> Void = { _ in }
    var onOpenEntryInNewTab: (_ kind: IndexKind, _ slug: String) -> Void = { _, _ in }
    var onOpenMeetingInNewTab: (_ relativePath: String) -> Void = { _ in }
    var onRefresh: () -> Void = {}

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                if !entry.aliases.isEmpty {
                    aliasesRow
                }

                Divider()

                bodyRendered

                if !entry.sourceMeetings.isEmpty {
                    Divider()
                    sourcesSection
                }
            }
            .padding(.horizontal, 48)
            .padding(.vertical, 24)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(entry.canonicalName)
                    .font(.system(size: 24, weight: .semibold))
                Spacer()
                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12))
                }
                .buttonStyle(.bordered)
                .help("Re-run the agent for this entry")
            }
            HStack(spacing: 12) {
                Label(entry.kind.displayName, systemImage: entry.kind.iconSystemName)
                Text("Updated \(formatted(entry.lastUpdated))")
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
    }

    private var aliasesRow: some View {
        HStack(spacing: 6) {
            Text("Also known as")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            ForEach(entry.aliases, id: \.self) { alias in
                Text(alias)
                    .font(.system(size: 11))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
            }
        }
    }

    private var bodyRendered: some View {
        let segments = WikilinkParser.parse(entry.body)
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                switch seg {
                case .text(let text):
                    if let attributed = try? AttributedString(markdown: text, options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
                        Text(attributed)
                            .font(.system(size: 14))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text(text)
                            .font(.system(size: 14))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                case .wikilink(let name):
                    let slug = MarkdownArchivePaths.slugForIndexEntry(name)
                    Button(action: { onOpenEntry(entry.kind, slug) }) {
                        Text(name)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.orange)
                            .underline()
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Open in new tab") {
                            onOpenEntryInNewTab(entry.kind, slug)
                        }
                    }
                }
            }
        }
    }

    private var sourcesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Source meetings")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            ForEach(entry.sourceMeetings, id: \.self) { path in
                Button(action: { onOpenMeeting(path) }) {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.text")
                            .font(.system(size: 11))
                        Text(path)
                            .font(.system(size: 12))
                    }
                    .foregroundColor(.orange)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Open in new tab") {
                        onOpenMeetingInNewTab(path)
                    }
                }
            }
        }
    }

    private func formatted(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }
}

/// Splits a markdown body into runs of plain text and wikilinks (`[[Name]]`).
/// Used by IndexEntryView to render wikilinks as tappable cross-refs.
enum WikilinkSegment: Equatable {
    case text(String)
    case wikilink(String)
}

enum WikilinkParser {
    static func parse(_ body: String) -> [WikilinkSegment] {
        var segments: [WikilinkSegment] = []
        var remaining = body[...]
        while let openRange = remaining.range(of: "[[") {
            let before = remaining[..<openRange.lowerBound]
            if !before.isEmpty {
                segments.append(.text(String(before)))
            }
            let afterOpen = remaining[openRange.upperBound...]
            guard let closeRange = afterOpen.range(of: "]]") else {
                segments.append(.text(String(remaining[openRange.lowerBound...])))
                return segments
            }
            let linkText = afterOpen[..<closeRange.lowerBound]
            segments.append(.wikilink(String(linkText)))
            remaining = afterOpen[closeRange.upperBound...]
        }
        if !remaining.isEmpty {
            segments.append(.text(String(remaining)))
        }
        return segments
    }
}
