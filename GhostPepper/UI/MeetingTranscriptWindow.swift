import AppKit
import Combine
import SwiftUI
import os.log

enum MeetingTranscriptWindowPresentation {
    static func windowLevel(
        shouldFloatWhileRecording: Bool,
        hasActiveRecording: Bool
    ) -> NSWindow.Level {
        shouldFloatWhileRecording && hasActiveRecording ? .floating : .normal
    }
}

// MARK: - Window Controller

@MainActor
final class MeetingTranscriptWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    var onOpenSettings: (() -> Void)?
    var onStartRecording: ((_ name: String, _ detectedMeeting: DetectedMeeting?) -> MeetingSession?)?
    var onStopRecording: ((MeetingSession) -> Void)?
    var onGenerateSummary: ((MeetingTranscript) -> Void)?
    var onAskQuestion: ((_ question: String) -> AsyncThrowingStream<QAEvent, Error>)?
    var shouldFloatWhileRecording: () -> Bool = { false }

    private(set) var windowState: MeetingWindowState?

    func show(session: MeetingSession? = nil) {
        if let window = window {
            // Add session as a tab if provided
            if let session = session, let state = windowState {
                state.addRecordingTab(session: session)
            }
            updateWindowLevel()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let state = MeetingWindowState()
        state.onOpenSettings = onOpenSettings
        state.onStartRecording = onStartRecording
        state.onStopRecording = onStopRecording
        state.onGenerateSummary = onGenerateSummary
        state.onAskQuestion = onAskQuestion
        state.onRecordingStateChanged = { [weak self] in
            self?.updateWindowLevel()
        }
        windowState = state

        if let session = session {
            state.addRecordingTab(session: session)
        }

        let view = MeetingRootView(state: state)

        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 720, height: 900)
        let windowHeight = screenFrame.height
        let windowWidth: CGFloat = 720

        let window = NSWindow(
            contentRect: NSRect(x: screenFrame.midX - windowWidth / 2, y: screenFrame.minY, width: windowWidth, height: windowHeight),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = .textBackgroundColor
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 500, height: 400)
        window.contentViewController = NSHostingController(rootView: view)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.hidesOnDeactivate = false
        NSApp.setActivationPolicy(.regular)
        window.setFrame(NSRect(x: screenFrame.midX - windowWidth / 2, y: screenFrame.minY, width: windowWidth, height: windowHeight), display: true)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
        updateWindowLevel()
    }

    func close() {
        guard let window = window else { return }
        window.orderOut(nil)
        self.window = nil
        windowState?.onRecordingStateChanged = nil
        windowState = nil
        NSApp.setActivationPolicy(.accessory)
    }

    /// Request a recording — shows consent dialog first (or starts immediately if user opted out).
    func requestRecording(name: String, skipConsent: Bool = false, sourceURL: String? = nil, detectedMeeting: DetectedMeeting? = nil) {
        guard let state = windowState else { return }
        state.pendingSourceURL = sourceURL
        state.pendingDetectedMeeting = detectedMeeting
        if skipConsent || UserDefaults.standard.bool(forKey: "skipConsentDialog") {
            guard let session = state.onStartRecording?(name, detectedMeeting) else { return }
            state.addRecordingTab(session: session)
            // Add URL to notes if provided
            if let url = sourceURL {
                session.transcript.notes = "Source: \(url)\n\n"
            }
            state.pendingSourceURL = nil
            state.pendingDetectedMeeting = nil
        } else {
            state.pendingRecordingName = name
            state.showConsentDialog = true
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)
        return false
    }

    func refreshPresentation() {
        updateWindowLevel()
    }

    private func updateWindowLevel() {
        guard let window, let windowState else { return }
        window.level = MeetingTranscriptWindowPresentation.windowLevel(
            shouldFloatWhileRecording: shouldFloatWhileRecording(),
            hasActiveRecording: windowState.hasActiveRecording
        )
    }
}

// MARK: - Tab Model

@MainActor
final class OpenMeetingTab: ObservableObject, Identifiable {
    let id = UUID()
    @Published var transcript: MeetingTranscript
    @Published var fileURL: URL?
    @Published var isRecording = false
    var session: MeetingSession? // nil = loaded from disk
    private var sessionObserver: Any?
    private let onRecordingStateChanged: (() -> Void)?

    private var fileURLObserver: Any?

    init(
        transcript: MeetingTranscript,
        fileURL: URL? = nil,
        session: MeetingSession? = nil,
        onRecordingStateChanged: (() -> Void)? = nil
    ) {
        self.transcript = transcript
        self.fileURL = fileURL
        self.session = session
        self.onRecordingStateChanged = onRecordingStateChanged
        if let session = session {
            isRecording = session.isActive
            sessionObserver = session.$isActive.sink { [weak self] active in
                self?.isRecording = active
                self?.onRecordingStateChanged?()
            }
            // Sync fileURL from session when it gets created
            fileURLObserver = session.$fileURL.sink { [weak self] url in
                if let url = url {
                    self?.fileURL = url
                }
            }
        }
    }
}

// MARK: - Window State

enum MeetingSurface: Equatable {
    case home
    case tab(UUID)
}

@MainActor
final class MeetingWindowState: ObservableObject {
    var onAskQuestion: ((_ question: String) -> AsyncThrowingStream<QAEvent, Error>)?
    @Published var tabs: [OpenMeetingTab] = []
    @Published var selectedSurface: MeetingSurface = .home
    @Published var showSidebar = true
    @Published var historyGroups: [(date: String, entries: [MeetingHistoryEntry])] = []
    @Published var showConsentDialog = false
    var pendingRecordingName: String?
    var pendingSourceURL: String?
    var pendingDetectedMeeting: DetectedMeeting?
    var pendingCalendarEvent: CalendarEvent?
    var onRecordingStateChanged: (() -> Void)?

    var onOpenSettings: (() -> Void)?
    var onStartRecording: ((_ name: String, _ detectedMeeting: DetectedMeeting?) -> MeetingSession?)?
    var onStopRecording: ((MeetingSession) -> Void)?
    var onGenerateSummary: ((MeetingTranscript) -> Void)?

    var activeTabID: UUID? {
        if case let .tab(id) = selectedSurface { return id }
        return nil
    }

    var activeTab: OpenMeetingTab? {
        guard let id = activeTabID else { return nil }
        return tabs.first { $0.id == id }
    }

    var hasActiveRecording: Bool {
        tabs.contains { $0.isRecording }
    }

    func selectHome() {
        selectedSurface = .home
    }

    func selectTab(_ id: UUID) {
        selectedSurface = .tab(id)
    }

    func addRecordingTab(session: MeetingSession) {
        let tab = OpenMeetingTab(
            transcript: session.transcript,
            fileURL: session.fileURL,
            session: session,
            onRecordingStateChanged: { [weak self] in
                self?.onRecordingStateChanged?()
            }
        )
        tabs.append(tab)
        selectedSurface = .tab(tab.id)
        onRecordingStateChanged?()
    }

    func openFile(_ url: URL) {
        // Already open? Switch to it.
        if let existing = tabs.first(where: { $0.fileURL == url }) {
            selectedSurface = .tab(existing.id)
            return
        }

        // Parse and open in new tab
        do {
            let transcript = try MeetingMarkdownWriter.parse(from: url)
            let tab = OpenMeetingTab(transcript: transcript, fileURL: url)
            tabs.append(tab)
            selectedSurface = .tab(tab.id)
            onRecordingStateChanged?()
        } catch {
            print("MeetingWindowState: failed to load \(url.lastPathComponent): \(error)")
        }
    }

    func closeTab(_ tabID: UUID) {
        // Stop recording if this is a live tab
        if let tab = tabs.first(where: { $0.id == tabID }), let session = tab.session {
            onStopRecording?(session)
        }

        tabs.removeAll { $0.id == tabID }
        onRecordingStateChanged?()

        // If the closed tab was active, fall back to last remaining tab, else Home.
        if case .tab(let activeID) = selectedSurface, activeID == tabID {
            if let last = tabs.last {
                selectedSurface = .tab(last.id)
            } else {
                selectedSurface = .home
            }
        }
    }

    func startNewNote() {
        startWithGeneratedName(prefix: "Quick Note")
    }

    func startAdHocCall() {
        startWithGeneratedName(prefix: "Ad Hoc Call")
    }

    private func startWithGeneratedName(prefix: String) {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        let name = "\(prefix) — \(formatter.string(from: Date()))"

        if UserDefaults.standard.bool(forKey: "skipConsentDialog") {
            guard let session = onStartRecording?(name, nil) else { return }
            addRecordingTab(session: session)
        } else {
            pendingRecordingName = name
            showConsentDialog = true
        }
    }

    func startCalendarMeeting(_ event: CalendarEvent) {
        if UserDefaults.standard.bool(forKey: "skipConsentDialog") {
            guard let session = onStartRecording?(event.title, nil) else { return }
            session.applyCalendarEvent(event)
            addRecordingTab(session: session)
            openMeetingLink(for: event)
        } else {
            pendingRecordingName = event.title
            pendingCalendarEvent = event
            showConsentDialog = true
        }
    }

    private func openMeetingLink(for event: CalendarEvent) {
        guard let link = event.meetLink, let url = URL(string: link) else { return }
        NSWorkspace.shared.open(url)
    }

    func confirmRecording() {
        showConsentDialog = false
        guard let name = pendingRecordingName else { return }
        let url = pendingSourceURL
        let detectedMeeting = pendingDetectedMeeting
        let calendarEvent = pendingCalendarEvent
        pendingRecordingName = nil
        pendingSourceURL = nil
        pendingDetectedMeeting = nil
        pendingCalendarEvent = nil
        guard let session = onStartRecording?(name, detectedMeeting) else { return }
        if let calendarEvent = calendarEvent {
            session.applyCalendarEvent(calendarEvent)
        }
        if let url = url {
            session.transcript.notes = "Source: \(url)\n\n"
        }
        addRecordingTab(session: session)
        if let calendarEvent = calendarEvent {
            openMeetingLink(for: calendarEvent)
        }
    }

    func cancelRecording() {
        showConsentDialog = false
        pendingRecordingName = nil
        pendingSourceURL = nil
        pendingDetectedMeeting = nil
    }

    func loadHistory() {
        let dir = MeetingTranscriptSettings.effectiveSaveDirectory()
        historyGroups = MeetingHistory.loadEntries(from: dir)
    }

    func renameActiveTab() {
        guard let tab = activeTab, let oldURL = tab.fileURL else { return }
        let newSlug = MeetingMarkdownWriter.slugify(tab.transcript.meetingName)
        let dir = oldURL.deletingLastPathComponent()
        let newURL = dir.appendingPathComponent(newSlug + ".md")

        // Don't rename if slug didn't change or target already exists
        guard newURL != oldURL, !FileManager.default.fileExists(atPath: newURL.path) else {
            saveActiveTab()
            return
        }

        do {
            try FileManager.default.moveItem(at: oldURL, to: newURL)
            tab.fileURL = newURL
            // Also update the session's fileURL so auto-save goes to the new path
            if let session = tab.session {
                session.fileURL = newURL
            }
            saveActiveTab()
            print("Renamed \(oldURL.lastPathComponent) → \(newURL.lastPathComponent)")
        } catch {
            print("Failed to rename: \(error)")
            saveActiveTab() // Still save content even if rename fails
        }
    }

    func saveActiveTab() {
        guard let tab = activeTab, let url = tab.fileURL else { return }
        let markdown = MeetingMarkdownWriter.renderMarkdown(transcript: tab.transcript)
        try? markdown.write(to: url, atomically: true, encoding: .utf8)
    }
}

// MARK: - Root View

struct MeetingRootView: View {
    @ObservedObject var state: MeetingWindowState
    @State private var sidebarWidth: CGFloat = 220
    @State private var qaQuestion = ""
    @State private var qaAnswer = ""
    @State private var qaIsLoading = false
    @State private var qaUsage: QAUsage?
    @State private var qaStatusLine: String = ""
    @State private var qaTraceExpanded: Bool = false
    @StateObject private var qaTranscript: QATranscript = QATranscript()
    @State private var currentQATask: Task<Void, Never>? = nil

    var body: some View {
        VStack(spacing: 0) {
        HStack(spacing: 0) {
            if state.showSidebar {
                MeetingSidebarView(state: state)
                    .frame(width: sidebarWidth)
                    .transition(.move(edge: .leading))

                // Draggable divider
                Rectangle()
                    .fill(Color(nsColor: .separatorColor))
                    .frame(width: 3)
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        if hovering {
                            NSCursor.resizeLeftRight.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                let newWidth = sidebarWidth + value.translation.width
                                sidebarWidth = max(160, min(400, newWidth))
                            }
                    )
            }

            VStack(spacing: 0) {
                // File tabs (always show — includes "+" tab)
                fileTabBar

                // Active tab content or new tab view
                switch state.selectedSurface {
                case .home:
                    newTabView
                case .tab:
                    if let tab = state.activeTab {
                        MeetingTabContentView(tab: tab, state: state)
                    } else {
                        newTabView
                    }
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
        }

        // App-level Q&A bar
        appQABar
        }
        .frame(minWidth: 500, minHeight: 400)
        .animation(.easeInOut(duration: 0.2), value: state.showSidebar)
        .onAppear { state.loadHistory() }
        .onChange(of: state.showSidebar) { _, visible in
            if visible { state.loadHistory() }
        }
        .onReceive(Timer.publish(every: 10, on: .main, in: .common).autoconnect()) { _ in
            if state.showSidebar { state.loadHistory() }
        }
        .sheet(isPresented: $state.showConsentDialog) {
            ConsentDialogView(state: state)
        }
    }

    // MARK: - App-Level Q&A

    private var appQABar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Status line + trace toggle + Stop button
            if qaIsLoading || !qaTranscript.events.isEmpty {
                Divider()
                HStack(spacing: 6) {
                    if qaIsLoading {
                        ProgressView().scaleEffect(0.5)
                    }
                    Text(qaStatusLine.isEmpty ? "" : qaStatusLine)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    if let usage = qaUsage {
                        Text(runningCostText(usage))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .help("\(usage.inputTokens) in / \(usage.outputTokens) out · \(usage.cacheReadTokens) cache read / \(usage.cacheWriteTokens) cache write")
                    }
                    if !qaTranscript.events.isEmpty {
                        Button(action: { qaTraceExpanded.toggle() }) {
                            Label(qaTraceExpanded ? "Hide trace" : "Show trace", systemImage: qaTraceExpanded ? "chevron.down" : "chevron.right")
                                .font(.system(size: 11))
                                .labelStyle(.titleAndIcon)
                        }
                        .buttonStyle(.borderless)
                    }
                    if qaIsLoading {
                        Button("Stop") {
                            currentQATask?.cancel()
                        }
                        .buttonStyle(.borderless)
                        .font(.system(size: 11))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
            }

            // Expandable trace
            if qaTraceExpanded {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
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
                .padding(.horizontal, 16)
                .padding(.bottom, 6)
            }

            // Streaming answer
            if !qaAnswer.isEmpty {
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(qaAnswer)
                            .font(.system(size: 13))
                            .textSelection(.enabled)
                        if let usage = qaUsage {
                            Text(usageFooterText(usage))
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .padding(.top, 2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
                .frame(maxHeight: 240)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.3))
            }

            // Input row (mostly unchanged)
            Divider()
            HStack(spacing: 8) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                TextField("Run agent across meeting data...", text: $qaQuestion)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .onSubmit { askAcrossMeetings() }
                    .disabled(qaIsLoading)
                if qaIsLoading {
                    ProgressView().scaleEffect(0.6)
                } else if !qaQuestion.isEmpty {
                    Button(action: { askAcrossMeetings() }) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 16))
                            .foregroundColor(.orange)
                    }
                    .buttonStyle(.plain)
                }
                if !qaAnswer.isEmpty || !qaTranscript.events.isEmpty {
                    Button(action: {
                        qaAnswer = ""
                        qaQuestion = ""
                        qaUsage = nil
                        qaStatusLine = ""
                        qaTranscript.clear()
                        qaTraceExpanded = false
                    }) {
                        Image(systemName: "xmark.circle")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    private func usageFooterText(_ u: QAUsage) -> String {
        let nf = NumberFormatter()
        nf.numberStyle = .decimal
        let fmtIn = nf.string(from: NSNumber(value: u.inputTokens)) ?? "\(u.inputTokens)"
        let fmtOut = nf.string(from: NSNumber(value: u.outputTokens)) ?? "\(u.outputTokens)"
        if u.isLocal {
            return "\(u.modelDisplayName) · ~\(fmtIn) in / ~\(fmtOut) out · free"
        }
        var inputPart = "\(fmtIn) in"
        if u.cacheReadTokens > 0 {
            let fmtCache = nf.string(from: NSNumber(value: u.cacheReadTokens)) ?? "\(u.cacheReadTokens)"
            inputPart += " (\(fmtCache) cached)"
        }
        if u.cacheWriteTokens > 0 {
            let fmtWrite = nf.string(from: NSNumber(value: u.cacheWriteTokens)) ?? "\(u.cacheWriteTokens)"
            inputPart += " (+\(fmtWrite) cache write)"
        }
        let cost = String(format: "$%.4f", u.estimatedCostUSD)
        return "\(u.modelDisplayName) · \(inputPart) / \(fmtOut) out · ~\(cost)"
    }

    private func runningCostText(_ u: QAUsage) -> String {
        if u.isLocal { return "free" }
        return String(format: "~$%.4f", u.estimatedCostUSD)
    }

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

    private func formatToolStatusLine(name: String, summary: String) -> String {
        switch name {
        case "grep": return "Searching: \(summary)"
        case "read_file": return "Reading \(summary)"
        case "list_dir": return "Listing \(summary)"
        default: return "\(name): \(summary)"
        }
    }

    private func askAcrossMeetings() {
        let question = qaQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !qaIsLoading else { return }
        qaIsLoading = true
        qaAnswer = ""
        qaUsage = nil
        qaStatusLine = ""
        qaTranscript.clear()
        qaTraceExpanded = false

        guard let stream = state.onAskQuestion?(question) else {
            qaAnswer = "Could not answer — open Settings → Meeting Transcript → Cross-Meeting Q&A to configure."
            qaIsLoading = false
            return
        }

        currentQATask = Task { @MainActor in
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
                if qaAnswer.isEmpty && qaTranscript.events.isEmpty == false {
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

    // MARK: - File Tab Bar

    private var fileTabBar: some View {
        HStack(spacing: 0) {
            Button(action: { state.showSidebar.toggle() }) {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(state.showSidebar ? .orange : .secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
            }
            .buttonStyle(.plain)
            .help(state.showSidebar ? "Hide sidebar" : "Show sidebar")

            Rectangle()
                .fill(Color(nsColor: .separatorColor).opacity(0.7))
                .frame(width: 1, height: 18)
                .padding(.trailing, 4)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    HomeTabView(isActive: state.selectedSurface == .home) {
                        state.saveActiveTab()
                        state.selectHome()
                    }

                    ForEach(state.tabs) { tab in
                        FileTabView(tab: tab, isActive: state.activeTabID == tab.id) {
                            state.saveActiveTab()
                            state.selectTab(tab.id)
                        } onClose: {
                            state.closeTab(tab.id)
                        }
                    }

                    Menu {
                        Button {
                            state.startNewNote()
                        } label: {
                            Label("New personal note", systemImage: "note.text")
                        }
                        Button {
                            state.startAdHocCall()
                        } label: {
                            Label("New ad hoc meeting", systemImage: "waveform")
                        }
                        if GranolaImporter.isCacheAvailable {
                            Divider()
                            Button {
                                showGranolaImport = true
                            } label: {
                                Label("Import from Granola…", systemImage: "tray.and.arrow.down")
                            }
                        }
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1)
        }
    }

    // MARK: - Empty State

    @StateObject private var granolaImporter = GranolaImporter()
    @State private var showGranolaImport = false
    @State private var todayEvents: [CalendarEvent] = []
    @State private var todayEventsLoaded = false
    @State private var todayEventsError: String?
    @State private var whitelistEmail: String = ""
    @State private var granolaPendingCount: Int? = nil

    private var newTabView: some View {
        VStack(spacing: 24) {
            if !GoogleCalendarService.shared.isSignedIn {
                disconnectedQuickActions
                    .padding(.top, 40)
            }

            if GranolaImporter.isCacheAvailable {
                granolaSyncRow
                    .padding(.top, GoogleCalendarService.shared.isSignedIn ? 40 : 0)
            }

            todayCalendarSection
                .padding(.top, (GoogleCalendarService.shared.isSignedIn && !GranolaImporter.isCacheAvailable) ? 40 : 0)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showGranolaImport, onDismiss: { refreshGranolaPendingCount() }) {
            GranolaImportView(importer: granolaImporter, state: state)
        }
        .task {
            await loadTodayEvents()
            refreshGranolaPendingCount()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await loadTodayEvents() }
            refreshGranolaPendingCount()
        }
        .onReceive(NotificationCenter.default.publisher(for: .meetingRecordingStopped)) { _ in
            GoogleCalendarService.shared.invalidateTodayCache()
            Task { await loadTodayEvents() }
        }
    }

    private var granolaSyncRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            if let pending = granolaPendingCount, pending > 0 {
                Button {
                    showGranolaImport = true
                } label: {
                    HStack(spacing: 6) {
                        Text("Sync \(pending) new from Granola")
                            .font(.system(size: 12, weight: .medium))
                        Image(systemName: "arrow.right")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.orange))
                    .foregroundColor(.white)
                }
                .buttonStyle(.plain)
            } else if granolaPendingCount == 0 {
                Text("Granola up to date")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Button {
                    showGranolaImport = true
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Sync with Granola")
            } else {
                Text("Checking Granola…")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .frame(maxWidth: 560)
        .padding(.horizontal, 24)
    }

    private func refreshGranolaPendingCount() {
        let dir = MeetingTranscriptSettings.effectiveSaveDirectory()
        Task.detached(priority: .background) {
            let count = await GranolaImporter.pendingImportCount(savedTo: dir)
            await MainActor.run {
                self.granolaPendingCount = count
            }
        }
    }

    private var disconnectedQuickActions: some View {
        HStack(spacing: 12) {
            Button("New Personal Note") {
                state.startNewNote()
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)

            Button("New Ad Hoc Meeting") {
                state.startAdHocCall()
            }
            .buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    private var todayCalendarSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "calendar")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Text("Today")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)
                Rectangle()
                    .fill(Color(nsColor: .separatorColor))
                    .frame(height: 1)
                if GoogleCalendarService.shared.isSignedIn {
                    Button {
                        GoogleCalendarService.shared.invalidateTodayCache()
                        Task { await loadTodayEvents() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Refresh calendar")
                }
            }
            .padding(.horizontal, 4)

            if !GoogleCalendarService.shared.isSignedIn {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Button("Connect to Calendar") {
                            GoogleCalendarService.shared.signIn()
                        }
                        .buttonStyle(.bordered)
                        Text("BETA")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.orange))
                        Spacer()
                    }

                    Divider()

                    Text("Calendar access is invite-only while in beta. Send Matt your email and he'll allow-list you.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 8) {
                        TextField("you@example.com", text: $whitelistEmail)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12))
                        Button(primaryWhitelistButtonLabel) {
                            sendWhitelistRequest(via: hasReliableMailClient ? .defaultMail : .gmail)
                        }
                        .disabled(!isLikelyEmail(whitelistEmail))
                    }
                    HStack(spacing: 4) {
                        Text(secondaryWhitelistPrompt)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                        Button(secondaryWhitelistButtonLabel) {
                            sendWhitelistRequest(via: hasReliableMailClient ? .gmail : .defaultMail)
                        }
                        .buttonStyle(.link)
                        .font(.system(size: 10))
                        .disabled(!isLikelyEmail(whitelistEmail))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
            } else if !todayEventsLoaded {
                HStack {
                    ProgressView().scaleEffect(0.6)
                    Text("Loading today's events…")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
            } else if todayEvents.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(todayEventsError == nil ? "No events today" : "No events to show")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    if let err = todayEventsError {
                        Text(err)
                            .font(.system(size: 11))
                            .foregroundColor(.red)
                            .textSelection(.enabled)
                    }
                    HStack(spacing: 8) {
                        Button("Refresh") {
                            GoogleCalendarService.shared.invalidateTodayCache()
                            Task { await loadTodayEvents() }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        Button("Disconnect") {
                            GoogleCalendarService.shared.signOut()
                            todayEventsLoaded = false
                            todayEvents = []
                            todayEventsError = nil
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
            } else {
                if let err = todayEventsError {
                    HStack(spacing: 6) {
                        Image(systemName: "wifi.slash")
                            .font(.system(size: 10))
                            .foregroundColor(.orange)
                        Text(err)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                }
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    eventsList(now: context.date)
                }
            }
        }
        .frame(maxWidth: 560)
        .padding(.horizontal, 24)
    }

    @ViewBuilder
    private func eventsList(now: Date) -> some View {
        let timed = todayEvents.filter { !$0.isAllDay && $0.startDate != nil }
        let allDay = todayEvents.filter { $0.isAllDay }

        // Find the "current" event (start ≤ now ≤ end) and the "next-up" event (first future).
        let current = timed.first { e in
            guard let s = e.startDate, let end = e.endDate else { return false }
            return now >= s && now <= end
        }
        let nextUp = timed.first { ($0.startDate ?? .distantFuture) > now }

        // Decide where to insert the now line. Insert it just before the first event whose
        // start is >= now; if all events are in the past, append it at the end.
        let nowLineInsertIndex: Int? = {
            for (i, e) in timed.enumerated() {
                if (e.startDate ?? .distantFuture) >= now { return i }
            }
            return nil // all in past — append at end
        }()

        VStack(spacing: 0) {
            ForEach(allDay) { event in
                CalendarEventRow(event: event, countdownText: nil) {
                    state.startCalendarMeeting(event)
                }
                Divider()
            }

            ForEach(Array(timed.enumerated()), id: \.element.id) { idx, event in
                if nowLineInsertIndex == idx {
                    NowLineView(time: now)
                    Divider()
                }
                let countdown: String? = {
                    if event.id == current?.id { return countdownText(prefix: "ends in", until: event.endDate, now: now) }
                    if event.id == nextUp?.id, current == nil { return countdownText(prefix: "in", until: event.startDate, now: now) }
                    return nil
                }()
                CalendarEventRow(event: event, countdownText: countdown) {
                    state.startCalendarMeeting(event)
                }
                if idx != timed.count - 1 {
                    Divider()
                }
            }

            if nowLineInsertIndex == nil && !timed.isEmpty {
                Divider()
                NowLineView(time: now)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.4))
        .cornerRadius(8)
    }

    private func countdownText(prefix: String, until date: Date?, now: Date) -> String? {
        guard let date else { return nil }
        let seconds = Int(date.timeIntervalSince(now))
        guard seconds > 0 else { return nil }
        let formatted: String
        if seconds < 60 {
            formatted = "<1m"
        } else if seconds < 3600 {
            formatted = "\(seconds / 60)m"
        } else {
            let h = seconds / 3600
            let m = (seconds % 3600) / 60
            formatted = m == 0 ? "\(h)h" : "\(h)h \(m)m"
        }
        return "\(prefix) \(formatted)"
    }

    private func isLikelyEmail(_ s: String) -> Bool {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        guard let at = trimmed.firstIndex(of: "@") else { return false }
        let domain = trimmed[trimmed.index(after: at)...]
        return !domain.isEmpty && domain.contains(".") && trimmed.startIndex < at
    }

    private enum WhitelistTransport {
        case defaultMail
        case gmail
    }

    /// Bundle IDs we trust to actually handle mailto URLs reliably (i.e. real mail
    /// clients with configured accounts in the common case). Apple Mail is intentionally
    /// excluded — it's the system default whether or not the user has ever set up
    /// an account, and we have no way to detect configuration without Full Disk Access.
    /// Browsers are also excluded — they often "handle" mailto by falling back to the
    /// system default mail app, which loops us right back to the Apple Mail problem.
    private static let knownReliableMailClients: Set<String> = [
        "com.readdle.smartemail-Mac",  // Spark
        "it.bloop.airmail",             // Airmail
        "it.bloop.airmail3",
        "com.mimestream.Mimestream",
        "com.microsoft.Outlook",
        "com.flashlightsoft.flashemail", // Newton
        "com.freron.MailMate",
        "com.postbox-inc.postbox",
        "org.mozilla.thunderbird",
        "com.canarymail.macos",         // Canary
        "com.proton.mail",              // Proton Mail desktop
    ]

    /// True iff the system's default mailto handler is in the allow-list.
    /// If false, we route to Gmail web compose instead — which always works and
    /// avoids prompting the user to set up Apple Mail or some browser fallback chain.
    private var hasReliableMailClient: Bool {
        guard let url = URL(string: "mailto:test@example.com"),
              let handler = NSWorkspace.shared.urlForApplication(toOpen: url),
              let bundleID = Bundle(url: handler)?.bundleIdentifier else {
            return false
        }
        return Self.knownReliableMailClients.contains(bundleID)
    }

    private var primaryWhitelistButtonLabel: String {
        hasReliableMailClient ? "Request whitelist" : "Send via Gmail"
    }

    private var secondaryWhitelistPrompt: String {
        hasReliableMailClient ? "Prefer Gmail?" : "Want to use your mail app instead?"
    }

    private var secondaryWhitelistButtonLabel: String {
        hasReliableMailClient ? "Send via Gmail in browser" : "Try default mail app"
    }

    private func sendWhitelistRequest(via transport: WhitelistTransport) {
        let email = whitelistEmail.trimmingCharacters(in: .whitespaces)
        guard isLikelyEmail(email) else { return }
        let to = "ghostpepper@factorial.cc"
        let subject = "Whitelist request for Ghost Pepper"
        let body = "Hey Matt, can you white list my email address for ghost pepper calendar integration: \(email)"
        let allowed = CharacterSet.urlQueryAllowed
        guard let encodedSubject = subject.addingPercentEncoding(withAllowedCharacters: allowed),
              let encodedBody = body.addingPercentEncoding(withAllowedCharacters: allowed) else {
            return
        }
        let urlString: String
        switch transport {
        case .defaultMail:
            urlString = "mailto:\(to)?subject=\(encodedSubject)&body=\(encodedBody)"
        case .gmail:
            urlString = "https://mail.google.com/mail/?view=cm&fs=1&to=\(to)&su=\(encodedSubject)&body=\(encodedBody)"
        }
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    private func loadTodayEvents() async {
        guard GoogleCalendarService.shared.isSignedIn else {
            todayEvents = []
            todayEventsError = nil
            todayEventsLoaded = false
            return
        }
        let result = await GoogleCalendarService.shared.eventsForToday()
        todayEvents = result.events
        todayEventsError = result.errorMessage
        todayEventsLoaded = true
    }
}

private struct NowLineView: View {
    let time: Date

    var body: some View {
        HStack(spacing: 8) {
            Text(timeLabel)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(.orange)
                .frame(width: 70, alignment: .leading)
            Circle()
                .fill(Color.orange)
                .frame(width: 6, height: 6)
            Rectangle()
                .fill(Color.orange)
                .frame(height: 1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    private var timeLabel: String {
        let f = DateFormatter()
        f.timeStyle = .short
        return f.string(from: time)
    }
}

private struct CalendarEventRow: View {
    let event: CalendarEvent
    let countdownText: String?
    let onStart: () -> Void

    private var timeText: String {
        if event.isAllDay { return "All day" }
        guard let start = event.startDate else { return "" }
        let f = DateFormatter()
        f.timeStyle = .short
        return f.string(from: start)
    }

    private var attendeeText: String? {
        guard event.attendeeCount > 0 else { return nil }
        if event.attendeeCount == 1 { return "1 person" }
        return "\(event.attendeeCount) people"
    }

    private var isPast: Bool {
        guard let end = event.endDate else { return false }
        return end < Date()
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(timeText)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 70, alignment: .leading)

            Text(event.title)
                .font(.system(size: 13))
                .foregroundColor(isPast ? .secondary : .primary)
                .lineLimit(1)

            Spacer(minLength: 8)

            if let attendeeText = attendeeText {
                Text(attendeeText)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            if let countdownText {
                Text(countdownText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.orange)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .overlay(
                        Capsule().stroke(Color.orange.opacity(0.4), lineWidth: 1)
                    )
            }

            if !event.isAllDay {
                Button(action: onStart) {
                    HStack(spacing: 4) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 9))
                        Text(event.meetLink != nil ? "Start & Join" : "Start")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .foregroundColor(.orange)
                    .overlay(
                        Capsule().stroke(Color.orange, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

// MARK: - Content View for a Single Tab

// MARK: - File Tab View (observes individual tab)

private struct HomeTabView: View {
    let isActive: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            Image(systemName: isActive ? "house.fill" : "house")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(isActive ? .primary : .secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(isActive ? Color(nsColor: .textBackgroundColor) : Color.clear)
                .overlay(alignment: .bottom) {
                    if isActive {
                        Rectangle().fill(Color.orange).frame(height: 2)
                    }
                }
        }
        .buttonStyle(.plain)
        .help("Home")
    }
}

private struct FileTabView: View {
    @ObservedObject var tab: OpenMeetingTab
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            if tab.isRecording {
                Circle().fill(.red).frame(width: 6, height: 6)
            }
            Text(tab.transcript.meetingName)
                .font(.system(size: 12))
                .foregroundColor(isActive ? .primary : .secondary)
                .lineLimit(1)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .opacity(isActive ? 1 : 0.5)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(isActive ? Color(nsColor: .textBackgroundColor) : Color.clear)
        .overlay(alignment: .bottom) {
            if isActive {
                Rectangle().fill(Color.orange).frame(height: 2)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
    }
}

/// Separate view that observes a single tab so isRecording changes trigger re-render.
private struct ActiveTabRecordingIndicator: View {
    @ObservedObject var tab: OpenMeetingTab

    var body: some View {
        if tab.isRecording, let session = tab.session {
            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    Circle().fill(.red).frame(width: 8, height: 8)
                    LiveDurationView(startDate: tab.transcript.startDate)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                }

                Button(action: { Task { await session.stop() } }) {
                    Text("Stop recording")
                        .font(.caption.weight(.medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(.red))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Content View for a Single Tab

struct MeetingTabContentView: View {
    @ObservedObject var tab: OpenMeetingTab
    @ObservedObject var transcript: MeetingTranscript
    @ObservedObject var state: MeetingWindowState

    init(tab: OpenMeetingTab, state: MeetingWindowState) {
        self.tab = tab
        self.transcript = tab.transcript
        self.state = state
    }
    @State private var selectedContentTab: MeetingContentTab = .notes
    @State private var searchText = ""
    @State private var showSearch = false
    @State private var showSummaryPrompt = false
    @AppStorage("meetingSummaryPrompt") private var summaryPrompt: String = MeetingSummaryGenerator.finalSummaryPrompt
    @AppStorage("selectedCleanupModelKind") private var selectedModelKind: String = LocalCleanupModelKind.qwen35_0_8b_q4_k_m.rawValue
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Title + date
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            TextField("Untitled", text: $tab.transcript.meetingName)
                                .textFieldStyle(.plain)
                                .font(.system(size: 28, weight: .bold))
                                .foregroundColor(.primary)
                                .onSubmit { state.renameActiveTab() }

                            if tab.isRecording {
                                Button(action: { tab.session?.refreshTitleAndAttendees() }) {
                                    HStack(spacing: 3) {
                                        Image(systemName: "sparkle.magnifyingglass")
                                            .font(.system(size: 11))
                                        Text("Detect")
                                            .font(.caption)
                                    }
                                    .foregroundColor(.secondary)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color(nsColor: .controlBackgroundColor))
                                    .cornerRadius(6)
                                }
                                .buttonStyle(.plain)
                                .help("Grab meeting name and attendee names from the meeting app window")
                            }
                        }

                        HStack(spacing: 8) {
                            Text(dateSubtitle)
                                .font(.callout)
                                .foregroundColor(.secondary)

                            if tab.transcript.importedFrom != nil {
                                Text("Imported from \(tab.transcript.importedFrom!.capitalized)")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(.orange)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 2)
                                    .background(Color.orange.opacity(0.1))
                                    .cornerRadius(4)
                            }
                        }
                        .padding(.bottom, tab.transcript.attendees.isEmpty ? 20 : 8)

                        if !tab.transcript.attendees.isEmpty {
                            HStack(spacing: 6) {
                                Image(systemName: "person.2")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                                ForEach(tab.transcript.attendees, id: \.self) { attendee in
                                    Text(attendee.name)
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundColor(attendee.declined ? .red : .primary)
                                        .strikethrough(attendee.declined)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(Color(nsColor: .controlBackgroundColor))
                                        .cornerRadius(10)
                                        .help(attendee.declined ? "Declined" : "")
                                }
                                Spacer()
                            }
                            .padding(.bottom, 8)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    ActiveTabRecordingIndicator(tab: tab)
                        .padding(.top, 4)
                }
            }
            .padding(.horizontal, 48)
            .padding(.top, 20)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)

            // Content tabs (Notes / Transcript / Summary)
            contentTabBar
                .padding(.horizontal, 48)
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity)

            // Search
            if showSearch {
                searchBar
            }

            // No audio warning
            if let session = tab.session, session.noAudioDetected {
                noAudioWarning
            }

            // Content
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        contentForTab(proxy: proxy)
                    }
                    .padding(.horizontal, 48)
                    .padding(.top, 24)
                    .padding(.bottom, 60)
                    .frame(maxWidth: 720, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: tab.transcript.segments.count) { _, _ in
                    if selectedContentTab == .transcript, let last = tab.transcript.segments.last {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }

            // Status bar
            statusBar
        }
        .onAppear {
            NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "f" else {
                    if event.keyCode == 53, showSearch { // Escape
                        showSearch = false; searchText = ""
                        return nil
                    }
                    return event
                }
                showSearch.toggle()
                if !showSearch { searchText = "" }
                return nil
            }
        }
    }

    // MARK: - Date subtitle

    private var dateSubtitle: String {
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .short
        if let end = tab.transcript.endDate {
            let endFmt = DateFormatter()
            endFmt.timeStyle = .short
            return "\(fmt.string(from: tab.transcript.startDate)) — \(endFmt.string(from: end))"
        }
        return fmt.string(from: tab.transcript.startDate)
    }

    // MARK: - Content Tab Bar

    private var contentTabBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 24) {
                ForEach(MeetingContentTab.allCases, id: \.self) { ct in
                    Button(action: { selectedContentTab = ct }) {
                        Text(ct.label)
                            .font(.system(size: 13, weight: selectedContentTab == ct ? .semibold : .regular))
                            .foregroundColor(selectedContentTab == ct ? .orange : .secondary)
                            .padding(.bottom, 10)
                            .overlay(alignment: .bottom) {
                                if selectedContentTab == ct {
                                    Rectangle().fill(Color.orange).frame(height: 2).offset(y: 1)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1)
        }
    }

    // MARK: - Search

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundColor(.secondary).font(.caption)
            TextField("Search...", text: $searchText)
                .textFieldStyle(.plain).font(.system(size: 13)).focused($searchFocused)
            if !searchText.isEmpty {
                Button(action: { searchText = "" }) {
                    Image(systemName: "xmark.circle.fill").foregroundColor(.secondary).font(.caption)
                }.buttonStyle(.plain)
            }
            Button(action: { showSearch = false; searchText = "" }) {
                Text("Done").font(.caption).foregroundColor(.secondary)
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 52).padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
        .onAppear { searchFocused = true }
    }

    // MARK: - No Audio Warning

    private var noAudioWarning: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange).font(.caption)
            Text("No audio detected. Check your microphone.").font(.caption)
            Spacer()
            Button("Open Settings") { state.onOpenSettings?() }
                .font(.caption.weight(.medium)).buttonStyle(.borderedProminent).tint(.orange).controlSize(.small)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(Color.orange.opacity(0.1))
    }

    // MARK: - Tab Content

    @ViewBuilder
    private func contentForTab(proxy: ScrollViewProxy) -> some View {
        switch selectedContentTab {
        case .notes: notesContent
        case .transcript: transcriptContent
        case .summary: summaryContent
        }
    }

    private static let notesFont = Font.custom("Georgia", size: 15)

    private var notesContent: some View {
        ZStack(alignment: .topLeading) {
            if tab.transcript.notes.isEmpty {
                Text("Start typing your notes...")
                    .font(Self.notesFont)
                    .foregroundColor(Color(nsColor: .placeholderTextColor))
                    .padding(.top, 1).padding(.leading, 6)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $tab.transcript.notes)
                .font(Self.notesFont).lineSpacing(6)
                .scrollContentBackground(.hidden)
                .frame(maxHeight: .infinity)
                .onChange(of: tab.transcript.notes) { _, _ in
                    state.saveActiveTab()
                }
        }
    }

    private var filteredSegments: [TranscriptSegment] {
        guard !searchText.isEmpty else { return tab.transcript.segments }
        return tab.transcript.segments.filter { $0.text.localizedCaseInsensitiveContains(searchText) }
    }

    private var transcriptContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            if tab.transcript.segments.isEmpty {
                if tab.isRecording {
                    HStack(spacing: 8) {
                        ProgressView().scaleEffect(0.6)
                        Text("Listening — segments appear every ~30 seconds").font(.callout).foregroundColor(.secondary)
                    }.padding(.vertical, 8)
                } else {
                    Text("No transcript yet.").font(.callout).foregroundColor(.secondary).padding(.vertical, 8)
                }
            }
            ForEach(filteredSegments) { segment in
                TranscriptSegmentRow(segment: segment, highlightText: searchText).id(segment.id)
            }
            if tab.isRecording && !tab.transcript.segments.isEmpty {
                HStack(spacing: 8) {
                    HStack(spacing: 4) {
                        Circle().fill(Color.secondary.opacity(0.4)).frame(width: 4, height: 4)
                        Circle().fill(Color.secondary.opacity(0.3)).frame(width: 4, height: 4)
                        Circle().fill(Color.secondary.opacity(0.2)).frame(width: 4, height: 4)
                    }
                    Text("Listening...").font(.caption).foregroundColor(.secondary)
                }.padding(.top, 4)
            }
        }
    }

    private var summaryContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            if tab.isRecording {
                VStack(spacing: 12) {
                    Image(systemName: "sparkles").font(.system(size: 32)).foregroundColor(.orange.opacity(0.4))
                    Text("Summary will be generated when the meeting ends").font(.callout).foregroundColor(.secondary)
                }.frame(maxWidth: .infinity).padding(.vertical, 60)
            } else if tab.transcript.isGeneratingSummary {
                VStack(spacing: 12) {
                    ProgressView().scaleEffect(0.8)
                    Text("Generating summary...").font(.callout).foregroundColor(.secondary)
                }.frame(maxWidth: .infinity).padding(.vertical, 60)
            } else if tab.transcript.summary != nil {
                summaryStats
            } else if tab.transcript.segments.isEmpty {
                Text("No transcript to summarize.").font(.callout).foregroundColor(.secondary).padding(.vertical, 40)
            } else {
                summaryStats
            }
        }
    }

    private var summaryStats: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Generate / Regenerate button row
            HStack {
                if tab.transcript.summary != nil {
                    Button(action: { regenerateSummary() }) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 10))
                            Text("Regenerate")
                                .font(.caption)
                        }
                        .foregroundColor(.orange)
                    }
                    .buttonStyle(.plain)
                    .disabled(tab.transcript.isGeneratingSummary)
                } else {
                    Button(action: { regenerateSummary() }) {
                        HStack(spacing: 4) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 11))
                            Text("Generate Summary")
                                .font(.caption.weight(.medium))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.orange))
                    }
                    .buttonStyle(.plain)
                    .disabled(tab.transcript.isGeneratingSummary || tab.transcript.segments.isEmpty)
                }

                Spacer()

                // Toggle prompt editor
                Button(action: { withAnimation(.easeInOut(duration: 0.15)) { showSummaryPrompt.toggle() } }) {
                    HStack(spacing: 4) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 10))
                        Text("Customize")
                            .font(.caption)
                    }
                    .foregroundColor(showSummaryPrompt ? .orange : .secondary)
                }
                .buttonStyle(.plain)
            }

            // Inline prompt editor (collapsible)
            if showSummaryPrompt {
                VStack(alignment: .leading, spacing: 8) {
                    // Model picker
                    HStack {
                        Text("Model")
                            .font(.caption).foregroundColor(.secondary)
                        Picker("", selection: $selectedModelKind) {
                            ForEach(TextCleanupManager.cleanupModels, id: \.kind) { model in
                                Text(model.displayName).tag(model.kind.rawValue)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 200)
                    }

                    // Prompt editor
                    Text("Summary prompt")
                        .font(.caption).foregroundColor(.secondary)

                    TextEditor(text: $summaryPrompt)
                        .font(.system(size: 11, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
                        .cornerRadius(6)
                        .frame(height: 120)

                    HStack {
                        Button("Reset to Default") {
                            summaryPrompt = MeetingSummaryGenerator.finalSummaryPrompt
                        }
                        .font(.caption)
                        .buttonStyle(.plain)
                        .foregroundColor(.secondary)

                        Spacer()
                    }
                }
                .padding(10)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
                .cornerRadius(8)
            }

            // Editable summary (same style as notes)
            ZStack(alignment: .topLeading) {
                if (tab.transcript.summary ?? "").isEmpty {
                    Text("Summary will appear here after generation...")
                        .font(Self.notesFont)
                        .foregroundColor(Color(nsColor: .placeholderTextColor))
                        .padding(.top, 1).padding(.leading, 6)
                        .allowsHitTesting(false)
                }

                TextEditor(text: Binding(
                    get: { tab.transcript.summary ?? "" },
                    set: { tab.transcript.summary = $0.isEmpty ? nil : $0 }
                ))
                .font(Self.notesFont)
                .lineSpacing(6)
                .scrollContentBackground(.hidden)
                .frame(maxHeight: .infinity)
                .onChange(of: tab.transcript.summary) { _, _ in
                    state.saveActiveTab()
                }
            }
        }
    }

    // MARK: - Status Bar

    private func regenerateSummary() {
        state.onGenerateSummary?(tab.transcript)
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            if let url = tab.fileURL {
                Button(action: {
                    NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.text")
                        Text(url.lastPathComponent)
                    }.font(.caption).foregroundColor(.secondary)
                }.buttonStyle(.plain)
            }
            Spacer()
            if !tab.transcript.segments.isEmpty {
                Text("\(tab.transcript.segments.count) segments").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 6)
        .background(Color(nsColor: .textBackgroundColor))
        .overlay(alignment: .top) {
            Rectangle().fill(Color(nsColor: .separatorColor).opacity(0.5)).frame(height: 1)
        }
    }
}

// MARK: - Content Tab Enum

enum MeetingContentTab: String, CaseIterable {
    case notes, transcript, summary
    var label: String {
        switch self {
        case .notes: "📝 Notes"
        case .transcript: "📜 Transcript"
        case .summary: "✨ Summary"
        }
    }
}

// MARK: - Sidebar

struct MeetingSidebarView: View {
    @ObservedObject var state: MeetingWindowState
    @State private var searchText = ""

    private var filteredGroups: [(date: String, entries: [MeetingHistoryEntry])] {
        guard !searchText.isEmpty else { return state.historyGroups }
        let query = searchText.lowercased()
        return state.historyGroups.compactMap { group in
            let filtered = group.entries.filter { $0.name.lowercased().contains(query) }
            return filtered.isEmpty ? nil : (date: group.date, entries: filtered)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("Meetings")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()

                Button(action: { openMeetingsFolder() }) {
                    Image(systemName: "folder")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Show in Finder")
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider().padding(.horizontal, 12).padding(.bottom, 4)

            // Search field
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                TextField("Search meetings", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
            .cornerRadius(6)
            .padding(.horizontal, 12)
            .padding(.bottom, 4)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if filteredGroups.isEmpty {
                        Text(searchText.isEmpty ? "No past meetings" : "No matches")
                            .font(.caption).foregroundColor(.secondary)
                            .padding(.horizontal, 16).padding(.top, 8)
                    }

                    ForEach(filteredGroups, id: \.date) { group in
                        Text(group.date)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 16)
                            .padding(.top, 10).padding(.bottom, 2)

                        ForEach(group.entries) { entry in
                            let isOpen = state.tabs.contains { $0.fileURL == entry.fileURL }
                            Button(action: { state.openFile(entry.fileURL) }) {
                                HStack(spacing: 6) {
                                    Image(systemName: entry.isGranola ? "square.and.arrow.down.on.square" : "doc.text")
                                        .font(.system(size: 10))
                                        .foregroundColor(isOpen ? .orange : (entry.isGranola ? .green.opacity(0.7) : .secondary))
                                    Text(entry.name)
                                        .font(.system(size: 12))
                                        .foregroundColor(isOpen ? .orange : .primary)
                                        .lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 5)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("Show in Finder") {
                                    NSWorkspace.shared.selectFile(
                                        entry.fileURL.path,
                                        inFileViewerRootedAtPath: entry.fileURL.deletingLastPathComponent().path
                                    )
                                }
                                Divider()
                                Button("Delete", role: .destructive) {
                                    deleteEntry(entry)
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func deleteEntry(_ entry: MeetingHistoryEntry) {
        // Close the tab if it's open
        if let tab = state.tabs.first(where: { $0.fileURL == entry.fileURL }) {
            state.closeTab(tab.id)
        }
        // Move to trash
        do {
            try FileManager.default.trashItem(at: entry.fileURL, resultingItemURL: nil)
            state.loadHistory()
        } catch {
            print("Failed to delete \(entry.fileURL.lastPathComponent): \(error)")
        }
    }

    private func openMeetingsFolder() {
        let dir = MeetingTranscriptSettings.effectiveSaveDirectory()
        NSWorkspace.shared.open(dir)
    }
}

// MARK: - Consent Dialog

private struct ConsentDialogView: View {
    @ObservedObject var state: MeetingWindowState
    @State private var copied = false
    @AppStorage("skipConsentDialog") private var skipConsent = false

    private static let consentMessage = "I'm using 🌶️ Ghost Pepper, a completely private AI note taker. Nothing leaves my computer and all AI models are done on device."

    var body: some View {
        VStack(spacing: 20) {
            // Header
            Image(systemName: "mic.badge.xmark")
                .font(.system(size: 36))
                .foregroundColor(.orange)
                .padding(.top, 8)

            Text("Let participants know")
                .font(.title3.bold())

            Text("Before recording, share this with your meeting participants:")
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            // Message to copy
            VStack(spacing: 8) {
                Text(Self.consentMessage)
                    .font(.system(size: 13))
                    .padding(12)
                    .frame(maxWidth: .infinity)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))

                Button(action: {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(Self.consentMessage, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        Text(copied ? "Copied!" : "Copy to clipboard")
                    }
                    .font(.caption.weight(.medium))
                }
                .buttonStyle(.plain)
                .foregroundColor(.blue)
            }

            Divider()

            // Buttons
            VStack(spacing: 12) {
                Button(action: { state.confirmRecording() }) {
                    Text("I've informed participants — Start recording")
                        .font(.callout.weight(.medium))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange))
                }
                .buttonStyle(.plain)

                Button(action: { state.cancelRecording() }) {
                    Text("Cancel")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }

            // Don't ask again
            Toggle(isOn: $skipConsent) {
                Text("Don't ask again (my jurisdiction doesn't require consent)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .toggleStyle(.checkbox)
            .padding(.bottom, 4)
        }
        .padding(24)
        .frame(width: 400)
    }
}

// MARK: - Helper Views

private struct SummarySectionHeader: View {
    let title: String
    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 11, weight: .bold))
            .foregroundColor(.secondary).tracking(0.5)
    }
}

private struct StatBlock: View {
    let value: String
    let label: String
    var color: Color = .primary
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 22, weight: .bold)).foregroundColor(color)
            Text(label).font(.caption).foregroundColor(.secondary)
        }
    }
}

struct TranscriptSegmentRow: View {
    let segment: TranscriptSegment
    var highlightText: String = ""

    private var showSpeakerBadge: Bool {
        switch segment.speaker {
        case .me: return true
        case .remote(let name): return name != nil
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(segment.formattedTimestamp)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 48, alignment: .trailing)
            if showSpeakerBadge {
                Text(segment.speaker.displayName)
                    .font(.caption2.weight(.semibold)).foregroundColor(.white)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(speakerColor))
            }
            highlightedText
                .font(.system(size: 14)).lineSpacing(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var highlightedText: Text {
        guard !highlightText.isEmpty else { return Text(segment.text) }
        var attributed = AttributedString(segment.text)
        let query = highlightText.lowercased()
        var searchRange = attributed.startIndex..<attributed.endIndex
        while let range = attributed[searchRange].range(of: query, options: .caseInsensitive) {
            attributed[range].backgroundColor = .yellow.opacity(0.5)
            attributed[range].foregroundColor = .black
            searchRange = range.upperBound..<attributed.endIndex
        }
        return Text(attributed)
    }

    private var speakerColor: Color {
        switch segment.speaker {
        case .me: return .orange
        case .remote: return .blue
        }
    }
}

struct LiveDurationView: View {
    let startDate: Date
    @State private var now = Date()
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Text(formattedDuration).onReceive(timer) { now = $0 }
    }

    private var formattedDuration: String {
        let total = Int(now.timeIntervalSince(startDate))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
}
