import Foundation

/// Orchestrates building and incrementally updating an index of dossier
/// markdown files. Wraps a `MeetingQAAgent` configured for the indexing task,
/// with read-only tool access to the meeting archive and write access scoped
/// to the index subdirectory.
///
/// All work for a given `IndexKind` is serialized through a single Task chain
/// so two close-together meeting stops can't race on the same dossier file.
@MainActor
final class IndexBuilder {
    private let provider: AnthropicProvider
    private let model: ClaudeAPIModel
    private let saveDir: URL

    private var perKindChain: [IndexKind: Task<Void, Never>] = [:]

    init(provider: AnthropicProvider, model: ClaudeAPIModel, saveDir: URL) {
        self.provider = provider
        self.model = model
        self.saveDir = saveDir
    }

    // MARK: - Cost estimation

    /// Pre-flight estimate. Returns a per-model cost range based on the
    /// number of *unprocessed* meetings (i.e. meetings not yet cited in any
    /// existing entry's source_meetings). On a resume, this estimate scales
    /// down because covered work is skipped.
    func estimateBuildCost(kind: IndexKind) async throws -> IndexBuildEstimate {
        let allMeetings = Self.allMeetingPaths(in: saveDir)
        let covered = Self.coveredMeetings(in: saveDir, kind: kind)
        let unprocessedCount = allMeetings.filter { !covered.contains($0) }.count
        let existingEntries = Self.countExistingEntries(in: saveDir, kind: kind)
        let range = ClaudePricing.estimateBuildCostRange(model: model, meetingCount: unprocessedCount)
        return IndexBuildEstimate(
            totalMeetingCount: allMeetings.count,
            alreadyProcessedCount: allMeetings.count - unprocessedCount,
            existingEntryCount: existingEntries,
            likelyLowUSD: range.low,
            likelyHighUSD: range.high,
            modelDisplayName: model.shortDisplayName
        )
    }

    /// The set of meeting paths that already appear in some existing entry's
    /// source_meetings list — these have effectively been processed and can
    /// be skipped on resume. Cheap disk read of every entry's frontmatter.
    nonisolated static func coveredMeetings(in saveDir: URL, kind: IndexKind) -> Set<String> {
        let root = MarkdownArchivePaths.indexRoot(in: saveDir, kind: kind)
        guard let files = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
            return []
        }
        var covered: Set<String> = []
        for url in files where url.pathExtension == "md" && !url.lastPathComponent.hasPrefix("_") {
            if let entry = try? IndexEntryFile.read(from: url) {
                for meeting in entry.sourceMeetings {
                    covered.insert(meeting)
                }
            }
        }
        return covered
    }

    nonisolated static func countExistingEntries(in saveDir: URL, kind: IndexKind) -> Int {
        let root = MarkdownArchivePaths.indexRoot(in: saveDir, kind: kind)
        guard let files = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
            return 0
        }
        return files.filter { $0.pathExtension == "md" && !$0.lastPathComponent.hasPrefix("_") }.count
    }

    // MARK: - Full build

    /// One-shot full build. Streams progress and writes a fresh manifest at the end.
    func buildFullIndex(kind: IndexKind) -> AsyncThrowingStream<IndexBuildEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [weak self] in
                guard let self else { continuation.finish(); return }
                await self.runFullBuild(kind: kind, continuation: continuation)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func runFullBuild(kind: IndexKind, continuation: AsyncThrowingStream<IndexBuildEvent, Error>.Continuation) async {
        let indexRoot = MarkdownArchivePaths.indexRoot(in: saveDir, kind: kind)
        do {
            try FileManager.default.createDirectory(at: indexRoot, withIntermediateDirectories: true)
        } catch {
            continuation.yield(.error("Couldn't create index directory: \(error.localizedDescription)"))
            continuation.finish()
            return
        }

        let allMeetings = Self.allMeetingPaths(in: saveDir)
        var coveredMeetings = Self.coveredMeetings(in: saveDir, kind: kind)
        let unprocessedMeetings = allMeetings.filter { !coveredMeetings.contains($0) }
        let totalCount = allMeetings.count

        if unprocessedMeetings.isEmpty {
            continuation.yield(.status("Index is up to date — nothing to process."))
            continuation.yield(.completed)
            continuation.finish()
            return
        }

        continuation.yield(.meetingsProcessed(processed: coveredMeetings.count, total: totalCount))

        let prompt = IndexSystemPrompt.buildPeopleIndexFullBuild(
            archiveRootPath: saveDir.path,
            indexRootPath: indexRoot.path
        )
        let agent = makeAgent(systemPrompt: prompt, indexRoot: indexRoot)
        let initialMessage = Self.fullBuildInitialMessage(meetings: unprocessedMeetings)

        let manifestURL = MarkdownArchivePaths.manifestURL(in: saveDir, kind: kind)
        var entriesTouched: Set<String> = []
        var buildFailed = false
        do {
            for try await event in agent.ask(initialMessage) {
                switch event {
                case .status(let s):
                    continuation.yield(.status(s))
                case .text:
                    // Index agent's narration is internal; surface only in trace, not as visible text.
                    break
                case .toolCall(_, let name, let summary, _):
                    continuation.yield(.status("\(name): \(summary)"))
                case .toolResult(_, let summary, _, let isError):
                    if !isError, summary.hasPrefix("Wrote") {
                        if let slug = Self.extractWrittenSlug(from: summary) {
                            entriesTouched.insert(slug)
                            continuation.yield(.entryWritten(slug: slug, canonicalName: ""))
                            // Re-read the just-written entry to pick up any new
                            // source_meetings, so the progress count advances
                            // and a future Stop+Resume knows what's covered.
                            let entryURL = MarkdownArchivePaths.entryURL(in: saveDir, kind: kind, slug: slug)
                            if let entry = try? IndexEntryFile.read(from: entryURL) {
                                for meeting in entry.sourceMeetings {
                                    coveredMeetings.insert(meeting)
                                }
                                continuation.yield(.meetingsProcessed(processed: coveredMeetings.count, total: totalCount))
                            }
                            persistPartialManifest(
                                manifestURL: manifestURL,
                                kind: kind,
                                entriesTouched: entriesTouched
                            )
                        }
                    }
                case .usage(let u):
                    continuation.yield(.usage(u))
                case .error(let msg):
                    continuation.yield(.error(msg))
                }
            }
        } catch {
            buildFailed = true
            continuation.yield(.error(error.localizedDescription))
        }

        if buildFailed {
            continuation.finish()
            return
        }

        // Build completed cleanly: mark every meeting as processed.
        var manifest = IndexManifest.loadOrEmpty(at: manifestURL, kind: kind)
        let now = Date()
        manifest.builtAt = now
        for meeting in allMeetings {
            manifest.markProcessed(
                meetingPath: meeting,
                entriesTouched: Array(entriesTouched).sorted(),
                at: now
            )
        }
        do {
            try manifest.save(to: manifestURL)
        } catch {
            continuation.yield(.error("Index built but failed to save manifest: \(error.localizedDescription)"))
            continuation.finish()
            return
        }
        continuation.yield(.completed)
        continuation.finish()
        NotificationCenter.default.post(name: .indexUpdated, object: kind)
    }

    /// Saves a partial manifest mid-build. Only entries are recorded; meetings
    /// stay un-marked until the build finishes cleanly. This means a Stop at
    /// any point preserves the entries on disk, and a subsequent run won't
    /// mistakenly skip meetings the agent hadn't actually finished with.
    private func persistPartialManifest(
        manifestURL: URL,
        kind: IndexKind,
        entriesTouched: Set<String>
    ) {
        var manifest = IndexManifest.loadOrEmpty(at: manifestURL, kind: kind)
        manifest.builtAt = Date()
        // entriesTouched is implicit in the .md files on disk; we don't need
        // to encode it separately. The point of this write is just to keep
        // the manifest file present so downstream code can find an alias
        // snapshot when resuming.
        _ = entriesTouched
        try? manifest.save(to: manifestURL)
    }

    // MARK: - Incremental update

    /// Folds a single meeting into the index. Skips silently if the meeting
    /// has already been processed (per the manifest). Serialized per kind.
    func updateForMeeting(_ meetingURL: URL, kind: IndexKind) {
        let chainKey = kind
        let previous = perKindChain[chainKey]
        let task = Task { [weak self] in
            await previous?.value  // wait for any in-flight update for this kind
            guard let self else { return }
            await self.runIncremental(meetingURL: meetingURL, kind: kind)
        }
        perKindChain[chainKey] = task
    }

    private func runIncremental(meetingURL: URL, kind: IndexKind) async {
        // Skip if there's no index yet — the user hasn't opted in.
        let indexRoot = MarkdownArchivePaths.indexRoot(in: saveDir, kind: kind)
        guard FileManager.default.fileExists(atPath: indexRoot.path) else { return }

        let meetingPath = Self.relativePath(of: meetingURL, in: saveDir) ?? meetingURL.lastPathComponent
        let manifestURL = MarkdownArchivePaths.manifestURL(in: saveDir, kind: kind)
        var manifest = IndexManifest.loadOrEmpty(at: manifestURL, kind: kind)
        guard !manifest.isProcessed(meetingPath: meetingPath) else { return }

        let aliasSnapshot = IndexManifest.aliasSnapshot(in: saveDir, kind: kind)
        let prompt = IndexSystemPrompt.buildPeopleIndexIncremental(
            archiveRootPath: saveDir.path,
            indexRootPath: indexRoot.path,
            meetingPath: meetingPath,
            aliasSnapshot: aliasSnapshot
        )
        let agent = makeAgent(systemPrompt: prompt, indexRoot: indexRoot)
        let initialMessage = "Update the People index for the new meeting at `\(meetingPath)`."

        var entriesTouched: Set<String> = []
        do {
            for try await event in agent.ask(initialMessage) {
                switch event {
                case .toolResult(_, let summary, _, let isError):
                    if !isError, summary.hasPrefix("Wrote") {
                        if let slug = Self.extractWrittenSlug(from: summary) {
                            entriesTouched.insert(slug)
                        }
                    }
                default:
                    break
                }
            }
        } catch {
            return  // silent on failure for incremental; the manifest stays unchanged
        }

        manifest.markProcessed(meetingPath: meetingPath, entriesTouched: Array(entriesTouched).sorted())
        try? manifest.save(to: manifestURL)
        NotificationCenter.default.post(name: .indexUpdated, object: kind)
    }

    // MARK: - Helpers

    private func makeAgent(systemPrompt: String, indexRoot: URL) -> MeetingQAAgent {
        let readTools = MeetingQATools(root: saveDir)
        let writeTools = MeetingQATools(root: indexRoot)
        let handlers: [String: AgentToolHandler] = [
            "grep": { input in
                let pattern = (input["pattern"] as? String) ?? ""
                let path = input["path"] as? String
                let caseInsensitive = (input["case_insensitive"] as? Bool) ?? true
                let maxResults = (input["max_results"] as? Int) ?? 50
                return try await readTools.grep(pattern: pattern, path: path, caseInsensitive: caseInsensitive, maxResults: maxResults)
            },
            "read_file": { input in
                let path = (input["path"] as? String) ?? ""
                let offset = (input["offset"] as? Int) ?? 1
                let limit = (input["limit"] as? Int) ?? 200
                return try await readTools.readFile(path: path, offset: offset, limit: limit)
            },
            "list_dir": { input in
                let path = (input["path"] as? String) ?? ""
                return try await readTools.listDir(path: path)
            },
            "write_file": { input in
                let path = (input["path"] as? String) ?? ""
                let content = (input["content"] as? String) ?? ""
                return try await writeTools.writeFile(path: path, content: content)
            },
        ]
        return MeetingQAAgent(
            provider: provider,
            model: model,
            systemPrompt: systemPrompt,
            toolHandlers: handlers,
            toolDefinitions: Self.indexingToolDefinitions(),
            summarizeInput: Self.summarizeIndexInput,
            summarizeOutput: Self.summarizeIndexOutput,
            maxIterations: 200
        )
    }

    nonisolated static func indexingToolDefinitions() -> [LLMTool] {
        let qa = MeetingQAAgent.qaToolDefinitions()
        let writeFile = LLMTool(
            name: "write_file",
            description: "Write or overwrite a dossier .md file in the index directory. Path must be a flat <slug>.md filename (no subdirectories), not starting with '.' or '_'. Returns 'Wrote N bytes to <path>' on success.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "path": ["type": "string", "description": "Flat filename ending in .md, e.g. 'john-smith.md'."],
                    "content": ["type": "string", "description": "Full file contents including YAML frontmatter and body."],
                ] as [String: Any],
                "required": ["path", "content"],
            ]
        )
        return qa + [writeFile]
    }

    private static func summarizeIndexInput(name: String, input: [String: Any]) -> String {
        switch name {
        case "write_file":
            let path = (input["path"] as? String) ?? "?"
            let bytes = (input["content"] as? String)?.utf8.count ?? 0
            return "\(path) (\(bytes) bytes)"
        default:
            return MeetingQAAgent.summarizeQAInput(name: name, input: input)
        }
    }

    private static func summarizeIndexOutput(name: String, output: String, isError: Bool) -> String {
        if isError { return "ERROR: \(output.prefix(120))" }
        if name == "write_file" { return output }
        return "\(output.split(separator: "\n").count) lines"
    }

    /// Returns paths like "2026-04-28/standup.md" for every .md file in date-folders.
    /// Skips dot-prefixed folders (so `.indexes/` is excluded).
    nonisolated static func allMeetingPaths(in saveDir: URL) -> [String] {
        let fm = FileManager.default
        guard let dateFolders = try? fm.contentsOfDirectory(
            at: saveDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var paths: [String] = []
        for folder in dateFolders {
            let isDir = (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDir else { continue }
            guard let files = try? fm.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }
            for file in files where file.pathExtension == "md" {
                paths.append("\(folder.lastPathComponent)/\(file.lastPathComponent)")
            }
        }
        return paths.sorted()
    }

    private static func relativePath(of url: URL, in saveDir: URL) -> String? {
        let fullPath = url.standardizedFileURL.path
        let rootPath = saveDir.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard fullPath.hasPrefix(prefix) else { return nil }
        return String(fullPath.dropFirst(prefix.count))
    }

    /// Extracts the slug (filename without extension) from a write_file result
    /// like "Wrote 1234 bytes to john-smith.md".
    private static func extractWrittenSlug(from summary: String) -> String? {
        guard let toRange = summary.range(of: " to ") else { return nil }
        let path = summary[toRange.upperBound...].trimmingCharacters(in: .whitespaces)
        guard path.hasSuffix(".md") else { return nil }
        return String(path.dropLast(3))
    }

    private static func fullBuildInitialMessage(meetings: [String]) -> String {
        if meetings.isEmpty {
            return "Build the People index. The archive currently has no meetings; write nothing and stop."
        }
        let preview = meetings.prefix(20).joined(separator: "\n")
        let suffix = meetings.count > 20 ? "\n... and \(meetings.count - 20) more." : ""
        return """
        Build the People index for the meeting archive. There are \(meetings.count) meetings in total. \
        First few paths:

        \(preview)\(suffix)

        Use `list_dir` and `grep` to explore the rest yourself, then `write_file` one dossier per canonical person.
        """
    }
}

extension Notification.Name {
    static let indexUpdated = Notification.Name("indexUpdated")
}
