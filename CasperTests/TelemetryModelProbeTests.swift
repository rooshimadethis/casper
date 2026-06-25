import XCTest
@testable import Casper

/// Manual probe test that feeds a telemetry events JSONL file through the real
/// local LLM summarization pipeline and writes the output to a file.
///
/// Set TELEMETRY_EVENTS_FILE to specify the events file (defaults to the
/// representative sample file). Set TELEMETRY_PROBE_OUTPUT to control where
/// the LLM output is written (default: /tmp/telemetry_probe_output.txt).
///
/// Run with the convenience wrapper:
///   scripts/telemetry-model-probe.sh --input path/to/file.jsonl --model fast
///
/// Or directly with xcodebuild:
///   TELEMETRY_EVENTS_FILE=~/file.jsonl xcodebuild test -scheme Casper \
///     -destination 'platform=macOS' -skipMacroValidation \
///     CODE_SIGNING_ALLOWED=NO -only-testing:CasperTests/TelemetryModelProbeTests
final class TelemetryModelProbeTests: XCTestCase {
    override func setUp() async throws {
        throw XCTSkip("LLM tests disabled on no-llm branch")
    }

    private let defaultEventsFile = "~/Library/Application Support/Casper/telemetry/events/telemetry_events_2026-06-24_15-58-20.jsonl"

    // MARK: - Helpers

    private func resolveEventsFilePath() -> String {
        let envPath = ProcessInfo.processInfo.environment["TELEMETRY_EVENTS_FILE"]
        let path = envPath ?? defaultEventsFile
        return (path as NSString).expandingTildeInPath
    }

    private func outputFilePath(for modelKind: LocalCleanupModelKind) -> String {
        let envPath = ProcessInfo.processInfo.environment["TELEMETRY_PROBE_OUTPUT"]
        if let envPath = envPath {
            let ext = (envPath as NSString).pathExtension
            let base = (envPath as NSString).deletingPathExtension
            return "\(base)_\(modelKind.rawValue).\(ext)"
        }
        let projectRoot = ((#file as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
        return "\(projectRoot)/scripts/output/telemetryprobe/telemetry_probe_output_\(modelKind.rawValue).txt"
    }

    private func loadEvents(from path: String) throws -> [TelemetryEventRecord] {
        let url = URL(fileURLWithPath: path)
        let content = try String(contentsOf: url, encoding: .utf8)
        let lines = content.components(separatedBy: .newlines).filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try lines.map { line in
            try decoder.decode(TelemetryEventRecord.self, from: Data(line.utf8))
        }
    }

    /// Truncates events to fit the model's context window, keeping the most
    /// recent events. Uses a conservative estimate of ~2.5 chars per token and
    /// reserves ~40% of context for template overhead + generation space.
    private func eventsFittingInContext(
        _ records: [TelemetryEventRecord],
        maxTokenCount: Int32
    ) -> ArraySlice<TelemetryEventRecord> {
        let maxTokens = Int(maxTokenCount)
        let reservedTokens = max(500, Int(Double(maxTokens) * 0.4))
        let availableTokens = max(1, maxTokens - reservedTokens)
        let availableChars = availableTokens * 3
        let estimatedPromptChars = records.count * 100
        guard estimatedPromptChars > availableChars else { return records[...] }
        let maxEvents = max(1, availableChars / 100)
        print("Truncated \(records.count) events to last \(maxEvents) to fit \(maxTokens)-token context")
        return records.suffix(maxEvents)
    }

    private func formatEventsForSummarization(_ records: [TelemetryEventRecord]) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        var output = ""
        for (index, record) in records.enumerated() {
            let prefix = "[\(index + 1)] "
            let timestamp = formatter.string(from: record.recordedAt)
            let event = record.event
            switch event {
            case .appActivated(let name, _, let title):
                output += "\(prefix)\(timestamp) Activated App: \(name) | Window Title: \(title)\n"
            case .windowTitleChanged(let name, let title):
                output += "\(prefix)\(timestamp) Window changed in \(name) to title: \(title)\n"
            case .textCopied(let text):
                let truncated = text.count > 100 ? text.prefix(100) + "..." : text
                output += "\(prefix)\(timestamp) Copied text: \"\(truncated)\"\n"
            case .screenOcrCaptured(let text):
                let truncated = text.count > 100 ? text.prefix(100) + "..." : text
                output += "\(prefix)\(timestamp) OCR captured text: \"\(truncated)\"\n"
            case .commandExecuted(let command, let exitCode, let out):
                let truncatedOut = (out ?? "").count > 100 ? (out ?? "").prefix(100) + "..." : (out ?? "")
                output += "\(prefix)\(timestamp) Executed terminal command: `\(command)` | Exit Code: \(exitCode) | Output: \(truncatedOut)\n"
            case .customInput(let prompt):
                output += "\(prefix)\(timestamp) Custom prompt input: \"\(prompt)\"\n"
            case .mouseClicked(let app, let element, let clickCount, let selectedText):
                let clickType = clickCount == 2 ? "Double-clicked" : (clickCount >= 3 ? "Triple-clicked" : "Clicked")
                var msg = "\(prefix)\(timestamp) \(clickType) UI element \"\(element)\" in app \(app)"
                if let selectedText = selectedText, !selectedText.isEmpty {
                    let truncated = selectedText.count > 100 ? selectedText.prefix(100) + "..." : selectedText
                    msg += " (highlighted: \"\(truncated)\")"
                }
                output += msg + "\n"
            case .appStalled(let app, let duration):
                output += "\(prefix)\(timestamp) App stalled: \(app) was unresponsive for \(String(format: "%.1f", duration))s\n"
            case .userHesitated(let app, let duration):
                output += "\(prefix)\(timestamp) User paused/hesitated on app: \(app) for \(String(format: "%.1f", duration))s\n"
            case .typingSession(let app, let targetElement, let text, let duration):
                let truncated = text.count > 100 ? text.prefix(100) + "..." : text
                if let targetElement = targetElement {
                    output += "\(prefix)\(timestamp) Typed \"\(truncated)\" in \"\(targetElement)\" under \(app) over \(String(format: "%.1f", duration))s\n"
                } else {
                    output += "\(prefix)\(timestamp) Typed \"\(truncated)\" in \(app) over \(String(format: "%.1f", duration))s\n"
                }
            }
        }
        return output
    }

    /// Wraps the system instruction + formatted events in Qwen3's chat template
    /// so the model responds rather than producing empty output.
    private func buildSummarizationPrompt(from formatted: String) -> String {
        let systemPrompt = """
        You are Casper's passive Telemetry Summarizer. Infer user actions and outcomes based on the local telemetry events log below.

        Analyze the log and output a list of inferred activities. For each distinct activity or sequence, format it exactly as:
        - Context: What did the user see? (e.g., app name, window title, command outputs, or starting state)
        - Action: What did the user try to do? (e.g., commands executed, typing patterns, copy-paste loops)
        - Outcome: What was the outcome? (e.g., success, error, app stall duration, or user hesitation)

        Keep each point factual and extremely concise. Do not invent any activity. Keep the total output under 150 words.
        """
        var prompt = """
        <|im_start|>system
        \(systemPrompt)
        <|im_end|>
        <|im_start|>user
        Telemetry Log:
        \(formatted)
        <|im_end|>
        <|im_start|>assistant
        """
        prompt += "<think>\n</think>\n\n"
        return prompt
    }

    // MARK: - Core Probe Runner

    @MainActor
    private func maxTokenCount(for modelKind: LocalCleanupModelKind) -> Int32 {
        TextCleanupManager.cleanupModels.first(where: { $0.kind == modelKind })?.maxTokenCount ?? 2048
    }

    @MainActor
    private func runProbe(filePath: String, modelKind: LocalCleanupModelKind) async throws {
        let resolvedPath = (filePath as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: resolvedPath) else {
            throw XCTSkip("Events file not found at \(resolvedPath)")
        }

        let allRecords = try loadEvents(from: resolvedPath)
        let maxTokenCount = maxTokenCount(for: modelKind)
        let records = Array(eventsFittingInContext(allRecords, maxTokenCount: maxTokenCount))
        let truncatedCount = allRecords.count - records.count

        let manager = TextCleanupManager(selectedCleanupModelKind: modelKind)

        guard manager.isModelDownloaded(modelKind) else {
            throw XCTSkip("Model \(modelKind.rawValue) not downloaded — run scripts/download-model.sh or let the app download it first")
        }

        await manager.loadModel(kind: modelKind)

        let formatted = formatEventsForSummarization(records)
        let prompt = buildSummarizationPrompt(from: formatted)

        let start = Date()
        var output = ""
        let stream = try await manager.streamCompletion(prompt: prompt, modelKind: modelKind)
        for await token in stream {
            output += token
        }
        let elapsed = Date().timeIntervalSince(start)

        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let charCount = trimmed.count
        let throughput = elapsed > 0 ? Double(charCount) / elapsed : 0.0

        let result = """
        \(trimmed)

        === METRICS ===
        Model: \(modelKind.rawValue)
        Generation Time: \(String(format: "%.2f", elapsed)) seconds
        Character Count: \(charCount)
        Throughput: \(String(format: "%.2f", throughput)) chars/sec
        Events: \(records.count) fed\(truncatedCount > 0 ? " (\(truncatedCount) older truncated to fit context)" : "")
        """

        let outputPath = outputFilePath(for: modelKind)
        try result.write(toFile: outputPath, atomically: true, encoding: .utf8)
        print("Telemetry model probe output written to \(outputPath)")
    }

    // MARK: - Test Methods

    @MainActor
    func testProbeOnQwen35_0_8B() async throws {
        try await runProbe(filePath: resolveEventsFilePath(), modelKind: .qwen35_0_8b_q4_k_m)
    }

    @MainActor
    func testProbeOnQwen35_2B_Fast() async throws {
        try await runProbe(filePath: resolveEventsFilePath(), modelKind: .fast)
    }

    @MainActor
    func testProbeOnQwen35_4B_Full() async throws {
        try await runProbe(filePath: resolveEventsFilePath(), modelKind: .full)
    }

    @MainActor
    func testProbeOnDeepSeekR1_7B() async throws {
        try await runProbe(filePath: resolveEventsFilePath(), modelKind: .deepseek_r1_qwen_7b_q4_k_m)
    }

    @MainActor
    func testProbeOnAllAvailableModels() async throws {
        let filePath = resolveEventsFilePath()
        var testedCount = 0
        var skippedCount = 0

        for modelKind in LocalCleanupModelKind.allCases {
            do {
                try await runProbe(filePath: filePath, modelKind: modelKind)
                testedCount += 1
                print("✅ \(modelKind.rawValue) — completed")
            } catch let skip as XCTSkip {
                skippedCount += 1
                print("⏭️ \(modelKind.rawValue) — skipped (\(skip.message ?? "not downloaded"))")
                if modelKind == LocalCleanupModelKind.allCases.last && testedCount == 0 {
                    throw skip
                }
            }
        }

        print("Probe summary: \(testedCount) models tested, \(skippedCount) skipped")
    }
}
