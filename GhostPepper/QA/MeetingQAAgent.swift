import Foundation

final class MeetingQAAgent {
    private let provider: LLMProvider
    private let model: ClaudeAPIModel
    private let archiveRoot: URL
    private let maxIterations: Int
    private let tools: MeetingQATools
    private let toolDefinitions: [LLMTool]

    init(provider: LLMProvider, model: ClaudeAPIModel, archiveRoot: URL, maxIterations: Int = 15) {
        self.provider = provider
        self.model = model
        self.archiveRoot = archiveRoot
        self.maxIterations = maxIterations
        self.tools = MeetingQATools(root: archiveRoot)
        self.toolDefinitions = Self.buildToolDefinitions()
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
        let systemPrompt = MeetingQASystemPrompt.build(archiveRootPath: archiveRoot.path)
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

            if !pendingToolCalls.isEmpty {
                messages.append(LLMMessage(role: .assistant, content: assistantBlocks))

                var toolResultBlocks: [LLMContentBlock] = []
                for call in pendingToolCalls {
                    continuation.yield(.toolCall(id: call.id, name: call.name, inputSummary: Self.summarizeInput(name: call.name, input: call.input), fullInput: call.input))
                    let (output, isError) = await runTool(name: call.name, input: call.input)
                    continuation.yield(.toolResult(id: call.id, summary: Self.summarizeOutput(name: call.name, output: output, isError: isError), fullOutput: output, isError: isError))
                    toolResultBlocks.append(.toolResult(toolUseId: call.id, content: output, isError: isError))
                }
                messages.append(LLMMessage(role: .user, content: toolResultBlocks))
                continue
            }

            switch stopReason {
            case .endTurn:
                emitFinalUsage(cumulativeUsage, continuation: continuation)
                continuation.finish()
                return
            case .maxTokens:
                continuation.yield(.error("Model hit max_tokens before finishing."))
                emitFinalUsage(cumulativeUsage, continuation: continuation)
                continuation.finish()
                return
            case .toolUse:
                emitFinalUsage(cumulativeUsage, continuation: continuation)
                continuation.finish()
                return
            case .other(let raw):
                continuation.yield(.error("Unexpected stop reason: \(raw)"))
                emitFinalUsage(cumulativeUsage, continuation: continuation)
                continuation.finish()
                return
            }
        }

        continuation.yield(.status("Hit iteration cap of \(maxIterations)"))
        emitFinalUsage(cumulativeUsage, continuation: continuation)
        continuation.finish()
    }

    private func runTool(name: String, input: [String: Any]) async -> (output: String, isError: Bool) {
        do {
            switch name {
            case "grep":
                let pattern = (input["pattern"] as? String) ?? ""
                let path = input["path"] as? String
                let caseInsensitive = (input["case_insensitive"] as? Bool) ?? true
                let maxResults = (input["max_results"] as? Int) ?? 50
                let out = try await tools.grep(pattern: pattern, path: path, caseInsensitive: caseInsensitive, maxResults: maxResults)
                return (out, false)
            case "read_file":
                let path = (input["path"] as? String) ?? ""
                let offset = (input["offset"] as? Int) ?? 1
                let limit = (input["limit"] as? Int) ?? 200
                let out = try await tools.readFile(path: path, offset: offset, limit: limit)
                return (out, false)
            case "list_dir":
                let path = (input["path"] as? String) ?? ""
                let out = try await tools.listDir(path: path)
                return (out, false)
            default:
                return ("Unknown tool: \(name)", true)
            }
        } catch {
            return (error.localizedDescription, true)
        }
    }

    private func emitFinalUsage(_ usage: ProviderUsage, continuation: AsyncThrowingStream<QAEvent, Error>.Continuation) {
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

    private static func summarizeInput(name: String, input: [String: Any]) -> String {
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

    private static func summarizeOutput(name: String, output: String, isError: Bool) -> String {
        if isError {
            return "ERROR: \(output.prefix(120))"
        }
        let lineCount = output.split(separator: "\n").count
        return "\(lineCount) lines"
    }

    private static func buildToolDefinitions() -> [LLMTool] {
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
