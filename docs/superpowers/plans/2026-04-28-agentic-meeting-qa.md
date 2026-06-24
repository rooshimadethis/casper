# Agentic Meeting Q&A Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Casper's keyword-scoring + 30 KB-cram cross-meeting Q&A core with a bounded agentic tool-use loop (grep/read_file/list_dir, cap 15 iterations) over the local meeting archive, behind a swappable `LLMProvider` protocol.

**Architecture:** A new `MeetingQAAgent` orchestrator owns the iteration loop and tool dispatch. It calls a thin `LLMProvider` protocol (one round trip per call) — only `AnthropicProvider` ships now, but the seam admits future Ollama/OpenAI providers. Three read-only tools (`grep`, `read_file`, `list_dir`) operate inside a `PathSandbox` rooted at the meetings folder. UI surfaces tool calls as a collapsed status line plus an expandable trace; existing prompt caching, streaming, and cost display from the predecessor spec are preserved.

**Tech Stack:** Swift 5.9+, SwiftUI, XCTest, AsyncSequence/AsyncThrowingStream, URLSession SSE, `Process()` for grep, Anthropic Messages API with tool use, prompt caching (`cache_control: ephemeral`).

**Spec:** `docs/superpowers/specs/2026-04-28-agentic-meeting-qa-design.md`

---

## Build & test commands

Run the full test suite:
```bash
xcodebuild test -project Casper.xcodeproj -scheme Casper -destination 'platform=macOS' -skipMacroValidation -quiet
```

Run a single test class (used heavily in this plan):
```bash
xcodebuild test -project Casper.xcodeproj -scheme Casper -destination 'platform=macOS' -skipMacroValidation -only-testing:CasperTests/<TestClassName> -quiet
```

Build only (no tests):
```bash
xcodebuild build -project Casper.xcodeproj -scheme Casper -destination 'platform=macOS' -skipMacroValidation -quiet
```

Launch the debug build for manual verification (per memory):
```bash
xcodebuild build -project Casper.xcodeproj -scheme Casper -derivedDataPath build/derived -skipMacroValidation
cp -R build/derived/Build/Products/Debug/Casper.app /Applications/
open /Applications/Casper.app
```

---

## File structure summary

**New files (all in `Casper/QA/`):**
- `LLMProvider.swift` — protocol, `LLMMessage`, `LLMTool`, `ProviderEvent`, `ProviderUsage`, `LLMProviderKind` enum.
- `AnthropicProvider.swift` — implements `LLMProvider` against Anthropic Messages API.
- `MeetingQAAgent.swift` — orchestrator. Owns iteration loop, message list, cancellation.
- `MeetingQATools.swift` — three tool implementations + JSON schemas.
- `PathSandbox.swift` — single safe-path resolver.
- `QAEvent.swift` — UI-facing event enum + `QAUsage`.
- `QATranscript.swift` — `ObservableObject` event log for the trace UI.
- `MeetingQASystemPrompt.swift` — system prompt builder with archive-root interpolation.

**Test files (all in `CasperTests/`):**
- `PathSandboxTests.swift`
- `MeetingQAToolsTests.swift`
- `MeetingQASystemPromptTests.swift`
- `AnthropicProviderSSETests.swift`
- `MeetingQAAgentTests.swift`

**Modified:**
- `Casper/AppState.swift` — replace `onAskQuestion` closure body with `MeetingQAAgent` instantiation; drop the keyword-scoring + dual-backend code path.
- `Casper/UI/MeetingTranscriptWindow.swift` — drop keyword scoring in `askAcrossMeetings()`; add status line + expandable trace + Stop button.
- `Casper/UI/SettingsWindow.swift` — replace backend picker with provider picker; drop the local-Q&A-model row.
- `Casper.xcodeproj/project.pbxproj` — register new files; remove old; rename.

**Deleted:**
- `Casper/QA/ClaudeAPIClient.swift` — subsumed by `AnthropicProvider.swift`.

**Renamed:**
- `Casper/QA/QABackendKind.swift` → `Casper/QA/LLMProviderKind.swift` (also drops `.local` case; moves `QAStreamEvent` and `QAUsage` out).

---

## Task ordering rationale

Bottom-up dependency order keeps the build green at every commit:
1. New foundation types (`PathSandbox`, schemas, system-prompt) have no internal deps.
2. `MeetingQATools` depends only on `PathSandbox`.
3. `LLMProvider` protocol + `QAEvent` are pure types.
4. `AnthropicProvider` and `MeetingQAAgent` depend on the above; tested with mocks/canned SSE.
5. Integration into `AppState` happens *after* the new code is fully tested in isolation, so the existing `ClaudeAPIClient` flow still works during early tasks.
6. UI changes follow once `AppState` exposes the new agent.
7. `Settings` UI follows.
8. Cleanup (delete `ClaudeAPIClient.swift`, rename `QABackendKind.swift`, drop `.local`) happens last — once nothing references the old types.
9. Manual end-to-end verification last.

---

## Task 1: Setup — register all new file stubs in pbxproj

**Files:**
- Create: `Casper/QA/LLMProvider.swift` (stub)
- Create: `Casper/QA/AnthropicProvider.swift` (stub)
- Create: `Casper/QA/MeetingQAAgent.swift` (stub)
- Create: `Casper/QA/MeetingQATools.swift` (stub)
- Create: `Casper/QA/PathSandbox.swift` (stub)
- Create: `Casper/QA/QAEvent.swift` (stub)
- Create: `Casper/QA/QATranscript.swift` (stub)
- Create: `Casper/QA/MeetingQASystemPrompt.swift` (stub)
- Create: `CasperTests/PathSandboxTests.swift` (stub)
- Create: `CasperTests/MeetingQAToolsTests.swift` (stub)
- Create: `CasperTests/MeetingQASystemPromptTests.swift` (stub)
- Create: `CasperTests/AnthropicProviderSSETests.swift` (stub)
- Create: `CasperTests/MeetingQAAgentTests.swift` (stub)
- Modify: `Casper.xcodeproj/project.pbxproj` (add via `xcodeproj` Ruby gem)

- [ ] **Step 1: Create empty stubs for all 8 new source files**

```bash
cat > Casper/QA/LLMProvider.swift <<'EOF'
import Foundation

// Implemented in Task 8.
EOF

cat > Casper/QA/AnthropicProvider.swift <<'EOF'
import Foundation

// Implemented in Tasks 9-10.
EOF

cat > Casper/QA/MeetingQAAgent.swift <<'EOF'
import Foundation

// Implemented in Task 11.
EOF

cat > Casper/QA/MeetingQATools.swift <<'EOF'
import Foundation

// Implemented in Tasks 3-5.
EOF

cat > Casper/QA/PathSandbox.swift <<'EOF'
import Foundation

// Implemented in Task 2.
EOF

cat > Casper/QA/QAEvent.swift <<'EOF'
import Foundation

// Implemented in Task 7.
EOF

cat > Casper/QA/QATranscript.swift <<'EOF'
import Foundation

// Implemented in Task 7.
EOF

cat > Casper/QA/MeetingQASystemPrompt.swift <<'EOF'
import Foundation

// Implemented in Task 6.
EOF
```

- [ ] **Step 2: Create empty test-file stubs**

```bash
for f in PathSandboxTests MeetingQAToolsTests MeetingQASystemPromptTests AnthropicProviderSSETests MeetingQAAgentTests; do
  cat > CasperTests/$f.swift <<EOF
import XCTest
@testable import Casper

final class ${f}: XCTestCase {
    // Tests added in subsequent tasks.
    func testStubCompiles() {
        XCTAssertTrue(true)
    }
}
EOF
done
```

- [ ] **Step 3: Register all 13 files in pbxproj using the `xcodeproj` Ruby gem**

```bash
ruby <<'RUBY'
require 'xcodeproj'

project = Xcodeproj::Project.open('Casper.xcodeproj')

main_target = project.targets.find { |t| t.name == 'Casper' }
test_target = project.targets.find { |t| t.name == 'CasperTests' }
abort 'Casper target not found' unless main_target
abort 'CasperTests target not found' unless test_target

# Find or create the QA group under the Casper folder.
ghost_group = project.main_group.find_subpath('Casper', false)
abort 'Casper group not found' unless ghost_group
qa_group = ghost_group.find_subpath('QA', true)
qa_group.set_source_tree('<group>')
qa_group.set_path('QA')

new_qa_files = %w[
  LLMProvider.swift
  AnthropicProvider.swift
  MeetingQAAgent.swift
  MeetingQATools.swift
  PathSandbox.swift
  QAEvent.swift
  QATranscript.swift
  MeetingQASystemPrompt.swift
]
new_qa_files.each do |fname|
  next if qa_group.files.any? { |f| f.path == fname }
  ref = qa_group.new_reference(fname)
  main_target.add_file_references([ref])
end

tests_group = project.main_group.find_subpath('CasperTests', false)
abort 'CasperTests group not found' unless tests_group

new_test_files = %w[
  PathSandboxTests.swift
  MeetingQAToolsTests.swift
  MeetingQASystemPromptTests.swift
  AnthropicProviderSSETests.swift
  MeetingQAAgentTests.swift
]
new_test_files.each do |fname|
  next if tests_group.files.any? { |f| f.path == fname }
  ref = tests_group.new_reference(fname)
  test_target.add_file_references([ref])
end

project.save
puts 'pbxproj updated.'
RUBY
```

- [ ] **Step 4: Verify build still green**

Run: `xcodebuild build -project Casper.xcodeproj -scheme Casper -destination 'platform=macOS' -skipMacroValidation -quiet`

Expected: `** BUILD SUCCEEDED **`. The stub files contain only comments + `import Foundation`, so nothing breaks.

- [ ] **Step 5: Verify the stub test passes (proves the test target picks up new files)**

Run: `xcodebuild test -project Casper.xcodeproj -scheme Casper -destination 'platform=macOS' -skipMacroValidation -only-testing:CasperTests/PathSandboxTests -quiet`

Expected: `Test Suite 'PathSandboxTests' passed`.

- [ ] **Step 6: Commit**

```bash
git add Casper/QA/*.swift CasperTests/{PathSandboxTests,MeetingQAToolsTests,MeetingQASystemPromptTests,AnthropicProviderSSETests,MeetingQAAgentTests}.swift Casper.xcodeproj/project.pbxproj
git commit -m "feat(qa): scaffold agentic Q&A files and register in pbxproj"
```

---

## Task 2: PathSandbox — safe path resolution inside the meeting archive

**Files:**
- Modify: `Casper/QA/PathSandbox.swift` (replace stub)
- Modify: `CasperTests/PathSandboxTests.swift` (replace stub)

- [ ] **Step 1: Write failing tests for PathSandbox**

Replace `CasperTests/PathSandboxTests.swift` with:

```swift
import XCTest
@testable import Casper

final class PathSandboxTests: XCTestCase {
    private var rootDir: URL!

    override func setUpWithError() throws {
        rootDir = FileManager.default.temporaryDirectory.appendingPathComponent("PathSandboxTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: rootDir.appendingPathComponent("2025-01-29"), withIntermediateDirectories: true)
        try "hello".write(to: rootDir.appendingPathComponent("2025-01-29/note.md"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: rootDir)
    }

    func testResolvesRootForEmptyAndDot() throws {
        XCTAssertEqual(try PathSandbox.resolveSafe("", root: rootDir).path, rootDir.resolvingSymlinksInPath().path)
        XCTAssertEqual(try PathSandbox.resolveSafe(".", root: rootDir).path, rootDir.resolvingSymlinksInPath().path)
    }

    func testResolvesValidRelativePath() throws {
        let url = try PathSandbox.resolveSafe("2025-01-29/note.md", root: rootDir)
        XCTAssertTrue(url.path.hasSuffix("/2025-01-29/note.md"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testRejectsParentEscape() {
        XCTAssertThrowsError(try PathSandbox.resolveSafe("../outside.md", root: rootDir)) { error in
            guard case PathSandboxError.pathOutsideRoot = error else {
                XCTFail("Expected pathOutsideRoot, got \(error)")
                return
            }
        }
    }

    func testRejectsAbsolutePath() {
        XCTAssertThrowsError(try PathSandbox.resolveSafe("/etc/passwd", root: rootDir)) { error in
            guard case PathSandboxError.pathOutsideRoot = error else {
                XCTFail("Expected pathOutsideRoot, got \(error)")
                return
            }
        }
    }

    func testRejectsSymlinkOutsideRoot() throws {
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("PathSandboxTests-outside-\(UUID().uuidString).md")
        try "secret".write(to: outside, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: outside) }

        let symlinkPath = rootDir.appendingPathComponent("link.md")
        try FileManager.default.createSymbolicLink(at: symlinkPath, withDestinationURL: outside)

        XCTAssertThrowsError(try PathSandbox.resolveSafe("link.md", root: rootDir)) { error in
            guard case PathSandboxError.pathOutsideRoot = error else {
                XCTFail("Expected pathOutsideRoot, got \(error)")
                return
            }
        }
    }

    func testAllowsSymlinkInsideRoot() throws {
        let target = rootDir.appendingPathComponent("2025-01-29/note.md")
        let symlink = rootDir.appendingPathComponent("alias.md")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: target)
        XCTAssertNoThrow(try PathSandbox.resolveSafe("alias.md", root: rootDir))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project Casper.xcodeproj -scheme Casper -destination 'platform=macOS' -skipMacroValidation -only-testing:CasperTests/PathSandboxTests -quiet`

Expected: compile error (`PathSandbox` and `PathSandboxError` not defined).

- [ ] **Step 3: Implement PathSandbox**

Replace `Casper/QA/PathSandbox.swift` with:

```swift
import Foundation

enum PathSandboxError: LocalizedError {
    case pathOutsideRoot(String)

    var errorDescription: String? {
        switch self {
        case .pathOutsideRoot(let p):
            return "Path '\(p)' is outside the meeting archive."
        }
    }
}

enum PathSandbox {
    static func resolveSafe(_ relative: String, root: URL) throws -> URL {
        let trimmed = relative.trimmingCharacters(in: .whitespaces)
        let candidate: URL
        if trimmed.isEmpty || trimmed == "." {
            candidate = root
        } else if trimmed.hasPrefix("/") {
            // Absolute paths are never allowed.
            throw PathSandboxError.pathOutsideRoot(relative)
        } else {
            candidate = root.appendingPathComponent(trimmed)
        }

        let resolved = candidate.standardizedFileURL.resolvingSymlinksInPath()
        let rootResolved = root.standardizedFileURL.resolvingSymlinksInPath()
        let rootPath = rootResolved.path
        let rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"

        if resolved.path == rootPath || resolved.path.hasPrefix(rootPrefix) {
            return resolved
        }
        throw PathSandboxError.pathOutsideRoot(relative)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project Casper.xcodeproj -scheme Casper -destination 'platform=macOS' -skipMacroValidation -only-testing:CasperTests/PathSandboxTests -quiet`

Expected: `Test Suite 'PathSandboxTests' passed` with 6 tests passing.

- [ ] **Step 5: Commit**

```bash
git add Casper/QA/PathSandbox.swift CasperTests/PathSandboxTests.swift
git commit -m "feat(qa): add PathSandbox for meeting archive root containment"
```

---

## Task 3: MeetingQATools — `grep` tool

**Files:**
- Modify: `Casper/QA/MeetingQATools.swift` (add grep)
- Modify: `CasperTests/MeetingQAToolsTests.swift` (replace stub)

- [ ] **Step 1: Write failing tests for grep**

Replace `CasperTests/MeetingQAToolsTests.swift` with:

```swift
import XCTest
@testable import Casper

final class MeetingQAToolsTests: XCTestCase {
    private var rootDir: URL!

    override func setUpWithError() throws {
        rootDir = FileManager.default.temporaryDirectory.appendingPathComponent("MeetingQAToolsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootDir.appendingPathComponent("2025-01-29"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: rootDir.appendingPathComponent("2026-01-07"), withIntermediateDirectories: true)
        try """
        ---
        title: "Dana <> Matt"
        date: "2025-01-29"
        ---

        # Dana <> Matt

        ## Summary
        Discussion about Quinn Adler and the fund.
        """.write(to: rootDir.appendingPathComponent("2025-01-29/dana-matt.md"), atomically: true, encoding: .utf8)

        try """
        # team-standup

        **Date:** 2026-01-07

        ## Notes
        Sam Rivers - he's not a Quinn Adler for 10 years. Trade ideas.
        """.write(to: rootDir.appendingPathComponent("2026-01-07/team-standup.md"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: rootDir)
    }

    // MARK: - grep

    func testGrepFindsMatchAcrossArchive() async throws {
        let tools = MeetingQATools(root: rootDir)
        let result = try await tools.grep(pattern: "Quinn", path: nil, caseInsensitive: true, maxResults: 50)
        XCTAssertTrue(result.contains("2025-01-29/dana-matt.md:"), "Expected file:line match in output: \(result)")
        XCTAssertTrue(result.contains("2026-01-07/team-standup.md:"), "Expected second-file match in output: \(result)")
    }

    func testGrepRespectsMaxResults() async throws {
        let tools = MeetingQATools(root: rootDir)
        let result = try await tools.grep(pattern: "Quinn", path: nil, caseInsensitive: true, maxResults: 1)
        // Two matches in fixtures, capped to 1.
        let matchLines = result.split(separator: "\n").filter { $0.contains(".md:") }
        XCTAssertEqual(matchLines.count, 1, "Expected exactly 1 match line, got: \(result)")
        XCTAssertTrue(result.contains("max_results was M and was hit") || result.contains("max_results was 1"), "Expected hit-cap meta line: \(result)")
    }

    func testGrepReturnsNoMatchesMessage() async throws {
        let tools = MeetingQATools(root: rootDir)
        let result = try await tools.grep(pattern: "definitelynotinanyfile", path: nil, caseInsensitive: false, maxResults: 50)
        XCTAssertTrue(result.contains("No matches found"), result)
    }

    func testGrepRejectsPathOutsideRoot() async {
        let tools = MeetingQATools(root: rootDir)
        do {
            _ = try await tools.grep(pattern: "anything", path: "../outside", caseInsensitive: true, maxResults: 10)
            XCTFail("Expected pathOutsideRoot error")
        } catch let error as PathSandboxError {
            guard case .pathOutsideRoot = error else { XCTFail("Wrong error: \(error)"); return }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project Casper.xcodeproj -scheme Casper -destination 'platform=macOS' -skipMacroValidation -only-testing:CasperTests/MeetingQAToolsTests -quiet`

Expected: compile error (`MeetingQATools` not defined).

- [ ] **Step 3: Implement `MeetingQATools` with `grep`**

Replace `Casper/QA/MeetingQATools.swift` with:

```swift
import Foundation

enum MeetingQAToolError: LocalizedError {
    case grepFailed(String)
    case readFailed(String)
    case timedOut(String)
    case notADirectory(String)
    case fileNotFound(String)
    case invalidArguments(String)

    var errorDescription: String? {
        switch self {
        case .grepFailed(let m): return "grep failed: \(m)"
        case .readFailed(let m): return "read failed: \(m)"
        case .timedOut(let what): return "\(what) timed out after 30s. Narrow scope and retry."
        case .notADirectory(let p): return "Not a directory: \(p)"
        case .fileNotFound(let p): return "File not found: \(p)"
        case .invalidArguments(let m): return "Invalid arguments: \(m)"
        }
    }
}

struct MeetingQATools {
    let root: URL
    private let timeout: TimeInterval = 30

    init(root: URL) {
        self.root = root
    }

    // MARK: - grep

    func grep(pattern: String, path: String?, caseInsensitive: Bool, maxResults: Int) async throws -> String {
        let searchURL: URL
        if let path = path, !path.isEmpty, path != "." {
            searchURL = try PathSandbox.resolveSafe(path, root: root)
        } else {
            searchURL = root
        }

        let binary = Self.preferredGrepBinary()
        var args: [String] = ["-r", "-n", "--include=*.md", "--exclude-dir=.git"]
        if caseInsensitive { args.append("-i") }
        // -e ensures pattern is treated as a value, not a flag.
        args.append("-e")
        args.append(pattern)
        args.append(searchURL.path)

        let result = try await runProcess(launchPath: binary, arguments: args)
        // grep exit codes: 0 = matches, 1 = no matches, >1 = error.
        if result.exitCode > 1 {
            throw MeetingQAToolError.grepFailed(result.stderr.isEmpty ? "exit \(result.exitCode)" : result.stderr)
        }
        if result.exitCode == 1 {
            return "No matches found for pattern: \(pattern)"
        }

        let allLines = result.stdout.split(separator: "\n", omittingEmptySubsequences: true).map { String($0) }
        let totalMatches = allLines.count
        let cap = max(1, min(maxResults, 200))
        let truncated = allLines.prefix(cap)
        let rebased = truncated.map { line -> String in
            // Replace absolute root prefix with relative path.
            if line.hasPrefix(root.path + "/") {
                return String(line.dropFirst(root.path.count + 1))
            }
            return line
        }
        var output = rebased.joined(separator: "\n")
        if !output.isEmpty { output += "\n" }
        if totalMatches > cap {
            output += "\n(Returned \(cap) matches; max_results was \(cap) and was hit. Increase max_results or narrow scope to see more.)"
        } else {
            output += "\n(Returned \(totalMatches) of \(totalMatches) matches.)"
        }
        return output
    }

    // MARK: - Process plumbing

    private struct ProcessResult {
        let stdout: String
        let stderr: String
        let exitCode: Int32
    }

    private func runProcess(launchPath: String, arguments: [String]) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ProcessResult, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: launchPath)
            process.arguments = arguments

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            var didResume = false
            let resumeLock = NSLock()
            func resumeOnce(_ block: () -> Void) {
                resumeLock.lock(); defer { resumeLock.unlock() }
                guard !didResume else { return }
                didResume = true
                block()
            }

            let timer = DispatchSource.makeTimerSource(queue: .global())
            timer.schedule(deadline: .now() + timeout)
            timer.setEventHandler {
                if process.isRunning {
                    process.terminate()
                    resumeOnce { continuation.resume(throwing: MeetingQAToolError.timedOut("grep")) }
                }
            }
            timer.resume()

            process.terminationHandler = { p in
                timer.cancel()
                let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let stdout = String(data: outData, encoding: .utf8) ?? ""
                let stderr = String(data: errData, encoding: .utf8) ?? ""
                resumeOnce { continuation.resume(returning: ProcessResult(stdout: stdout, stderr: stderr, exitCode: p.terminationStatus)) }
            }

            do {
                try process.run()
            } catch {
                timer.cancel()
                resumeOnce { continuation.resume(throwing: error) }
            }
        }
    }

    private static func preferredGrepBinary() -> String {
        let candidates = ["/opt/homebrew/bin/rg", "/usr/local/bin/rg"]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) {
            return c
        }
        return "/usr/bin/grep"
    }
}
```

> Note: ripgrep accepts `-r -n --include` flags compatibly. If a future change finds an incompatibility, fall back to `/usr/bin/grep` always.

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project Casper.xcodeproj -scheme Casper -destination 'platform=macOS' -skipMacroValidation -only-testing:CasperTests/MeetingQAToolsTests -quiet`

Expected: 4 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Casper/QA/MeetingQATools.swift CasperTests/MeetingQAToolsTests.swift
git commit -m "feat(qa): add grep tool with rg fallback and result-cap metadata"
```

---

## Task 4: MeetingQATools — `read_file` tool

**Files:**
- Modify: `Casper/QA/MeetingQATools.swift` (add readFile method)
- Modify: `CasperTests/MeetingQAToolsTests.swift` (add readFile tests)

- [ ] **Step 1: Append failing tests for `readFile`**

Add to `CasperTests/MeetingQAToolsTests.swift` inside the `MeetingQAToolsTests` class (before the closing `}`):

```swift
    // MARK: - read_file

    func testReadFileReturnsRequestedSliceWithLineNumbers() async throws {
        let tools = MeetingQATools(root: rootDir)
        let result = try await tools.readFile(path: "2025-01-29/dana-matt.md", offset: 1, limit: 200)
        // First content line is "---", line 2 is title.
        XCTAssertTrue(result.hasPrefix("1\t---\n"), "Expected line 1 prefix, got: \(result.prefix(30))")
        XCTAssertTrue(result.contains("2\ttitle: \"Dana <> Matt\""), "Expected line 2: \(result)")
        XCTAssertTrue(result.contains("(End of file at line"), "Expected end-of-file footer: \(result)")
    }

    func testReadFileWithOffsetSkipsEarlierLines() async throws {
        let tools = MeetingQATools(root: rootDir)
        let result = try await tools.readFile(path: "2025-01-29/dana-matt.md", offset: 5, limit: 1)
        // Line 5 of fixture is the blank line after frontmatter; line 6 is the H1.
        // We asked for limit=1 starting at offset=5, so we get exactly line 5.
        let firstLine = result.split(separator: "\n").first ?? ""
        XCTAssertTrue(firstLine.hasPrefix("5\t"), "Expected line 5 prefix, got: \(firstLine)")
    }

    func testReadFilePaginationFooterWhenMoreLinesExist() async throws {
        // Build a 50-line file, ask for first 10.
        let big = (1...50).map { "line \($0)" }.joined(separator: "\n")
        let url = rootDir.appendingPathComponent("2025-01-29/big.md")
        try big.write(to: url, atomically: true, encoding: .utf8)
        let tools = MeetingQATools(root: rootDir)
        let result = try await tools.readFile(path: "2025-01-29/big.md", offset: 1, limit: 10)
        XCTAssertTrue(result.contains("(Returned lines 1-10 of 50. Use offset=11 to continue.)"), result)
    }

    func testReadFileRejectsPathOutsideRoot() async {
        let tools = MeetingQATools(root: rootDir)
        do {
            _ = try await tools.readFile(path: "../outside.md", offset: 1, limit: 200)
            XCTFail("Expected pathOutsideRoot error")
        } catch is PathSandboxError {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testReadFileMissingFileThrows() async {
        let tools = MeetingQATools(root: rootDir)
        do {
            _ = try await tools.readFile(path: "nope.md", offset: 1, limit: 200)
            XCTFail("Expected fileNotFound error")
        } catch let error as MeetingQAToolError {
            guard case .fileNotFound = error else { XCTFail("Wrong error: \(error)"); return }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project Casper.xcodeproj -scheme Casper -destination 'platform=macOS' -skipMacroValidation -only-testing:CasperTests/MeetingQAToolsTests -quiet`

Expected: compile error (`readFile` method not defined on `MeetingQATools`).

- [ ] **Step 3: Implement `readFile`**

Add to `Casper/QA/MeetingQATools.swift` inside the `MeetingQATools` struct (before the `// MARK: - Process plumbing` line):

```swift
    // MARK: - read_file

    func readFile(path: String, offset: Int, limit: Int) async throws -> String {
        let resolved = try PathSandbox.resolveSafe(path, root: root)
        guard FileManager.default.fileExists(atPath: resolved.path) else {
            throw MeetingQAToolError.fileNotFound(path)
        }
        let content: String
        do {
            content = try String(contentsOf: resolved, encoding: .utf8)
        } catch {
            throw MeetingQAToolError.readFailed("\(path): \(error.localizedDescription)")
        }

        let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map { String($0) }
        let totalLines = lines.count
        let safeOffset = max(1, offset)
        let safeLimit = max(1, min(limit, 1000))

        let startIndex = safeOffset - 1
        guard startIndex < totalLines else {
            return "(File has \(totalLines) lines; requested offset=\(safeOffset) is past end of file.)"
        }
        let endExclusive = min(startIndex + safeLimit, totalLines)
        let slice = lines[startIndex..<endExclusive]
        let numbered = slice.enumerated().map { (i, line) in
            "\(safeOffset + i)\t\(line)"
        }.joined(separator: "\n")

        let footer: String
        if endExclusive >= totalLines {
            footer = "\n\n(End of file at line \(totalLines).)"
        } else {
            footer = "\n\n(Returned lines \(safeOffset)-\(endExclusive) of \(totalLines). Use offset=\(endExclusive + 1) to continue.)"
        }
        return numbered + footer
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project Casper.xcodeproj -scheme Casper -destination 'platform=macOS' -skipMacroValidation -only-testing:CasperTests/MeetingQAToolsTests -quiet`

Expected: 9 tests total now passing (4 grep + 5 read_file).

- [ ] **Step 5: Commit**

```bash
git add Casper/QA/MeetingQATools.swift CasperTests/MeetingQAToolsTests.swift
git commit -m "feat(qa): add read_file tool with line numbers and pagination footer"
```

---

## Task 5: MeetingQATools — `list_dir` tool

**Files:**
- Modify: `Casper/QA/MeetingQATools.swift` (add listDir method)
- Modify: `CasperTests/MeetingQAToolsTests.swift` (add listDir tests)

- [ ] **Step 1: Append failing tests for `listDir`**

Add to `CasperTests/MeetingQAToolsTests.swift` inside the class:

```swift
    // MARK: - list_dir

    func testListDirReturnsSortedEntriesWithDirSuffix() async throws {
        let tools = MeetingQATools(root: rootDir)
        let result = try await tools.listDir(path: "")
        let lines = result.split(separator: "\n").map(String.init)
        XCTAssertTrue(lines.contains("2025-01-29/"), "Expected dir entry: \(lines)")
        XCTAssertTrue(lines.contains("2026-01-07/"), "Expected dir entry: \(lines)")
        // Lexicographic sort: 2025 before 2026.
        let i25 = lines.firstIndex(of: "2025-01-29/")!
        let i26 = lines.firstIndex(of: "2026-01-07/")!
        XCTAssertLessThan(i25, i26)
    }

    func testListDirInsideDateFolder() async throws {
        let tools = MeetingQATools(root: rootDir)
        let result = try await tools.listDir(path: "2025-01-29")
        XCTAssertTrue(result.contains("dana-matt.md"))
        XCTAssertFalse(result.contains("dana-matt.md/"), "File should not have / suffix: \(result)")
    }

    func testListDirRejectsPathOutsideRoot() async {
        let tools = MeetingQATools(root: rootDir)
        do {
            _ = try await tools.listDir(path: "../outside")
            XCTFail("Expected pathOutsideRoot error")
        } catch is PathSandboxError {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testListDirOnMissingDirThrows() async {
        let tools = MeetingQATools(root: rootDir)
        do {
            _ = try await tools.listDir(path: "nope")
            XCTFail("Expected notADirectory error")
        } catch let error as MeetingQAToolError {
            guard case .notADirectory = error else { XCTFail("Wrong error: \(error)"); return }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project Casper.xcodeproj -scheme Casper -destination 'platform=macOS' -skipMacroValidation -only-testing:CasperTests/MeetingQAToolsTests -quiet`

Expected: compile error (`listDir` not defined).

- [ ] **Step 3: Implement `listDir`**

Add to `Casper/QA/MeetingQATools.swift` inside the struct (before `// MARK: - Process plumbing`):

```swift
    // MARK: - list_dir

    func listDir(path: String) async throws -> String {
        let resolved = try PathSandbox.resolveSafe(path, root: root)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDir), isDir.boolValue else {
            throw MeetingQAToolError.notADirectory(path.isEmpty ? "." : path)
        }
        let entries = try FileManager.default.contentsOfDirectory(at: resolved, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        let formatted: [String] = try entries.map { url in
            let values = try url.resourceValues(forKeys: [.isDirectoryKey])
            let name = url.lastPathComponent
            return (values.isDirectory ?? false) ? "\(name)/" : name
        }
        return formatted.sorted().joined(separator: "\n")
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project Casper.xcodeproj -scheme Casper -destination 'platform=macOS' -skipMacroValidation -only-testing:CasperTests/MeetingQAToolsTests -quiet`

Expected: 13 tests total passing (4 grep + 5 read_file + 4 list_dir).

- [ ] **Step 5: Commit**

```bash
git add Casper/QA/MeetingQATools.swift CasperTests/MeetingQAToolsTests.swift
git commit -m "feat(qa): add list_dir tool with sorted entries and trailing-slash dir marker"
```

---

## Task 6: MeetingQASystemPrompt — system prompt builder

**Files:**
- Modify: `Casper/QA/MeetingQASystemPrompt.swift` (replace stub)
- Modify: `CasperTests/MeetingQASystemPromptTests.swift` (replace stub)

- [ ] **Step 1: Write failing tests**

Replace `CasperTests/MeetingQASystemPromptTests.swift` with:

```swift
import XCTest
@testable import Casper

final class MeetingQASystemPromptTests: XCTestCase {
    func testPromptInterpolatesArchiveRoot() {
        let prompt = MeetingQASystemPrompt.build(archiveRootPath: "/tmp/Meetings")
        XCTAssertTrue(prompt.contains("Root: /tmp/Meetings"), prompt)
    }

    func testPromptDescribesGranolaFormat() {
        let prompt = MeetingQASystemPrompt.build(archiveRootPath: "/tmp/Meetings")
        XCTAssertTrue(prompt.contains("Granola-imported"), prompt)
        XCTAssertTrue(prompt.contains("YAML frontmatter"), prompt)
    }

    func testPromptDescribesNativeFormat() {
        let prompt = MeetingQASystemPrompt.build(archiveRootPath: "/tmp/Meetings")
        XCTAssertTrue(prompt.contains("Native Casper"), prompt)
        XCTAssertTrue(prompt.contains("**Date:**"), prompt)
        XCTAssertTrue(prompt.contains("## Notes"), prompt)
    }

    func testPromptRequiresCitations() {
        let prompt = MeetingQASystemPrompt.build(archiveRootPath: "/tmp/Meetings")
        XCTAssertTrue(prompt.contains("cite"), prompt)
        XCTAssertTrue(prompt.contains("path:line"), prompt)
    }

    func testPromptHasVoiceToTextGuidance() {
        let prompt = MeetingQASystemPrompt.build(archiveRootPath: "/tmp/Meetings")
        XCTAssertTrue(prompt.contains("voice-to-text") || prompt.contains("Voice-to-text"), prompt)
        XCTAssertTrue(prompt.contains("Quinn Adler"), "Should include the canonical artifact example")
    }

    func testPromptDescribesMultiHopGuidance() {
        let prompt = MeetingQASystemPrompt.build(archiveRootPath: "/tmp/Meetings")
        XCTAssertTrue(prompt.contains("multi-hop") || prompt.contains("Multi-hop") || prompt.contains("know each other"), prompt)
    }

    func testPromptDescribesIterationBudget() {
        let prompt = MeetingQASystemPrompt.build(archiveRootPath: "/tmp/Meetings")
        XCTAssertTrue(prompt.contains("15"), "Iteration cap should be visible to the model")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project Casper.xcodeproj -scheme Casper -destination 'platform=macOS' -skipMacroValidation -only-testing:CasperTests/MeetingQASystemPromptTests -quiet`

Expected: compile error (`MeetingQASystemPrompt.build` not defined).

- [ ] **Step 3: Implement the system prompt builder**

Replace `Casper/QA/MeetingQASystemPrompt.swift` with:

```swift
import Foundation

enum MeetingQASystemPrompt {
    static func build(archiveRootPath: String) -> String {
        return """
        You are the meeting Q&A assistant for the user's personal meeting archive. \
        You answer questions about their meetings using three tools: grep, read_file, and list_dir.

        # Archive layout

        Root: \(archiveRootPath)

        Files are markdown meeting transcripts in YYYY-MM-DD/ folders, with one or more .md \
        files per meeting. Two file formats coexist:

        1. Granola-imported (most files). Starts with YAML frontmatter:
            ---
            title: "..."
            date: "2025-01-29T..."
            granola_id: "..."
            source_type: meeting
            imported_from: granola
            ---
           Followed by an H1 title, then ## Summary (with ### subsection headings), \
           sometimes ## Transcript with **[HH:MM] Speaker:** lines. Transcripts can be \
           4,000+ lines.

        2. Native Casper (a smaller fraction — quick notes and window snippets). \
           No frontmatter. Starts with an H1 title, then **Date:** line, then ## Notes \
           with free-form content. Generally short.

        Both formats are valid. When grep matches a file, check for `---` on line 1 to know \
        which format you're dealing with.

        # How to answer

        1. Always cite your sources as `path:line` or `path:start-end`. Every factual claim \
           needs a citation. If you can't cite it, don't claim it.
        2. Prefer grep for names, dates, and exact strings. It's much cheaper than read_file.
        3. Use read_file with a small offset/limit to confirm context around a grep match. \
           Read more (up to 1000 lines) only when you need the full meeting.
        4. Use list_dir to discover meetings on a specific date or to find date-named folders.
        5. Stop searching when you have enough to answer. Don't read every file.

        # Voice-to-text reasoning

        Transcripts are voice-to-text with frequent artifacts: misheard names, run-on \
        fragments, dropped words. When a phrase looks garbled, reason about the likely \
        intended meaning from surrounding context.

        Examples of artifacts you should interpret, not take literally:
        - "He's not a Quinn Adler for 10 years" almost certainly means \
          "He's known Quinn for 10 years."
        - "Robin" addressed in a "Dana <> Matt" meeting is most likely Dana being \
          addressed informally — note the discrepancy in your answer.
        - Names with similar phonemes are often the same person across files.

        When you interpret an artifact, say so explicitly: "The transcript reads X, which I \
        read as Y because [reason]."

        # Multi-hop questions

        For "do X and Y know each other" or similar relationship questions:
        1. Search for both names independently.
        2. Look for direct co-attendance (both names appearing in the same file's \
           attendees field or transcript).
        3. Look for one mentioning the other in a third party's meeting (often the \
           strongest signal in this archive).
        4. Cite the strongest evidence. Be honest about what you can and can't conclude.

        # Iteration budget

        You have at most 15 tool calls per question. Plan accordingly. Front-load grep \
        calls (cheap, narrow the search), then read selectively.
        """
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project Casper.xcodeproj -scheme Casper -destination 'platform=macOS' -skipMacroValidation -only-testing:CasperTests/MeetingQASystemPromptTests -quiet`

Expected: 7 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Casper/QA/MeetingQASystemPrompt.swift CasperTests/MeetingQASystemPromptTests.swift
git commit -m "feat(qa): add system prompt builder with both archive formats and v2t guidance"
```

---

## Task 7: QAEvent and QATranscript — UI-facing event types

**Files:**
- Modify: `Casper/QA/QAEvent.swift` (replace stub)
- Modify: `Casper/QA/QATranscript.swift` (replace stub)

No tests in this task — these are pure data types whose behavior is exercised by the agent and UI tests.

- [ ] **Step 1: Implement QAEvent.swift**

Replace `Casper/QA/QAEvent.swift` with:

```swift
import Foundation

/// One unit of activity emitted by the agent loop, consumed by the UI.
enum QAEvent {
    case status(String)
    case toolCall(id: String, name: String, inputSummary: String, fullInput: [String: Any])
    case toolResult(id: String, summary: String, fullOutput: String, isError: Bool)
    case text(String)
    case usage(QAUsage)
    case error(String)
}

struct QAUsage: Equatable {
    let modelDisplayName: String
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let cacheWriteTokens: Int
    let estimatedCostUSD: Double
    let isLocal: Bool
}
```

- [ ] **Step 2: Implement QATranscript.swift**

Replace `Casper/QA/QATranscript.swift` with:

```swift
import Foundation
import Combine

/// Holds the full event log for the current question. Powers the expandable trace UI.
/// Stores **full** tool inputs and outputs (not summaries) so tap-to-copy works.
@MainActor
final class QATranscript: ObservableObject {
    @Published private(set) var events: [QAEvent] = []

    func append(_ event: QAEvent) {
        events.append(event)
    }

    func clear() {
        events.removeAll()
    }
}
```

- [ ] **Step 3: Verify build is green**

Run: `xcodebuild build -project Casper.xcodeproj -scheme Casper -destination 'platform=macOS' -skipMacroValidation -quiet`

Expected: `** BUILD SUCCEEDED **`. Note: `QAUsage` is now defined in `QAEvent.swift`. The old `QAUsage` definition in `QABackendKind.swift` is still there until Task 15 — Swift will see two definitions and fail to compile if both are visible. Resolve by deleting the old definition now.

- [ ] **Step 4: Remove the old QAUsage and QAStreamEvent from QABackendKind.swift**

Edit `Casper/QA/QABackendKind.swift`. Delete the `struct QAUsage` and `enum QAStreamEvent` definitions (lines around 41–67). Keep `enum QABackendKind` and `enum ClaudeAPIModel` for now — they'll be reshaped in Task 15.

After this edit, the `static func local(...)` factory on `QAUsage` is gone. The current `AppState.swift` code at line 1076 calls `QAUsage.local(...)`. We'll need to provide a free-function or static factory equivalent on the new `QAUsage`. For now, add this back to `QAEvent.swift` at the end:

```swift
extension QAUsage {
    static func local(modelDisplayName: String, inputTokens: Int, outputTokens: Int) -> QAUsage {
        QAUsage(
            modelDisplayName: modelDisplayName,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheReadTokens: 0,
            cacheWriteTokens: 0,
            estimatedCostUSD: 0,
            isLocal: true
        )
    }
}
```

This keeps the existing local-backend path compiling until Task 12 rewires `AppState`.

- [ ] **Step 5: Verify build is green**

Run: `xcodebuild build -project Casper.xcodeproj -scheme Casper -destination 'platform=macOS' -skipMacroValidation -quiet`

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add Casper/QA/QAEvent.swift Casper/QA/QATranscript.swift Casper/QA/QABackendKind.swift
git commit -m "feat(qa): introduce QAEvent and QATranscript; move QAUsage to QAEvent.swift"
```

---

## Task 8: LLMProvider protocol and shared types

**Files:**
- Modify: `Casper/QA/LLMProvider.swift` (replace stub)

No new tests; the protocol is exercised by the AnthropicProvider and MeetingQAAgent tests.

- [ ] **Step 1: Implement LLMProvider.swift**

Replace `Casper/QA/LLMProvider.swift` with:

```swift
import Foundation

/// Abstract LLM backend. One round trip per call. The agent does the looping.
protocol LLMProvider {
    func complete(
        system: String,
        messages: [LLMMessage],
        tools: [LLMTool]
    ) -> AsyncThrowingStream<ProviderEvent, Error>
}

struct LLMMessage {
    enum Role {
        case user
        case assistant
    }
    let role: Role
    let content: [LLMContentBlock]
}

enum LLMContentBlock {
    case text(String)
    case toolUse(id: String, name: String, input: [String: Any])
    case toolResult(toolUseId: String, content: String, isError: Bool)
}

struct LLMTool {
    let name: String
    let description: String
    let inputSchema: [String: Any]
}

enum ProviderEvent {
    case textDelta(String)
    case toolUse(id: String, name: String, input: [String: Any])
    case stop(reason: StopReason, usage: ProviderUsage)
}

enum StopReason: Equatable {
    case endTurn
    case toolUse
    case maxTokens
    case other(String)
}

struct ProviderUsage: Equatable {
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let cacheWriteTokens: Int

    static let zero = ProviderUsage(inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0)
}

enum LLMProviderKind: String, CaseIterable, Identifiable {
    case anthropic

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .anthropic: return "Anthropic (Claude)"
        }
    }
}
```

- [ ] **Step 2: Verify build green**

Run: `xcodebuild build -project Casper.xcodeproj -scheme Casper -destination 'platform=macOS' -skipMacroValidation -quiet`

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add Casper/QA/LLMProvider.swift
git commit -m "feat(qa): add LLMProvider protocol and provider-neutral types"
```

---

## Task 9: AnthropicProvider — SSE buffer accumulator (TDD core)

This task isolates the trickiest part of the provider — multi-chunk `input_json_delta` accumulation — and tests it with canned SSE input. Network code comes in Task 10.

**Files:**
- Modify: `Casper/QA/AnthropicProvider.swift` (add `AnthropicSSEAccumulator`)
- Modify: `CasperTests/AnthropicProviderSSETests.swift` (replace stub)

- [ ] **Step 1: Write failing tests for SSE accumulator**

Replace `CasperTests/AnthropicProviderSSETests.swift` with:

```swift
import XCTest
@testable import Casper

final class AnthropicProviderSSETests: XCTestCase {
    func testTextDeltaEmitsImmediately() throws {
        var emitted: [ProviderEvent] = []
        var acc = AnthropicSSEAccumulator(onEvent: { emitted.append($0) })

        try acc.handle(eventJSON: """
        {"type":"message_start","message":{"usage":{"input_tokens":10,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"output_tokens":0}}}
        """)
        try acc.handle(eventJSON: """
        {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}
        """)
        try acc.handle(eventJSON: """
        {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}
        """)

        XCTAssertEqual(emitted.count, 1)
        if case .textDelta(let s) = emitted[0] {
            XCTAssertEqual(s, "Hello")
        } else {
            XCTFail("Expected .textDelta, got \(emitted[0])")
        }
    }

    func testToolUseAccumulatesAcrossDeltasAndEmitsOnBlockStop() throws {
        var emitted: [ProviderEvent] = []
        var acc = AnthropicSSEAccumulator(onEvent: { emitted.append($0) })

        try acc.handle(eventJSON: """
        {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_abc","name":"grep","input":{}}}
        """)
        try acc.handle(eventJSON: """
        {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\\"pattern\\":\\"Nev"}}
        """)
        try acc.handle(eventJSON: """
        {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"ille\\"}"}}
        """)
        // No event should have been emitted yet — buffer is incomplete.
        XCTAssertTrue(emitted.isEmpty, "Should not emit until block_stop, got \(emitted)")

        try acc.handle(eventJSON: """
        {"type":"content_block_stop","index":1}
        """)

        XCTAssertEqual(emitted.count, 1)
        if case .toolUse(let id, let name, let input) = emitted[0] {
            XCTAssertEqual(id, "toolu_abc")
            XCTAssertEqual(name, "grep")
            XCTAssertEqual(input["pattern"] as? String, "Quinn")
        } else {
            XCTFail("Expected .toolUse, got \(emitted[0])")
        }
    }

    func testStopEventCarriesStopReasonAndUsage() throws {
        var emitted: [ProviderEvent] = []
        var acc = AnthropicSSEAccumulator(onEvent: { emitted.append($0) })

        try acc.handle(eventJSON: """
        {"type":"message_start","message":{"usage":{"input_tokens":5,"cache_read_input_tokens":2,"cache_creation_input_tokens":3,"output_tokens":0}}}
        """)
        try acc.handle(eventJSON: """
        {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":7}}
        """)
        try acc.handle(eventJSON: """
        {"type":"message_stop"}
        """)

        XCTAssertEqual(emitted.count, 1)
        if case .stop(let reason, let usage) = emitted[0] {
            XCTAssertEqual(reason, .endTurn)
            XCTAssertEqual(usage.inputTokens, 5)
            XCTAssertEqual(usage.outputTokens, 7)
            XCTAssertEqual(usage.cacheReadTokens, 2)
            XCTAssertEqual(usage.cacheWriteTokens, 3)
        } else {
            XCTFail("Expected .stop, got \(emitted[0])")
        }
    }

    func testStopReasonToolUseRecognized() throws {
        var emitted: [ProviderEvent] = []
        var acc = AnthropicSSEAccumulator(onEvent: { emitted.append($0) })
        try acc.handle(eventJSON: """
        {"type":"message_start","message":{"usage":{"input_tokens":1,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"output_tokens":0}}}
        """)
        try acc.handle(eventJSON: """
        {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":3}}
        """)
        try acc.handle(eventJSON: """
        {"type":"message_stop"}
        """)
        XCTAssertEqual(emitted.count, 1)
        if case .stop(let reason, _) = emitted[0] {
            XCTAssertEqual(reason, .toolUse)
        } else {
            XCTFail("Expected .stop with .toolUse")
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project Casper.xcodeproj -scheme Casper -destination 'platform=macOS' -skipMacroValidation -only-testing:CasperTests/AnthropicProviderSSETests -quiet`

Expected: compile error (`AnthropicSSEAccumulator` not defined).

- [ ] **Step 3: Implement the SSE accumulator**

Replace `Casper/QA/AnthropicProvider.swift` with:

```swift
import Foundation

enum AnthropicProviderError: LocalizedError {
    case missingAPIKey
    case invalidResponse
    case httpError(status: Int, message: String)
    case decodeError(String)
    case streamError(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "Claude API key not configured. Add it in Settings → Meeting Transcript."
        case .invalidResponse: return "Invalid response from Claude API."
        case .httpError(let status, let message): return "Claude API error \(status): \(message)"
        case .decodeError(let detail): return "Failed to decode Claude response: \(detail)"
        case .streamError(let detail): return "Stream error: \(detail)"
        }
    }
}

/// Accumulates Anthropic SSE events into provider-neutral ProviderEvents.
/// Critical contract: tool_use input arrives across multiple input_json_delta chunks,
/// so we buffer per content-block-index and parse only at content_block_stop.
struct AnthropicSSEAccumulator {
    private var jsonBuffers: [Int: String] = [:]
    private var toolUseStarts: [Int: (id: String, name: String)] = [:]
    private var pendingStopReason: StopReason?
    private var usage: ProviderUsage = .zero
    let onEvent: (ProviderEvent) -> Void

    init(onEvent: @escaping (ProviderEvent) -> Void) {
        self.onEvent = onEvent
    }

    mutating func handle(eventJSON: String) throws {
        guard let data = eventJSON.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            throw AnthropicProviderError.streamError("malformed SSE payload: \(eventJSON.prefix(120))")
        }

        switch type {
        case "message_start":
            if let msg = json["message"] as? [String: Any], let u = msg["usage"] as? [String: Any] {
                usage = ProviderUsage(
                    inputTokens: u["input_tokens"] as? Int ?? 0,
                    outputTokens: u["output_tokens"] as? Int ?? 0,
                    cacheReadTokens: u["cache_read_input_tokens"] as? Int ?? 0,
                    cacheWriteTokens: u["cache_creation_input_tokens"] as? Int ?? 0
                )
            }

        case "content_block_start":
            guard let index = json["index"] as? Int,
                  let block = json["content_block"] as? [String: Any] else { return }
            if (block["type"] as? String) == "tool_use",
               let id = block["id"] as? String,
               let name = block["name"] as? String {
                toolUseStarts[index] = (id, name)
                jsonBuffers[index] = ""
            }

        case "content_block_delta":
            guard let index = json["index"] as? Int,
                  let delta = json["delta"] as? [String: Any],
                  let deltaType = delta["type"] as? String else { return }
            switch deltaType {
            case "text_delta":
                if let text = delta["text"] as? String, !text.isEmpty {
                    onEvent(.textDelta(text))
                }
            case "input_json_delta":
                if let partial = delta["partial_json"] as? String {
                    jsonBuffers[index, default: ""] += partial
                }
            default:
                break
            }

        case "content_block_stop":
            guard let index = json["index"] as? Int else { return }
            if let start = toolUseStarts[index] {
                let buffer = jsonBuffers[index] ?? "{}"
                let inputData = buffer.isEmpty ? Data("{}".utf8) : Data(buffer.utf8)
                let parsed = (try? JSONSerialization.jsonObject(with: inputData)) as? [String: Any] ?? [:]
                onEvent(.toolUse(id: start.id, name: start.name, input: parsed))
                toolUseStarts.removeValue(forKey: index)
                jsonBuffers.removeValue(forKey: index)
            }

        case "message_delta":
            if let delta = json["delta"] as? [String: Any] {
                if let raw = delta["stop_reason"] as? String {
                    pendingStopReason = Self.parseStopReason(raw)
                }
            }
            if let u = json["usage"] as? [String: Any] {
                if let v = u["output_tokens"] as? Int { usage = ProviderUsage(inputTokens: usage.inputTokens, outputTokens: v, cacheReadTokens: usage.cacheReadTokens, cacheWriteTokens: usage.cacheWriteTokens) }
                if let v = u["input_tokens"] as? Int { usage = ProviderUsage(inputTokens: v, outputTokens: usage.outputTokens, cacheReadTokens: usage.cacheReadTokens, cacheWriteTokens: usage.cacheWriteTokens) }
                if let v = u["cache_read_input_tokens"] as? Int { usage = ProviderUsage(inputTokens: usage.inputTokens, outputTokens: usage.outputTokens, cacheReadTokens: v, cacheWriteTokens: usage.cacheWriteTokens) }
                if let v = u["cache_creation_input_tokens"] as? Int { usage = ProviderUsage(inputTokens: usage.inputTokens, outputTokens: usage.outputTokens, cacheReadTokens: usage.cacheReadTokens, cacheWriteTokens: v) }
            }

        case "message_stop":
            let reason = pendingStopReason ?? .other("missing_stop_reason")
            onEvent(.stop(reason: reason, usage: usage))

        case "error":
            if let err = json["error"] as? [String: Any], let msg = err["message"] as? String {
                throw AnthropicProviderError.streamError(msg)
            }
            throw AnthropicProviderError.streamError("unknown stream error")

        default:
            break
        }
    }

    private static func parseStopReason(_ raw: String) -> StopReason {
        switch raw {
        case "end_turn": return .endTurn
        case "tool_use": return .toolUse
        case "max_tokens": return .maxTokens
        default: return .other(raw)
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project Casper.xcodeproj -scheme Casper -destination 'platform=macOS' -skipMacroValidation -only-testing:CasperTests/AnthropicProviderSSETests -quiet`

Expected: 4 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Casper/QA/AnthropicProvider.swift CasperTests/AnthropicProviderSSETests.swift
git commit -m "feat(qa): add AnthropicSSEAccumulator with multi-chunk input_json_delta buffering"
```

---

## Task 10: AnthropicProvider — full provider implementation with HTTP/SSE

**Files:**
- Modify: `Casper/QA/AnthropicProvider.swift` (add `AnthropicProvider` struct + ClaudePricing usage)

No new unit tests; HTTP path is verified end-to-end by the manual verification task. The accumulator is already covered by Task 9's tests.

- [ ] **Step 1: Add `AnthropicProvider` struct that implements `LLMProvider`**

Append to `Casper/QA/AnthropicProvider.swift`:

```swift
struct AnthropicProvider: LLMProvider {
    static let keychainKey = "claudeAPIKey"

    let model: ClaudeAPIModel
    let apiKey: String

    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    func complete(
        system: String,
        messages: [LLMMessage],
        tools: [LLMTool]
    ) -> AsyncThrowingStream<ProviderEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let body = Self.buildRequestBody(model: model, system: system, messages: messages, tools: tools)
                    var request = URLRequest(url: Self.endpoint)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                    request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
                    request.timeoutInterval = 600
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        throw AnthropicProviderError.invalidResponse
                    }
                    if http.statusCode != 200 {
                        var data = Data()
                        for try await byte in bytes { data.append(byte) }
                        let detail = String(data: data, encoding: .utf8) ?? "<no body>"
                        throw AnthropicProviderError.httpError(status: http.statusCode, message: detail)
                    }

                    var accumulator = AnthropicSSEAccumulator { event in
                        continuation.yield(event)
                    }

                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
                        guard !payload.isEmpty, payload != "[DONE]" else { continue }
                        try accumulator.handle(eventJSON: payload)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func buildRequestBody(
        model: ClaudeAPIModel,
        system: String,
        messages: [LLMMessage],
        tools: [LLMTool]
    ) -> [String: Any] {
        var body: [String: Any] = [
            "model": model.rawValue,
            "max_tokens": 4096,
            "stream": true,
            "system": [
                [
                    "type": "text",
                    "text": system,
                    "cache_control": ["type": "ephemeral"],
                ],
            ],
            "messages": messages.map(encodeMessage(_:)),
        ]
        if !tools.isEmpty {
            body["tools"] = tools.map { tool -> [String: Any] in
                [
                    "name": tool.name,
                    "description": tool.description,
                    "input_schema": tool.inputSchema,
                ]
            }
        }
        return body
    }

    private static func encodeMessage(_ message: LLMMessage) -> [String: Any] {
        let role: String = (message.role == .user) ? "user" : "assistant"
        let blocks: [[String: Any]] = message.content.map { block in
            switch block {
            case .text(let s):
                return ["type": "text", "text": s]
            case .toolUse(let id, let name, let input):
                return ["type": "tool_use", "id": id, "name": name, "input": input]
            case .toolResult(let toolUseId, let content, let isError):
                return [
                    "type": "tool_result",
                    "tool_use_id": toolUseId,
                    "content": content,
                    "is_error": isError,
                ]
            }
        }
        return ["role": role, "content": blocks]
    }
}
```

- [ ] **Step 2: Verify build green**

Run: `xcodebuild build -project Casper.xcodeproj -scheme Casper -destination 'platform=macOS' -skipMacroValidation -quiet`

Expected: `** BUILD SUCCEEDED **`. Note `ClaudeAPIModel` is still defined in `QABackendKind.swift` at this point — that's fine; it's referenced by name.

- [ ] **Step 3: Commit**

```bash
git add Casper/QA/AnthropicProvider.swift
git commit -m "feat(qa): add AnthropicProvider implementing LLMProvider over Messages API"
```

---

## Task 11: MeetingQAAgent — orchestrator with tool dispatch and iteration cap

**Files:**
- Modify: `Casper/QA/MeetingQAAgent.swift` (replace stub)
- Modify: `CasperTests/MeetingQAAgentTests.swift` (replace stub)

- [ ] **Step 1: Write failing tests for the agent**

Replace `CasperTests/MeetingQAAgentTests.swift` with:

```swift
import XCTest
@testable import Casper

/// Mock LLMProvider that yields a programmable script of ProviderEvents.
private final class MockProvider: LLMProvider {
    /// Each `[ProviderEvent]` is returned in sequence per iteration.
    var scripts: [[ProviderEvent]]
    private(set) var calls: [(messages: [LLMMessage], tools: [LLMTool])] = []

    init(scripts: [[ProviderEvent]]) {
        self.scripts = scripts
    }

    func complete(system: String, messages: [LLMMessage], tools: [LLMTool]) -> AsyncThrowingStream<ProviderEvent, Error> {
        let script = scripts.isEmpty ? [] : scripts.removeFirst()
        calls.append((messages, tools))
        return AsyncThrowingStream { continuation in
            for event in script {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }
}

final class MeetingQAAgentTests: XCTestCase {
    private var rootDir: URL!

    override func setUpWithError() throws {
        rootDir = FileManager.default.temporaryDirectory.appendingPathComponent("MeetingQAAgentTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: rootDir.appendingPathComponent("2025-01-29"), withIntermediateDirectories: true)
        try "Quinn Adler".write(to: rootDir.appendingPathComponent("2025-01-29/dana-matt.md"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: rootDir)
    }

    func testEndsWhenProviderReturnsEndTurn() async throws {
        let provider = MockProvider(scripts: [
            [
                .textDelta("The answer is 42."),
                .stop(reason: .endTurn, usage: ProviderUsage(inputTokens: 100, outputTokens: 5, cacheReadTokens: 0, cacheWriteTokens: 0)),
            ]
        ])
        let agent = MeetingQAAgent(provider: provider, model: .sonnet, archiveRoot: rootDir, maxIterations: 15)

        var collected = ""
        var sawUsage = false
        for try await event in agent.ask("What is the answer?") {
            switch event {
            case .text(let t): collected += t
            case .usage: sawUsage = true
            default: break
            }
        }
        XCTAssertEqual(collected, "The answer is 42.")
        XCTAssertTrue(sawUsage)
    }

    func testExecutesToolCallAndContinuesLoop() async throws {
        let provider = MockProvider(scripts: [
            [
                .toolUse(id: "tu_1", name: "grep", input: ["pattern": "Quinn", "case_insensitive": true, "max_results": 50]),
                .stop(reason: .toolUse, usage: ProviderUsage(inputTokens: 50, outputTokens: 10, cacheReadTokens: 0, cacheWriteTokens: 0)),
            ],
            [
                .textDelta("Found in 2025-01-29/dana-matt.md."),
                .stop(reason: .endTurn, usage: ProviderUsage(inputTokens: 80, outputTokens: 8, cacheReadTokens: 0, cacheWriteTokens: 0)),
            ],
        ])
        let agent = MeetingQAAgent(provider: provider, model: .sonnet, archiveRoot: rootDir, maxIterations: 15)

        var sawToolCall = false
        var sawToolResult = false
        var text = ""
        for try await event in agent.ask("Where is Quinn?") {
            switch event {
            case .toolCall: sawToolCall = true
            case .toolResult: sawToolResult = true
            case .text(let t): text += t
            default: break
            }
        }
        XCTAssertTrue(sawToolCall)
        XCTAssertTrue(sawToolResult)
        XCTAssertEqual(text, "Found in 2025-01-29/dana-matt.md.")
        // Provider should have been called exactly twice: initial + after tool result.
        XCTAssertEqual(provider.calls.count, 2)
    }

    func testHonorsIterationCap() async throws {
        // Provider always returns a tool_use (would loop forever without a cap).
        let infiniteToolUse: [ProviderEvent] = [
            .toolUse(id: "tu_x", name: "grep", input: ["pattern": "anything", "case_insensitive": true, "max_results": 10]),
            .stop(reason: .toolUse, usage: ProviderUsage(inputTokens: 10, outputTokens: 1, cacheReadTokens: 0, cacheWriteTokens: 0)),
        ]
        let provider = MockProvider(scripts: Array(repeating: infiniteToolUse, count: 20))
        let agent = MeetingQAAgent(provider: provider, model: .sonnet, archiveRoot: rootDir, maxIterations: 3)

        var statuses: [String] = []
        for try await event in agent.ask("Loop forever") {
            if case .status(let s) = event { statuses.append(s) }
        }
        XCTAssertTrue(statuses.contains(where: { $0.contains("iteration cap") }), "Expected iteration-cap status, got \(statuses)")
        // 3 iterations, so 3 provider calls.
        XCTAssertEqual(provider.calls.count, 3)
    }

    func testToolErrorReportedToProviderAsIsError() async throws {
        let provider = MockProvider(scripts: [
            [
                .toolUse(id: "tu_bad", name: "read_file", input: ["path": "../escape.md", "offset": 1, "limit": 200]),
                .stop(reason: .toolUse, usage: ProviderUsage(inputTokens: 50, outputTokens: 5, cacheReadTokens: 0, cacheWriteTokens: 0)),
            ],
            [
                .textDelta("Sorry, that path was rejected."),
                .stop(reason: .endTurn, usage: ProviderUsage(inputTokens: 60, outputTokens: 6, cacheReadTokens: 0, cacheWriteTokens: 0)),
            ],
        ])
        let agent = MeetingQAAgent(provider: provider, model: .sonnet, archiveRoot: rootDir, maxIterations: 15)

        var sawErrorResult = false
        for try await event in agent.ask("Read forbidden") {
            if case .toolResult(_, _, _, let isError) = event, isError {
                sawErrorResult = true
            }
        }
        XCTAssertTrue(sawErrorResult)

        // The second provider call should include a tool_result with isError=true in the user message.
        XCTAssertEqual(provider.calls.count, 2)
        let secondCallMessages = provider.calls[1].messages
        let lastUserMsg = secondCallMessages.last { $0.role == .user }!
        let hasErrorBlock = lastUserMsg.content.contains { block in
            if case .toolResult(_, _, let isError) = block { return isError }
            return false
        }
        XCTAssertTrue(hasErrorBlock)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project Casper.xcodeproj -scheme Casper -destination 'platform=macOS' -skipMacroValidation -only-testing:CasperTests/MeetingQAAgentTests -quiet`

Expected: compile error (`MeetingQAAgent` not defined).

- [ ] **Step 3: Implement the agent**

Replace `Casper/QA/MeetingQAAgent.swift` with:

```swift
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

        for iteration in 0..<maxIterations {
            if Task.isCancelled {
                continuation.yield(.status("Stopped"))
                continuation.finish()
                return
            }

            var assistantBlocks: [LLMContentBlock] = []
            var pendingToolCalls: [(id: String, name: String, input: [String: Any])] = []
            var streamErrored = false
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

            if streamErrored { return }

            // If there are tool calls, execute and loop.
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
                // Defensive: stop_reason said tool_use but we got no tool calls. Treat as end.
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

        // Loop fell through without an explicit end_turn.
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project Casper.xcodeproj -scheme Casper -destination 'platform=macOS' -skipMacroValidation -only-testing:CasperTests/MeetingQAAgentTests -quiet`

Expected: 4 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Casper/QA/MeetingQAAgent.swift CasperTests/MeetingQAAgentTests.swift
git commit -m "feat(qa): add MeetingQAAgent orchestrator with tool dispatch and iteration cap"
```

---

## Task 12: Wire AppState to use MeetingQAAgent

**Files:**
- Modify: `Casper/AppState.swift` (around lines 1023–1092 — replace the `controller.onAskQuestion` closure body)

The current closure has a `(question, context)` signature and dispatches to either local or Claude API. We need to:
- Drop the keyword-scoring + cram path entirely (which lives in `MeetingTranscriptWindow.swift`, not here, but we no longer need the `context` arg).
- Use the new agent for the Claude API path.
- For the `.local` case (still in the enum until Task 15), emit a status saying "Local backend isn't supported in agentic mode — switch to Claude API in Settings."

The closure signature currently is:
```swift
((_ question: String, _ context: String) -> AsyncThrowingStream<QAStreamEvent, Error>)?
```

We don't change the signature in this task — that's part of Task 13 (UI). For now, accept and ignore the `context` argument; the agent fetches its own context via tools.

But wait: the closure returns `AsyncThrowingStream<QAStreamEvent, Error>` and the agent returns `AsyncThrowingStream<QAEvent, Error>`. We need an adapter. Build one inline that maps `QAEvent → QAStreamEvent` for now, until the UI is updated in Task 13.

- [ ] **Step 1: Add a temporary QAEvent → QAStreamEvent adapter**

Add this private helper to `Casper/AppState.swift` (anywhere in the class, e.g., right above the `controller.onAskQuestion` block):

```swift
// TEMPORARY adapter — removed in Task 13 when the UI is updated to consume QAEvent directly.
private func adaptAgentStream(_ source: AsyncThrowingStream<QAEvent, Error>) -> AsyncThrowingStream<QAStreamEvent, Error> {
    AsyncThrowingStream { continuation in
        let task = Task {
            do {
                for try await event in source {
                    switch event {
                    case .text(let s): continuation.yield(.text(s))
                    case .usage(let u): continuation.yield(.usage(u))
                    case .status, .toolCall, .toolResult, .error:
                        // Older UI ignores these. Suppressed until Task 13.
                        break
                    }
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
    }
}
```

> Note: `QAStreamEvent` still has the old `.text(String)` and `.usage(QAUsage)` cases — those types are retained until Task 15 cleanup.

- [ ] **Step 2: Replace the `controller.onAskQuestion` closure body**

Find the existing closure (currently around `AppState.swift:1023–1092`) and replace its body with:

```swift
controller.onAskQuestion = { [weak self] question, _ in
    AsyncThrowingStream { continuation in
        guard let self else {
            continuation.finish()
            return
        }
        let backend = QABackendKind(rawValue: self.meetingQABackend) ?? .claudeAPI
        switch backend {
        case .claudeAPI:
            guard let key = KeychainHelper.get(AnthropicProvider.keychainKey), !key.isEmpty else {
                Task { @MainActor in self.showSettings(section: .meetingTranscript) }
                continuation.yield(.text("Add your Claude API key to continue — Settings opened."))
                continuation.finish()
                return
            }
            let model = ClaudeAPIModel(rawValue: self.claudeAPIModel) ?? .sonnet
            let provider = AnthropicProvider(model: model, apiKey: key)
            let archiveRoot = MeetingTranscriptSettings.effectiveSaveDirectory()
            let agent = MeetingQAAgent(provider: provider, model: model, archiveRoot: archiveRoot, maxIterations: 15)
            let upstream = self.adaptAgentStream(agent.ask(question))
            let task = Task {
                do {
                    for try await event in upstream {
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    self.debugLogStore.record(category: .model, message: "Agentic Q&A error: \(error)")
                    continuation.yield(.text("\nClaude API error: \(error.localizedDescription)"))
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        case .local:
            // Local agentic Q&A isn't shipped. Surface a clear message.
            continuation.yield(.text("Local cross-meeting Q&A isn't supported — switch to Claude API in Settings → Meeting Transcript → Cross-Meeting Q&A."))
            continuation.finish()
        }
    }
}
```

> Note: replace `ClaudeAPIClient.keychainKey` with `AnthropicProvider.keychainKey` everywhere. Both have value `"claudeAPIKey"`, so the existing keychain entry continues to work.

- [ ] **Step 3: Update SettingsWindow to use AnthropicProvider.keychainKey**

In `Casper/UI/SettingsWindow.swift`, replace every reference to `ClaudeAPIClient.keychainKey` with `AnthropicProvider.keychainKey`:

```bash
sed -i '' 's/ClaudeAPIClient\.keychainKey/AnthropicProvider.keychainKey/g' Casper/UI/SettingsWindow.swift
```

Verify with `grep -n "ClaudeAPIClient" Casper/UI/SettingsWindow.swift` — should print nothing.

- [ ] **Step 4: Build and verify the existing test suite still passes**

Run: `xcodebuild test -project Casper.xcodeproj -scheme Casper -destination 'platform=macOS' -skipMacroValidation -quiet`

Expected: full test suite passes. Pre-existing tests unaffected; new tests from Tasks 2–11 pass.

- [ ] **Step 5: Commit**

```bash
git add Casper/AppState.swift Casper/UI/SettingsWindow.swift
git commit -m "feat(qa): wire AppState.onAskQuestion to use MeetingQAAgent"
```

---

## Task 13: MeetingTranscriptWindow Q&A bar UI — status line, expandable trace, Stop button

**Files:**
- Modify: `Casper/UI/MeetingTranscriptWindow.swift` (around lines 426–600 — `appQABar` area, `askAcrossMeetings`, supporting state)
- Modify: `Casper/AppState.swift` (drop the temporary adapter; change closure type)

This task changes the closure signature from `(question, context) -> Stream<QAStreamEvent>` to `(question) -> Stream<QAEvent>`, and replaces the keyword-scoring + cram code in `askAcrossMeetings()` with direct rendering of `QAEvent`s.

- [ ] **Step 1: Update the closure type in `MeetingTranscriptDisplayState` and `MeetingTranscriptWindowController`**

In `Casper/UI/MeetingTranscriptWindow.swift`:

Find the two places where the closure is declared (currently around lines 24 and 177):
```swift
var onAskQuestion: ((_ question: String, _ context: String) -> AsyncThrowingStream<QAStreamEvent, Error>)?
```

Replace **both** with:
```swift
var onAskQuestion: ((_ question: String) -> AsyncThrowingStream<QAEvent, Error>)?
```

- [ ] **Step 2: Replace `askAcrossMeetings()` implementation**

Find `private func askAcrossMeetings()` (currently around line 512) and replace its entire body with:

```swift
private func askAcrossMeetings() {
    let question = qaQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !question.isEmpty, !qaIsLoading else { return }
    qaIsLoading = true
    qaAnswer = ""
    qaUsage = nil
    qaStatusLine = ""
    qaTranscript.clear()

    Task { @MainActor in
        guard let stream = state.onAskQuestion?(question) else {
            qaAnswer = "Could not answer — open Settings → Meeting Transcript → Cross-Meeting Q&A to configure."
            qaIsLoading = false
            return
        }

        currentQATask = Task {
            do {
                for try await event in stream {
                    if Task.isCancelled { break }
                    switch event {
                    case .status(let s):
                        qaStatusLine = s
                        qaTranscript.append(event)
                    case .toolCall(_, let name, let summary, _):
                        qaStatusLine = formatToolStatusLine(name: name, summary: summary)
                        qaTranscript.append(event)
                    case .toolResult:
                        // Status line stays; user can expand the trace for details.
                        qaTranscript.append(event)
                    case .text(let delta):
                        qaStatusLine = "Thinking..."
                        qaAnswer += delta
                        qaTranscript.append(event)
                    case .usage(let u):
                        qaUsage = u
                        qaTranscript.append(event)
                    case .error(let msg):
                        qaAnswer = qaAnswer.isEmpty ? "Error: \(msg)" : qaAnswer + "\n\n[error: \(msg)]"
                        qaTranscript.append(event)
                    }
                }
                qaAnswer = qaAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
                if qaAnswer.isEmpty {
                    qaAnswer = "No answer returned. Check the trace for what was searched."
                }
            } catch {
                qaAnswer = qaAnswer.isEmpty ? "Stream error: \(error.localizedDescription)" : qaAnswer + "\n\n[stream interrupted: \(error.localizedDescription)]"
            }
            qaStatusLine = ""
            qaIsLoading = false
            currentQATask = nil
        }
    }
}

private func formatToolStatusLine(name: String, summary: String) -> String {
    switch name {
    case "grep": return "Searching: \(summary)"
    case "read_file": return "Reading \(summary)"
    case "list_dir": return "Listing \(summary)"
    default: return "\(name): \(summary)"
    }
}
```

- [ ] **Step 3: Add new `@State` properties in the SwiftUI view that owns `appQABar`**

Find the view that contains `@State private var qaQuestion = ""` and `@State private var qaAnswer = ""` (currently around lines 358–359). Add alongside them:

```swift
@State private var qaStatusLine: String = ""
@State private var qaTraceExpanded: Bool = false
@StateObject private var qaTranscript: QATranscript = QATranscript()
@State private var currentQATask: Task<Void, Never>? = nil
```

Remove the existing:
```swift
@State private var qaSourceFile: String? = nil
```
…and any references to `qaSourceFile` further down in the file.

- [ ] **Step 4: Render the new UI elements above the answer**

In the `appQABar` view body (currently around line 426), find the block that renders the answer (near line 430 — `if !qaAnswer.isEmpty { ... }`). Replace its surrounding wrapper with:

```swift
if !qaStatusLine.isEmpty || qaIsLoading || !qaTranscript.events.isEmpty {
    HStack(spacing: 6) {
        if qaIsLoading {
            ProgressView().scaleEffect(0.6)
        }
        Text(qaStatusLine.isEmpty ? "" : qaStatusLine)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
        Spacer()
        if !qaTranscript.events.isEmpty {
            Button(action: { qaTraceExpanded.toggle() }) {
                Label(qaTraceExpanded ? "Hide trace" : "Show trace", systemImage: qaTraceExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
        }
        if qaIsLoading {
            Button("Stop") {
                currentQATask?.cancel()
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
    }
    .padding(.horizontal, 8)
}

if qaTraceExpanded {
    ScrollView {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(qaTranscript.events.enumerated()), id: \.offset) { _, event in
                Text(formatTraceLine(event))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
        .padding(8)
    }
    .frame(maxHeight: 180)
    .background(Color.secondary.opacity(0.06))
    .cornerRadius(6)
    .padding(.horizontal, 8)
}

if !qaAnswer.isEmpty {
    // ... existing answer rendering left unchanged ...
}
```

- [ ] **Step 5: Add the trace-line formatter**

Add this method to the same view (next to `usageFooterText`):

```swift
private func formatTraceLine(_ event: QAEvent) -> String {
    switch event {
    case .status(let s):
        return "[status]    \(s)"
    case .toolCall(_, let name, let summary, _):
        return "[\(name)]    \(summary)"
    case .toolResult(_, let summary, _, let isError):
        return isError ? "[result]    ERROR: \(summary)" : "[result]    \(summary)"
    case .text:
        return "[text]      (streaming...)"
    case .usage(let u):
        let cost = String(format: "$%.4f", u.estimatedCostUSD)
        return "[usage]     \(u.modelDisplayName) · \(u.inputTokens) in / \(u.outputTokens) out · \(cost)"
    case .error(let msg):
        return "[error]     \(msg)"
    }
}
```

- [ ] **Step 6: Update reset action (clear button)**

Find the existing reset button code (currently around line 478):
```swift
Button(action: { qaAnswer = ""; qaQuestion = ""; qaSourceFile = nil; qaUsage = nil }) {
```
Replace with:
```swift
Button(action: {
    qaAnswer = ""
    qaQuestion = ""
    qaUsage = nil
    qaStatusLine = ""
    qaTranscript.clear()
    qaTraceExpanded = false
}) {
```

- [ ] **Step 7: Drop the temporary adapter and rewire AppState**

In `Casper/AppState.swift`:
- Delete the `adaptAgentStream(_:)` helper added in Task 12.
- Change the `controller.onAskQuestion` closure: drop the second `_` argument (signature is now `(question) -> AsyncThrowingStream<QAEvent, Error>`); the `AsyncThrowingStream` returned should yield `QAEvent`s directly (not `QAStreamEvent`).

The body becomes:

```swift
controller.onAskQuestion = { [weak self] question in
    AsyncThrowingStream { continuation in
        guard let self else {
            continuation.finish()
            return
        }
        let backend = QABackendKind(rawValue: self.meetingQABackend) ?? .claudeAPI
        switch backend {
        case .claudeAPI:
            guard let key = KeychainHelper.get(AnthropicProvider.keychainKey), !key.isEmpty else {
                Task { @MainActor in self.showSettings(section: .meetingTranscript) }
                continuation.yield(.error("Add your Claude API key to continue — Settings opened."))
                continuation.finish()
                return
            }
            let model = ClaudeAPIModel(rawValue: self.claudeAPIModel) ?? .sonnet
            let provider = AnthropicProvider(model: model, apiKey: key)
            let archiveRoot = MeetingTranscriptSettings.effectiveSaveDirectory()
            let agent = MeetingQAAgent(provider: provider, model: model, archiveRoot: archiveRoot, maxIterations: 15)
            let task = Task {
                do {
                    for try await event in agent.ask(question) {
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    self.debugLogStore.record(category: .model, message: "Agentic Q&A error: \(error)")
                    continuation.yield(.error("Claude API error: \(error.localizedDescription)"))
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        case .local:
            continuation.yield(.error("Local cross-meeting Q&A isn't supported — switch to Claude API in Settings → Meeting Transcript → Cross-Meeting Q&A."))
            continuation.finish()
        }
    }
}
```

- [ ] **Step 8: Build and run all tests**

Run: `xcodebuild test -project Casper.xcodeproj -scheme Casper -destination 'platform=macOS' -skipMacroValidation -quiet`

Expected: full test suite passes.

- [ ] **Step 9: Commit**

```bash
git add Casper/UI/MeetingTranscriptWindow.swift Casper/AppState.swift
git commit -m "feat(qa): replace cross-meeting Q&A UI with status line + expandable trace + Stop"
```

---

## Task 14: SettingsWindow — replace backend picker with provider picker, drop local row

**Files:**
- Modify: `Casper/UI/SettingsWindow.swift` (around lines 1818–1865 — `crossMeetingQACard`)

- [ ] **Step 1: Update `crossMeetingQACard`**

Find `private var crossMeetingQACard: some View` (around line 1818). Replace its body with the version below. The previous "Backend: Local / Claude API" picker becomes "Provider: Anthropic", and the local-Q&A-model row is removed.

```swift
private var crossMeetingQACard: some View {
    GroupBox(label: Text("Cross-Meeting Q&A").font(.headline)) {
        VStack(alignment: .leading, spacing: 12) {
            Text("Ask questions across all meeting transcripts. The assistant searches your archive with grep/read_file/list_dir tools and cites sources.")
                .font(.callout)
                .foregroundStyle(.secondary)

            // Provider picker — single option for now; the seam exists for future Ollama/OpenAI.
            HStack {
                Text("Provider:")
                Picker("", selection: .constant(LLMProviderKind.anthropic)) {
                    ForEach(LLMProviderKind.allCases) { p in
                        Text(p.displayName).tag(p)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 220)
                Spacer()
            }

            HStack {
                Text("Model:")
                Picker("", selection: $appState.claudeAPIModel) {
                    ForEach(ClaudeAPIModel.allCases) { m in
                        Text(m.displayName).tag(m.rawValue)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 320)
                Spacer()
            }

            HStack {
                Text("API key:")
                SecureField("sk-ant-...", text: $claudeAPIKeyInput)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: claudeAPIKeyInput) { _, _ in
                        claudeAPIKeySaved = false
                    }
                Button(claudeAPIKeySaved ? "Saved" : "Save") {
                    _ = KeychainHelper.set(claudeAPIKeyInput, for: AnthropicProvider.keychainKey)
                    claudeAPIKeySaved = true
                }
                .disabled(claudeAPIKeyInput.isEmpty)
                Button("Clear") {
                    _ = KeychainHelper.set("", for: AnthropicProvider.keychainKey)
                    claudeAPIKeyInput = ""
                    claudeAPIKeySaved = false
                }
                .disabled(claudeAPIKeyInput.isEmpty && !claudeAPIKeySaved)
            }

            Text("Cost is shown after each answer. Prompt caching is on, so follow-up questions in the same session are cheaper.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}
```

- [ ] **Step 2: Force the backend default to `.claudeAPI` for existing installs**

In `Casper/AppState.swift`, the `meetingQABackend` `@AppStorage` default is already `claudeAPI` (per current code), so existing installs that have `local` saved will keep using `local`. Override on app launch to fix this — add this to `AppState.init` (or wherever first-launch migrations live; if there's no such hook, add it at the top of `setupMeetingTranscriptController`):

```swift
// Migration: agentic Q&A doesn't support local backend. Force Claude API.
if meetingQABackend == QABackendKind.local.rawValue {
    meetingQABackend = QABackendKind.claudeAPI.rawValue
}
```

- [ ] **Step 3: Build and run all tests**

Run: `xcodebuild test -project Casper.xcodeproj -scheme Casper -destination 'platform=macOS' -skipMacroValidation -quiet`

Expected: full test suite passes.

- [ ] **Step 4: Commit**

```bash
git add Casper/UI/SettingsWindow.swift Casper/AppState.swift
git commit -m "feat(qa): provider-picker Settings UI; force-migrate local backend to claudeAPI"
```

---

## Task 15: Cleanup — delete ClaudeAPIClient.swift, drop QABackendKind.local, finalize types

**Files:**
- Delete: `Casper/QA/ClaudeAPIClient.swift`
- Modify: `Casper/QA/QABackendKind.swift` → rename to `LLMProviderKind.swift` content; remove `.local` and old types
- Modify: `Casper/AppState.swift` (drop `.local` switch arm, drop `meetingQAModelKind` storage if unused)
- Modify: `Casper.xcodeproj/project.pbxproj` (remove `ClaudeAPIClient.swift`, rename `QABackendKind.swift` → `LLMProviderKind.swift`)

- [ ] **Step 1: Verify nothing references `ClaudeAPIClient` anywhere except Task-12-replaced lines**

```bash
grep -rn "ClaudeAPIClient" Casper CasperTests
```

Expected: only references inside `Casper/QA/ClaudeAPIClient.swift` itself. If anything else references it, fix that first.

- [ ] **Step 2: Delete the file from disk**

```bash
rm Casper/QA/ClaudeAPIClient.swift
```

- [ ] **Step 3: Reshape `QABackendKind.swift` → `QABackendKind`-shaped types removed**

The file currently contains: `QABackendKind` enum (with `.local`, `.claudeAPI`), `ClaudeAPIModel` enum, and (after Task 7) the file no longer has `QAUsage`/`QAStreamEvent`.

We need to:
- Keep `ClaudeAPIModel` (still used).
- Drop `QABackendKind` entirely (the agent doesn't switch on backend; the new `LLMProviderKind` enum lives in `LLMProvider.swift` with only `.anthropic`).
- Drop the `QAStreamEvent` type completely (the closure now yields `QAEvent`).

Replace `Casper/QA/QABackendKind.swift` content with **only**:

```swift
import Foundation

enum ClaudeAPIModel: String, CaseIterable, Identifiable {
    case opus = "claude-opus-4-7"
    case sonnet = "claude-sonnet-4-6"
    case haiku = "claude-haiku-4-5"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .opus: return "Claude Opus 4.7 (best quality)"
        case .sonnet: return "Claude Sonnet 4.6 (balanced)"
        case .haiku: return "Claude Haiku 4.5 (fastest)"
        }
    }

    var shortDisplayName: String {
        switch self {
        case .opus: return "Opus 4.7"
        case .sonnet: return "Sonnet 4.6"
        case .haiku: return "Haiku 4.5"
        }
    }
}
```

- [ ] **Step 4: Rename the file to `ClaudeAPIModel.swift`**

```bash
git mv Casper/QA/QABackendKind.swift Casper/QA/ClaudeAPIModel.swift
```

- [ ] **Step 5: Drop `QABackendKind` references in `AppState.swift`**

```bash
grep -n "QABackendKind\|meetingQABackend\|meetingQAModelKind" Casper/AppState.swift
```

For each match:
- Remove the `@AppStorage("meetingQABackend") var meetingQABackend: String = ...` line entirely (if it was only used for the Q&A path).
- Remove the migration code added in Task 14, Step 2 (no longer needed — `QABackendKind.local` doesn't exist).
- Remove the `switch backend { case .claudeAPI: ... case .local: ... }` (around line 1037 after Task 13 edits) and inline only the `.claudeAPI` arm.
- Remove `@AppStorage("meetingQAModelKind") var meetingQAModelKind: ...` if it's only used for the dropped local Q&A path.

Final closure body (cleaning up Task 13's version):

```swift
controller.onAskQuestion = { [weak self] question in
    AsyncThrowingStream { continuation in
        guard let self else {
            continuation.finish()
            return
        }
        guard let key = KeychainHelper.get(AnthropicProvider.keychainKey), !key.isEmpty else {
            Task { @MainActor in self.showSettings(section: .meetingTranscript) }
            continuation.yield(.error("Add your Claude API key to continue — Settings opened."))
            continuation.finish()
            return
        }
        let model = ClaudeAPIModel(rawValue: self.claudeAPIModel) ?? .sonnet
        let provider = AnthropicProvider(model: model, apiKey: key)
        let archiveRoot = MeetingTranscriptSettings.effectiveSaveDirectory()
        let agent = MeetingQAAgent(provider: provider, model: model, archiveRoot: archiveRoot, maxIterations: 15)
        let task = Task {
            do {
                for try await event in agent.ask(question) {
                    continuation.yield(event)
                }
                continuation.finish()
            } catch {
                self.debugLogStore.record(category: .model, message: "Agentic Q&A error: \(error)")
                continuation.yield(.error("Claude API error: \(error.localizedDescription)"))
                continuation.finish()
            }
        }
        continuation.onTermination = { _ in task.cancel() }
    }
}
```

- [ ] **Step 6: Update pbxproj — remove `ClaudeAPIClient.swift`, rename `QABackendKind.swift` → `ClaudeAPIModel.swift`**

```bash
ruby <<'RUBY'
require 'xcodeproj'

project = Xcodeproj::Project.open('Casper.xcodeproj')

main_target = project.targets.find { |t| t.name == 'Casper' }
abort 'Casper target not found' unless main_target

# Remove ClaudeAPIClient.swift entirely.
removed = []
main_target.source_build_phase.files_references.each do |ref|
  if ref && ref.path == 'ClaudeAPIClient.swift'
    main_target.source_build_phase.remove_file_reference(ref)
    ref.remove_from_project
    removed << 'ClaudeAPIClient.swift'
  end
end

# Rename QABackendKind.swift -> ClaudeAPIModel.swift in references.
project.files.each do |ref|
  if ref.path == 'QABackendKind.swift'
    ref.path = 'ClaudeAPIModel.swift'
    ref.name = 'ClaudeAPIModel.swift'
    removed << 'renamed QABackendKind.swift -> ClaudeAPIModel.swift'
  end
end

project.save
puts "Done: #{removed.inspect}"
RUBY
```

- [ ] **Step 7: Build and run all tests**

Run: `xcodebuild test -project Casper.xcodeproj -scheme Casper -destination 'platform=macOS' -skipMacroValidation -quiet`

Expected: full test suite passes. Any reference to dropped types (e.g., `QABackendKind`, `QAStreamEvent`) surfaces as a compile error and must be fixed inline.

- [ ] **Step 8: Commit**

```bash
git add -A Casper CasperTests Casper.xcodeproj/project.pbxproj
git commit -m "refactor(qa): remove ClaudeAPIClient and QABackendKind; agentic flow only"
```

---

## Task 16: End-to-end manual verification

**Files:** none modified — this is a manual smoke test.

- [ ] **Step 1: Build and install the debug build**

```bash
xcodebuild build -project Casper.xcodeproj -scheme Casper -derivedDataPath build/derived -skipMacroValidation -quiet
cp -R build/derived/Build/Products/Debug/Casper.app /Applications/
open /Applications/Casper.app
```

- [ ] **Step 2: Configure the meeting archive**

In Settings → Meeting Transcript → Save directory, choose `/Users/matthewhartman/Projects/granolatest/Casper Meetings/`.

In Settings → Meeting Transcript → Cross-Meeting Q&A, confirm Provider is "Anthropic", Model is "Claude Sonnet 4.6", and the API key is saved.

- [ ] **Step 3: Verification Test 1 — Timeline**

Open the meeting window. In the Q&A bar at the top, ask:

> Give me a quick timeline of my meetings with Quinn.

**Pass criteria:**
- Status line cycles through `Searching: pattern="Quinn"...` → `Reading <file>...` (one or more times) → `Thinking...`.
- Final answer chronologically lists three files: `2025-01-29/dana-matt.md`, `2025-05-19/team-standup.md`, `2026-01-07/team-standup.md`.
- Each entry has a `path:line` citation.
- Answer mentions Quinn is mentioned but never an attendee.
- Cost footer appears at the bottom.

If the answer cites different files: open the trace, confirm grep matched what was expected. If grep missed a file, the system prompt or tool definitions need adjustment.

- [ ] **Step 4: Verification Test 2 — Single-meeting summary**

Ask:

> Tell me about the Dana-Matt meeting.

**Pass criteria:**
- Trace shows at least one `read_file` call into `2025-01-29/dana-matt.md`.
- Final answer covers ≥ 3 substantive topics with `path:start-end` citations.
- Bonus pass: answer notes the title is "Dana <> Matt" but the speaker is later addressed as "Robin".

- [ ] **Step 5: Verification Test 3 — Multi-hop with voice-to-text artifact**

Ask:

> Does Quinn know Sam Rivers?

**Pass criteria:**
- Trace shows `grep("Sam Rivers")` and a `read_file` into `2026-01-07/team-standup.md` covering line ~184.
- Final answer correctly interprets "He's not a Quinn Adler for 10 years" as "He's known Quinn for ~10 years."
- Answer explicitly flags the voice-to-text artifact ("the transcript reads X, which I read as Y").

If this fails: the system prompt's "Voice-to-text reasoning" section needs a sharper directive or more concrete example. Edit `MeetingQASystemPrompt.swift`, re-run the test. Do not weaken pass criteria.

- [ ] **Step 6: Verification — Stop button**

Submit any question. While the agent is running (status line visible), click "Stop". Expect:
- Status line shows `Stopped` briefly.
- No further events arrive.
- The bar returns to idle (input field re-enabled, no spinner).

- [ ] **Step 7: Verification — Iteration cap behavior**

Submit a deliberately vague question that may run long, e.g.:

> List every meeting where I discussed pricing with anyone, what they said, and what I said.

If the agent hits 15 iterations: status line should show `Hit iteration cap of 15`, and whatever partial text streamed before the cap stays visible. The trace shows the last 15 tool calls.

- [ ] **Step 8: Verification — Missing API key flow**

In Settings → Meeting Transcript → Cross-Meeting Q&A, click "Clear" on the API key. Submit any question. Expect:
- Settings window opens to the Meeting Transcript section.
- Q&A bar shows: "Add your Claude API key to continue — Settings opened."
- No question runs.

Re-enter and save the key, retry the question — expect normal behavior.

- [ ] **Step 9: If all eight verifications pass, commit a marker**

```bash
git commit --allow-empty -m "verify: agentic meeting Q&A passes timeline, summary, multi-hop, and Stop tests"
```

---

## Self-review notes

The plan covers each section of the spec:

- **Architecture / data flow** → Tasks 8 (LLMProvider), 11 (MeetingQAAgent loop), 13 (UI), 12+15 (AppState wiring).
- **Components — new files** → Tasks 1–11 (one per file with TDD where applicable).
- **Components — modified files** → Tasks 12 (AppState), 13 (MeetingTranscriptWindow), 14 (SettingsWindow).
- **Deleted file** → Task 15 (ClaudeAPIClient.swift).
- **Renamed file** → Task 15 (QABackendKind.swift → ClaudeAPIModel.swift).
- **pbxproj** → Tasks 1 (add new files), 15 (remove + rename).
- **Tool definitions (grep/read_file/list_dir + PathSandbox)** → Tasks 2–5; tool JSON schemas in Task 11 (`buildToolDefinitions`).
- **System prompt with both file formats and voice-to-text guidance** → Task 6.
- **Provider abstraction (`LLMProvider` + `AnthropicProvider` + SSE accumulator + stop-reason branching)** → Tasks 8, 9, 10.
- **UI — status line + expandable trace + Stop button** → Task 13.
- **Settings — provider picker + drop local row** → Task 14.
- **Error handling matrix (missing key, HTTP error, cancellation, tool error, iteration cap, empty answer, stream error)** → Task 11 (agent), Task 12/13/15 (AppState wiring), Task 16 (manual verification).
- **No-silent-truncation contract** → Tasks 3 (grep cap message), 4 (read_file pagination footer).
- **Verification queries** → Task 16.

No placeholders. No "implement later". Type names match across tasks (e.g., `MeetingQATools` defined in Task 3 is the same as referenced in Task 11; `LLMProvider` defined in Task 8 is the same as used in Task 10/11; `QAEvent` defined in Task 7 is the same as consumed in Task 13).
