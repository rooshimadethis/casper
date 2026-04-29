import SwiftUI
import AppKit

/// Renders a single dossier entry. The body is parsed as markdown blocks
/// (headers, paragraphs, bullet lists) and rendered with appropriate styles.
/// `[[Wikilinks]]` are rewritten as `wikilink://<slug>` links so SwiftUI's
/// AttributedString link rendering keeps them tappable inside flowing text;
/// taps are intercepted via `.environment(\.openURL, ...)`.
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
        .environment(\.openURL, OpenURLAction { url in
            if url.scheme == "wikilink" {
                let slug = url.host ?? url.lastPathComponent
                onOpenEntry(entry.kind, slug)
                return .handled
            }
            return .systemAction
        })
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
        let blocks = MarkdownBlockParser.parse(entry.body)
        return VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                renderBlock(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func renderBlock(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            inlineText(text)
                .font(headingFont(for: level))
                .padding(.top, level <= 2 ? 8 : 2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        case .paragraph(let text):
            inlineText(text)
                .font(.system(size: 14))
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        case .bulletList(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                        inlineText(item)
                            .font(.system(size: 14))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
            }
        case .codeBlock(let text):
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.08))
                .cornerRadius(4)
                .textSelection(.enabled)
        }
    }

    /// Renders inline markdown with `[[Wikilink]]` rewritten as
    /// `[Wikilink](wikilink://slug)` so SwiftUI's AttributedString link parser
    /// keeps the link tappable inside flowing text. Taps are routed via the
    /// openURL environment override at the view root.
    private func inlineText(_ text: String) -> Text {
        let transformed = Self.transformWikilinks(text)
        if let attributed = try? AttributedString(
            markdown: transformed,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return Text(attributed)
        }
        return Text(text)
    }

    private func headingFont(for level: Int) -> Font {
        switch level {
        case 1: return .system(size: 20, weight: .bold)
        case 2: return .system(size: 16, weight: .semibold)
        default: return .system(size: 14, weight: .semibold)
        }
    }

    private static func transformWikilinks(_ text: String) -> String {
        let pattern = #"\[\[([^\]]+)\]\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, range: range)
        guard !matches.isEmpty else { return text }
        var result = text
        for match in matches.reversed() {
            guard let nameRange = Range(match.range(at: 1), in: result),
                  let fullRange = Range(match.range, in: result) else { continue }
            let name = String(result[nameRange])
            let slug = MarkdownArchivePaths.slugForIndexEntry(name)
            result.replaceSubrange(fullRange, with: "[\(name)](wikilink://\(slug))")
        }
        return result
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

// MARK: - Markdown block parser

enum MarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bulletList([String])
    case codeBlock(String)
}

enum MarkdownBlockParser {
    static func parse(_ body: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paraLines: [String] = []
        var listItems: [String] = []
        var codeLines: [String] = []
        var inFence = false

        func flushPara() {
            if !paraLines.isEmpty {
                blocks.append(.paragraph(paraLines.joined(separator: " ")))
                paraLines = []
            }
        }
        func flushList() {
            if !listItems.isEmpty {
                blocks.append(.bulletList(listItems))
                listItems = []
            }
        }
        func flushCode() {
            if !codeLines.isEmpty {
                blocks.append(.codeBlock(codeLines.joined(separator: "\n")))
                codeLines = []
            }
        }

        for raw in body.components(separatedBy: "\n") {
            let trimmedFence = raw.trimmingCharacters(in: .whitespaces)
            if trimmedFence.hasPrefix("```") {
                if inFence {
                    flushCode()
                    inFence = false
                } else {
                    flushPara(); flushList()
                    inFence = true
                }
                continue
            }
            if inFence {
                codeLines.append(raw)
                continue
            }

            let trimmed = raw.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                flushPara(); flushList()
                continue
            }

            if let level = headingLevel(trimmed) {
                flushPara(); flushList()
                let stripped = String(trimmed.drop { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                blocks.append(.heading(level: level, text: stripped))
                continue
            }

            if let item = bulletItem(trimmed) {
                flushPara()
                listItems.append(item)
                continue
            }

            flushList()
            paraLines.append(trimmed)
        }

        flushPara(); flushList(); flushCode()
        return blocks
    }

    private static func headingLevel(_ line: String) -> Int? {
        var hashes = 0
        for ch in line {
            if ch == "#" { hashes += 1 } else { break }
        }
        guard hashes >= 1 && hashes <= 6 else { return nil }
        let after = line.index(line.startIndex, offsetBy: hashes)
        guard after < line.endIndex, line[after] == " " else { return nil }
        return hashes
    }

    private static func bulletItem(_ line: String) -> String? {
        if line.hasPrefix("- ") { return String(line.dropFirst(2)) }
        if line.hasPrefix("* ") { return String(line.dropFirst(2)) }
        if line.hasPrefix("• ") { return String(line.dropFirst(2)) }
        return nil
    }
}

// MARK: - Legacy wikilink-segment parser (kept so existing references still resolve)

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
