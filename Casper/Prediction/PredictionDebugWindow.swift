import SwiftUI
import AppKit

final class PredictionDebugWindowController: NSObject, NSWindowDelegate {
    private var window: NSPanel?
    private weak var trie: PpmTrie?
    private weak var microStore: MicroStore?

    func show(trie: PpmTrie, microStore: MicroStore) {
        if let window = window {
            self.trie = trie
            self.microStore = microStore
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        window.title = "Prediction Debug"
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.isFloatingPanel = true
        window.level = .floating
        window.hidesOnDeactivate = false
        window.contentViewController = NSHostingController(
            rootView: PredictionDebugView(trie: trie, microStore: microStore)
        )
        self.trie = trie
        self.microStore = microStore
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}

private enum PredictionDebugTab: String, CaseIterable {
    case trie = "Trie"
    case micro = "Micro Store"
    case test = "Test"
}

private struct PredictionDebugView: View {
    let trie: PpmTrie
    let microStore: MicroStore

    @State private var selectedTab = PredictionDebugTab.trie
    @State private var trieSnapshot: TrieNodeSnapshot?

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $selectedTab) {
                ForEach(PredictionDebugTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding()

            Divider()

            switch selectedTab {
            case .trie:
                if let snapshot = trieSnapshot {
                    TrieTabView(snapshot: snapshot)
                } else {
                    ProgressView("Loading trie...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            case .micro:
                MicroTabView(microStore: microStore)
            case .test:
                TestTabView(trie: trie)
            }
        }
        .frame(minWidth: 680, minHeight: 450)
        .onAppear {
            trieSnapshot = trie.snapshot()
        }
    }
}

// MARK: - Trie Tab

private struct TrieTabView: View {
    let snapshot: TrieNodeSnapshot

    @State private var searchText = ""

    private var totalLeafCount: Int {
        countLeaves(snapshot)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Filter tokens...", text: $searchText)
                        .textFieldStyle(.plain)
                }
                .padding(6)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                )
                .frame(maxWidth: 240)

                Spacer()

                Text("\(snapshot.children.count) top paths · \(totalLeafCount) nodes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    let children = searchText.isEmpty
                        ? snapshot.children.sorted { $0.count > $1.count }
                        : snapshot.children.filter { $0.hasDescendant(matching: searchText) }

                    if children.isEmpty {
                        Text("No matching tokens")
                            .foregroundStyle(.secondary)
                            .padding()
                    } else {
                        ForEach(children) { child in
                            TrieNodeRow(node: child, searchFilter: searchText, depth: 0)
                        }
                    }
                }
            }
        }
        .padding(.vertical)
    }

    private func countLeaves(_ node: TrieNodeSnapshot) -> Int {
        1 + node.children.reduce(0) { $0 + countLeaves($1) }
    }
}

private struct TrieNodeRow: View {
    let node: TrieNodeSnapshot
    let searchFilter: String
    let depth: Int

    @State private var isExpanded = false

    private var filteredChildren: [TrieNodeSnapshot] {
        if searchFilter.isEmpty {
            return node.children.sorted { $0.count > $1.count }
        }
        return node.children.filter { $0.hasDescendant(matching: searchFilter) }
    }

    var body: some View {
        let showExpansion = !node.children.isEmpty && (searchFilter.isEmpty || filteredChildren.contains(where: { $0.hasDescendant(matching: searchFilter) }))

        if showExpansion {
            DisclosureGroup(isExpanded: $isExpanded) {
                ForEach(filteredChildren) { child in
                    TrieNodeRow(node: child, searchFilter: searchFilter, depth: depth + 1)
                        .padding(.leading, 12)
                }
            } label: {
                nodeLabel
            }
        } else {
            nodeLabel
        }
    }

    private var nodeLabel: some View {
        HStack(spacing: 6) {
            if depth > 0 {
                tokenBadge
            }

            Text(node.token)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(1)

            Spacer()

            Text("\(node.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(minWidth: 32, alignment: .trailing)

            if depth == 0 && node.count > 0 {
                let pct = Double(node.count) / Double(max(node.count, 1))
                ConfidenceBar(value: pct)
                    .frame(width: 40)
            }
        }
        .padding(.vertical, 2)
        .padding(.trailing, 8)
        .id(node.id)
    }

    private var tokenBadge: some View {
        let prefix = node.token.prefix(2)
        let color: Color = {
            if prefix == "a:" { return .blue }
            if prefix == "k:" { return .green }
            if prefix == "m:" { return .orange }
            if prefix == "c:" { return .purple }
            if prefix == "h:" { return .gray }
            if prefix == "x:" { return .red }
            return .secondary
        }()
        return Text(String(prefix))
            .font(.system(size: 6, weight: .bold, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, 3)
            .padding(.vertical, 1)
            .background(color)
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}

private struct ConfidenceBar: View {
    let value: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.quaternary)
                Capsule()
                    .fill(.secondary)
                    .frame(width: geo.size.width * value)
            }
        }
        .frame(height: 4)
    }
}

// MARK: - Micro Store Tab

private struct MicroTabView: View {
    let microStore: MicroStore

    @State private var searchText = ""
    @State private var entries: [(context: String, values: [(value: String, count: Int)])] = []

    private var filteredEntries: [(context: String, values: [(value: String, count: Int)])] {
        if searchText.isEmpty { return entries }
        return entries.filter { entry in
            entry.context.localizedCaseInsensitiveContains(searchText)
                || entry.values.contains { $0.value.localizedCaseInsensitiveContains(searchText) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search contexts or values...", text: $searchText)
                        .textFieldStyle(.plain)
                }
                .padding(6)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                )
                .frame(maxWidth: 300)

                Spacer()

                Text("\(entries.count) contexts")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if filteredEntries.isEmpty {
                        Text( searchText.isEmpty ? "No micro store entries." : "No matching entries.")
                            .foregroundStyle(.secondary)
                            .padding()
                    } else {
                        ForEach(filteredEntries, id: \.context) { entry in
                            MicroContextSection(entry: entry)
                            Divider()
                                .padding(.leading)
                        }
                    }
                }
            }
        }
        .padding(.vertical)
        .onAppear {
            entries = microStore.allEntries
        }
    }
}

private struct MicroContextSection: View {
    let entry: (context: String, values: [(value: String, count: Int)])

    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            ForEach(entry.values.prefix(20), id: \.value) { v in
                HStack {
                    Text(v.value)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                    Spacer()
                    Text("\(v.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .padding(.leading, 24)
                .padding(.vertical, 1)
            }
            if entry.values.count > 20 {
                Text("... and \(entry.values.count - 20) more")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 24)
            }
        } label: {
            HStack {
                Text(entry.context)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                Spacer()
                Text("\(entry.values.count) value\(entry.values.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.trailing, 8)
        .padding(.vertical, 2)
    }
}

// MARK: - Test Tab

private struct TestTabView: View {
    let trie: PpmTrie

    @State private var contextInput = ""
    @State private var results: [(token: String, confidence: Double)] = []
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Test Prediction")
                .font(.headline)
                .padding(.horizontal)

            HStack(spacing: 8) {
                TextField("Enter context tokens separated by → or comma", text: $contextInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity)
                    .onSubmit { predict() }

                Button("Predict") {
                    predict()
                }
                .keyboardShortcut(.return)
            }
            .padding(.horizontal)

            Text("Example: a:com.ghostty → k:Ghostty")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.horizontal)

            Divider()

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.caption)
                    .padding(.horizontal)
            }

            if results.isEmpty {
                Text("Enter context tokens and tap Predict to see results.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(results.enumerated()), id: \.offset) { index, result in
                            HStack(spacing: 8) {
                                Text("\(index + 1).")
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 20, alignment: .trailing)

                                Text(result.token)
                                    .font(.system(.caption, design: .monospaced))
                                    .lineLimit(1)

                                Spacer()

                                ConfidenceBar(value: result.confidence)
                                    .frame(width: 60)

                                Text("\(Int(result.confidence * 100))%")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                                    .frame(width: 36, alignment: .trailing)
                            }
                            .padding(.horizontal)
                            .padding(.vertical, 2)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .padding(.vertical)
    }

    private func predict() {
        errorMessage = nil
        let trimmed = contextInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = "Please enter at least one context token."
            results = []
            return
        }

        let tokens = trimmed
            .components(separatedBy: "→")
            .flatMap { $0.components(separatedBy: ",") }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !tokens.isEmpty else {
            errorMessage = "Could not parse any tokens."
            results = []
            return
        }

        results = trie.predict(context: tokens)
        if results.isEmpty {
            errorMessage = "No predictions for this context."
        }
    }
}
