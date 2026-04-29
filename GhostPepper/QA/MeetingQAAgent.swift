import Foundation

typealias AgentToolHandler = ([String: Any]) async throws -> String

final class MeetingQAAgent {
    private let provider: LLMProvider
    private let model: ClaudeAPIModel
    private let systemPrompt: String
    private let toolHandlers: [String: AgentToolHandler]
    private let toolDefinitions: [LLMTool]
    private let summarizeInput: (String, [String: Any]) -> String
    private let summarizeOutput: (String, String, Bool) -> String
    private let maxIterations: Int

    /// Backward-compatible Q&A initializer. Wires up the standard
    /// MeetingQASystemPrompt and the read-only grep / read_file / list_dir tools
    /// scoped to the meeting archive.
    convenience init(
        provider: LLMProvider,
        model: ClaudeAPIModel,
        archiveRoot: URL,
        maxIterations: Int = 15
    ) {
        let tools = MeetingQATools(root: archiveRoot)
        let handlers: [String: AgentToolHandler] = [
            "grep": { input in
                let pattern = (input["pattern"] as? String) ?? ""
                let path = input["path"] as? String
                let caseInsensitive = (input["case_insensitive"] as? Bool) ?? true
                let maxResults = (input["max_results"] as? Int) ?? 50
                return try await tools.grep(pattern: pattern, path: path, caseInsensitive: caseInsensitive, maxResults: maxResults)
            },
            "read_file": { input in
                let path = (input["path"] as? String) ?? ""
                let offset = (input["offset"] as? Int) ?? 1
                let limit = (input["limit"] as? Int) ?? 200
                return try await tools.readFile(path: path, offset: offset, limit: limit)
            },
            "list_dir": { input in
                let path = (input["path"] as? String) ?? ""
                return try await tools.listDir(path: path)
            },
        ]
        self.init(
            provider: provider,
            model: model,
            systemPrompt: MeetingQASystemPrompt.build(archiveRootPath: archiveRoot.path),
            toolHandlers: handlers,
            toolDefinitions: Self.qaToolDefinitions(),
            summarizeInput: Self.summarizeQAInput,
            summarizeOutput: Self.summarizeQAOutput,
            maxIterations: maxIterations
        )
    }

    /// Generic initializer. Used for Q&A (via the convenience init above) and
    /// for the indexing flow, which passes its own prompt + tools (incl.
    /// write_file) so the same loop drives a different task.
    init(
        provider: LLMProvider,
        model: ClaudeAPIModel,
        systemPrompt: String,
        toolHandlers: [String: AgentToolHandler],
        toolDefinitions: [LLMTool],
        summarizeInput: @escaping (String, [String: Any]) -> String,
        summarizeOutput: @escaping (String, String, Bool) -> String,
        maxIterations: Int = 15
    ) {
        self.provider = provider
        self.model = model
        self.systemPrompt = systemPrompt
        self.toolHandlers = toolHandlers
        self.toolDefinitions = toolDefinitions
        self.summarizeInput = summarizeInput
        self.summarizeOutput = summarizeOutput
        self.maxIterations = maxIterations
    }

    func ask(_ question: String) -> AsyncThrowingStream<QAEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [weak self] in
                guard let self else { continuation.finish(); return }
                await self.runLoop(question: question, continuation: continuation)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func runLoop(question: String, continuation: AsyncThrowingStream<QAEvent, Error>.Continuation) async {
        var messages: [LLMMessage] = [LLMMessage(role: .user, content: [.text(question)])]
        var cumulativeUsage = ProviderUsage.zero

        for _ in 0..<maxIterations {
            if Task.isCancelled {
                continuation.yield(.status("Stopped"))
                continuation.finish()
                return
            }

            var assistantBlocks: [LLMContentBlock] = []
            var pendingToolCalls: [(id: String, name: String, input: [String: Any])] = []
            var stopReason: StopReason = .other("missing")
            var iterationUsage: ProviderUsage = .zero
            var assistantTextBuffer = ""

            do {
                for try await event in provider.complete(system: systemPrompt, messages: messages, tools: toolDefinitions) {
                    if Task.isCancelled {
                        continuation.yield(.status("Stopped"))
                        continuation.finish()
                        return
                    }
                    switch event {
                    case .textDelta(let delta):
                        assistantTextBuffer += delta
                        continuation.yield(.text(delta))
                    case .toolUse(let id, let name, let input):
                        pendingToolCalls.append((id, name, input))
                        assistantBlocks.append(.toolUse(id: id, name: name, input: input))
                    case .stop(let reason, let usage):
                        stopReason = reason
                        iterationUsage = usage
                    }
                }
            } catch {
                continuation.yield(.error(error.localizedDescription))
                continuation.finish()
                return
            }

            if !assistantTextBuffer.isEmpty {
                assistantBlocks.insert(.text(assistantTextBuffer), at: 0)
            }
            cumulativeUsage = ProviderUsage(
                inputTokens: cumulativeUsage.inputTokens + iterationUsage.inputTokens,
                outputTokens: cumulativeUsage.outputTokens + iterationUsage.outputTokens,
                cacheReadTokens: cumulativeUsage.cacheReadTokens + iterationUsage.cacheReadTokens,
                cacheWriteTokens: cumulativeUsage.cacheWriteTokens + iterationUsage.cacheWriteTokens
            )
            emitUsage(cumulativeUsage, continuation: continuation)

            if !pendingToolCalls.isEmpty {
                messages.append(LLMMessage(role: .assistant, content: assistantBlocks))

                var toolResultBlocks: [LLMContentBlock] = []
                for call in pendingToolCalls {
                    continuation.yield(.toolCall(id: call.id, name: call.name, inputSummary: summarizeInput(call.name, call.input), fullInput: call.input))
                    let (output, isError) = await runTool(name: call.name, input: call.input)
                    continuation.yield(.toolResult(id: call.id, summary: summarizeOutput(call.name, output, isError), fullOutput: output, isError: isError))
                    toolResultBlocks.append(.toolResult(toolUseId: call.id, content: output, isError: isError))
                }
                messages.append(LLMMessage(role: .user, content: toolResultBlocks))
                continue
            }

            switch stopReason {
            case .endTurn:
                continuation.finish()
                return
            case .maxTokens:
                continuation.yield(.error("Model hit max_tokens before finishing."))
                continuation.finish()
                return
            case .toolUse:
                continuation.finish()
                return
            case .other(let raw):
                continuation.yield(.error("Unexpected stop reason: \(raw)"))
                continuation.finish()
                return
            }
        }

        continuation.yield(.status("Hit iteration cap of \(maxIterations)"))
        continuation.finish()
    }

    private func runTool(name: String, input: [String: Any]) async -> (output: String, isError: Bool) {
        guard let handler = toolHandlers[name] else {
            return ("Unknown tool: \(name)", true)
        }
        do {
            let out = try await handler(input)
            return (out, false)
        } catch {
            return (error.localizedDescription, true)
        }
    }

    private func emitUsage(_ usage: ProviderUsage, continuation: AsyncThrowingStream<QAEvent, Error>.Continuation) {
        let cost = ClaudePricing.estimateCostUSD(
            model: model,
            inputTokens: usage.inputTokens,
            outputTokens: usage.outputTokens,
            cacheReadTokens: usage.cacheReadTokens,
            cacheWriteTokens: usage.cacheWriteTokens
        )
        continuation.yield(.usage(QAUsage(
            modelDisplayName: model.shortDisplayName,
            inputTokens: usage.inputTokens,
            outputTokens: usage.outputTokens,
            cacheReadTokens: usage.cacheReadTokens,
            cacheWriteTokens: usage.cacheWriteTokens,
            estimatedCostUSD: cost,
            isLocal: false
        )))
    }

    // MARK: - Q&A defaults

    static func summarizeQAInput(name: String, input: [String: Any]) -> String {
        switch name {
        case "grep":
            let pattern = (input["pattern"] as? String) ?? ""
            let path = (input["path"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return path.map { "pattern=\"\(pattern)\", path=\"\($0)\"" } ?? "pattern=\"\(pattern)\""
        case "read_file":
            let path = (input["path"] as? String) ?? "?"
            let offset = (input["offset"] as? Int) ?? 1
            let limit = (input["limit"] as? Int) ?? 200
            return "\(path) offset=\(offset) limit=\(limit)"
        case "list_dir":
            let path = (input["path"] as? String) ?? ""
            return path.isEmpty ? "(root)" : path
        default:
            return ""
        }
    }

    static func summarizeQAOutput(name: String, output: String, isError: Bool) -> String {
        if isError {
            return "ERROR: \(output.prefix(120))"
        }
        let lineCount = output.split(separator: "\n").count
        return "\(lineCount) lines"
    }

    static func qaToolDefinitions() -> [LLMTool] {
        let grep = LLMTool(
            name: "grep",
            description: "Search the meeting archive for a regex pattern. Returns matching lines with file paths and line numbers. Prefer this over read_file when looking for names, dates, or specific phrases — it's much cheaper than reading whole files.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "pattern": ["type": "string", "description": "Regex pattern. Use plain strings for names. Use \\b for word boundaries."],
                    "path": ["type": "string", "description": "Optional subdirectory or file relative to the archive root."],
                    "case_insensitive": ["type": "boolean", "default": true],
                    "max_results": ["type": "integer", "default": 50, "maximum": 200],
                ] as [String: Any],
                "required": ["pattern"],
            ]
        )
        let readFile = LLMTool(
            name: "read_file",
            description: "Read a slice of a meeting transcript file. Returns the content with line numbers prepended for easy citation.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "path": ["type": "string", "description": "Path relative to archive root."],
                    "offset": ["type": "integer", "default": 1, "description": "1-indexed starting line."],
                    "limit": ["type": "integer", "default": 200, "maximum": 1000],
                ] as [String: Any],
                "required": ["path"],
            ]
        )
        let listDir = LLMTool(
            name: "list_dir",
            description: "List entries in a directory inside the meeting archive. Use to discover meetings by date — directories are named YYYY-MM-DD.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "path": ["type": "string", "description": "Path relative to archive root. Use '.' or empty string for the root."],
                ] as [String: Any],
                "required": ["path"],
            ]
        )
        return [grep, readFile, listDir]
    }
}
