import Foundation

/// Represents a raw user action or system event captured by the passive monitor.
enum DesktopUserEvent: Sendable, Codable {
    case appActivated(appName: String, bundleID: String, windowTitle: String)
    case windowTitleChanged(appName: String, windowTitle: String)
    case textCopied(text: String)
    case screenOcrCaptured(text: String)
    case commandExecuted(command: String, exitCode: Int, output: String?)
    case customInput(prompt: String)
    case mouseClicked(appName: String, elementClicked: String)
    case appStalled(appName: String, durationSeconds: Double)
    case userHesitated(appName: String, durationSeconds: Double)
    case typingSession(appName: String, typedText: String, durationSeconds: Double)
}

/// Represents the accumulated real-time state of the user's workspace.
struct DesktopWorkspaceContext: Sendable, Codable {
    var activeAppName: String = ""
    var activeBundleID: String = ""
    var activeWindowTitle: String = ""
    var lastCopiedText: String? = nil
    var lastOcrText: String? = nil
    var lastCommand: String? = nil
    var lastCommandOutput: String? = nil
    var activeGoal: String? = nil
}

/// Represents an action recommended by the local model that can be run "just-in-time".
struct DesktopAgentRecommendation: Sendable, Identifiable, Codable {
    var id = UUID()
    let title: String
    let description: String
    let actionType: ActionType
    let suggestedContent: String

    enum ActionType: String, Sendable, Codable {
        case pasteText          // Pastes the suggestedContent into the focused field
        case runTerminalCommand // Proposes running a shell command
        case createNotes        // Creates a new markdown note/summary
        case showUIOverlay      // Shows a custom helper prompt
    }
}

/// A flexible bridge that receives workspace events and coordinates with a local
/// LLM provider to plan, filter, and recommend actions.
final class DesktopAgentBridge: ObservableObject {
    @Published var context = DesktopWorkspaceContext()
    @Published var recommendations: [DesktopAgentRecommendation] = []
    @Published var isEvaluating = false

    private let provider: LLMProvider
    private let backend: AgentBackend
    
    init(provider: LLMProvider, backend: AgentBackend) {
        self.provider = provider
        self.backend = backend
    }

    /// Feeds a new event into the workspace context and determines if we should evaluate.
    func handleEvent(_ event: DesktopUserEvent) async {
        switch event {
        case .appActivated(let name, let bundleID, let title):
            context.activeAppName = name
            context.activeBundleID = bundleID
            context.activeWindowTitle = title
        case .windowTitleChanged(let name, let title):
            if context.activeAppName == name {
                context.activeWindowTitle = title
            }
        case .textCopied(let text):
            context.lastCopiedText = text
        case .screenOcrCaptured(let text):
            context.lastOcrText = text
        case .commandExecuted(let cmd, _, let output):
            context.lastCommand = cmd
            context.lastCommandOutput = output
        case .customInput(let prompt):
            context.activeGoal = prompt
        case .mouseClicked, .appStalled, .userHesitated, .typingSession:
            break
        }

        // Undergo evaluation if context warrants a JIT action
        if shouldEvaluate(for: event) {
            await evaluateJITRecommendations()
        }
    }

    /// Heuristic filter to avoid running the local LLM on every minor event (e.g. cursor movement).
    private func shouldEvaluate(for event: DesktopUserEvent) -> Bool {
        switch event {
        case .textCopied:
            return true // Always evaluate copy events for smart clipboard actions
        case .commandExecuted(let cmd, let exitCode, _):
            // Evaluate if a terminal command failed (exit code != 0)
            return exitCode != 0
        case .customInput:
            return true // Evaluate explicit user goal queries
        case .appActivated, .windowTitleChanged:
            // Evaluate if switching to developer/productivity tools
            let lowerTitle = context.activeWindowTitle.lowercased()
            return lowerTitle.contains("error") || lowerTitle.contains("issue") || lowerTitle.contains("pr")
        case .screenOcrCaptured, .mouseClicked, .appStalled, .userHesitated, .typingSession:
            return false // Periodical/user clicks shouldn't auto-evaluate unless requested
        }
    }

    /// Formulates a prompt using the current workspace context and queries the local LLM.
    func evaluateJITRecommendations() async {
        guard !isEvaluating else { return }
        isEvaluating = true
        defer { isEvaluating = false }

        let systemPrompt = """
        You are Casper's local Desktop Helper. You passively monitor the user's workspace context to suggest useful, non-intrusive "Just-in-Time" actions.
        Format your suggestion as a JSON array of recommendations:
        [
          {
            "title": "Short title",
            "description": "Short explanation",
            "actionType": "pasteText" | "runTerminalCommand" | "createNotes" | "showUIOverlay",
            "suggestedContent": "content here"
          }
        ]
        Suggest actions ONLY if they would save the user time (e.g. proposing a git commit format, fixing a terminal error, extracting info from OCR). If no action is needed, return an empty array [].
        """

        let userMessage = """
        Active App: \(context.activeAppName) (\(context.activeBundleID))
        Active Window: \(context.activeWindowTitle)
        Last Copied: \(context.lastCopiedText ?? "None")
        Last OCR Snapshot: \(context.lastOcrText ?? "None")
        Last Command: \(context.lastCommand ?? "None") (Output: \(context.lastCommandOutput ?? "None"))
        Current Goal: \(context.activeGoal ?? "None")
        """

        var assistantText = ""
        do {
            let stream = provider.complete(
                system: systemPrompt,
                messages: [LLMMessage(role: .user, content: [.text(userMessage)])],
                tools: []
            )

            for try await event in stream {
                if case .textDelta(let text) = event {
                    assistantText += text
                }
            }

            if let data = assistantText.data(using: .utf8) {
                let decoded = try JSONDecoder().decode([DesktopAgentRecommendation].self, from: data)
                await MainActor.run {
                    self.recommendations = decoded
                }
            }
        } catch {
            print("Desktop agent evaluation failed: \(error.localizedDescription)")
        }
    }
}
