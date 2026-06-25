import SwiftUI
import CoreAudio
import ServiceManagement
import Combine

struct MenuBarView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var updaterController: UpdaterController
    @State private var telemetryStatus = TelemetryStatusSnapshot(
        rawEventsDirectory: URL(fileURLWithPath: NSHomeDirectory()),
        sessionsDirectory: URL(fileURLWithPath: NSHomeDirectory()),
        todayLogURL: URL(fileURLWithPath: NSHomeDirectory()),
        todayEventCount: 0,
        latestEventAt: nil,
        todaySummaryCount: 0,
        latestSummaryURL: nil
    )
    private let telemetryRefreshTimer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button("Settings...") {
                appState.showSettings()
            }

            if appState.pepperChatEnabled {
                Button("Context Bundler...") {
                    appState.showPepperChat()
                }
            }

            Button("Debug Log...") {
                appState.showDebugLog()
            }

            if appState.meetingTranscriptEnabled {
                Divider()

                Button("IDE...") {
                    appState.showOrCreateMeetingWindow()
                }

                if appState.activeMeetingSession != nil {
                    Button("Stop Meeting") {
                        appState.stopMeetingTranscription()
                    }
                }
            }

            Text("Casper v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 14)
                .padding(.vertical, 2)

            if let statusText = statusLine {
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 2)
            }

            Divider()

            telemetrySection

            if case .downloading(_, let progress) = appState.textCleanupManager.state {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .padding(.horizontal, 14)
            }

            if let error = appState.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 14)

                if appState.canReloadAudioInput {
                    Button("Reload Audio Input") {
                        appState.resetAudioEngine()
                    }
                }
                if error.contains("Input Monitoring") {
                    Button("Open Input Monitoring Settings") {
                        PermissionChecker.openInputMonitoringSettings()
                    }
                    Button("Retry") {
                        Task { await appState.startHotkeyMonitor() }
                    }
                }
                if error.contains("Accessibility") {
                    Button("Open Accessibility Settings") {
                        PermissionChecker.openAccessibilitySettings()
                    }
                    Button("Retry") {
                        Task { await appState.startHotkeyMonitor() }
                    }
                }
                if error.contains("Microphone") {
                    Button("Open Microphone Settings") {
                        PermissionChecker.openMicrophoneSettings()
                    }
                }
            }

            Divider()

            Button(updaterController.updateAvailable ? "Update Available — Install Now" : "Check for Updates") {
                updaterController.checkForUpdates()
            }
            .foregroundColor(updaterController.updateAvailable ? .orange : nil)

            Divider()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(.vertical, 4)
        .onAppear(perform: refreshTelemetryStatus)
        .onReceive(telemetryRefreshTimer) { _ in
            refreshTelemetryStatus()
        }
    }

    private var statusLine: String? {
        switch appState.status {
        case .ready:
            return nil
        case .loading:
            return "Loading..."
        case .recording:
            return "Recording..."
        case .transcribing:
            return "Transcribing..."
        case .cleaningUp:
            return "Cleaning up..."
        case .error:
            return nil
        }
    }

    private var telemetrySection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Telemetry")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 14)
                .padding(.top, 2)

            Text(telemetryHeadline)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)

            Text("Today: \(telemetryStatus.todayEventCount) event\(telemetryStatus.todayEventCount == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)

            Text("Session summaries today: \(telemetryStatus.todaySummaryCount)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)

            Button("Open Event Log Folder") {
                appState.openTelemetryEventLogDirectory()
            }

            Button("Open Summary Folder") {
                appState.openTelemetrySummaryDirectory()
            }

            Divider()

            Button("Show Prediction Overlay") {
                appState.togglePredictionOverlay()
            }

            Button("Retrain Prediction Model") {
                appState.retrainPredictionModel()
            }
        }
        .padding(.bottom, 2)
    }

    private var telemetryHeadline: String {
        guard telemetryStatus.todayEventCount > 0 else {
            return "No events captured yet today."
        }

        guard let latestEventAt = telemetryStatus.latestEventAt else {
            return "Events recorded today."
        }

        let age = Date().timeIntervalSince(latestEventAt)
        let relative = Self.relativeFormatter.localizedString(for: latestEventAt, relativeTo: Date())

        if age <= 120 {
            return "Telemetry active. Last event \(relative)."
        }

        if age <= 900 {
            return "Telemetry looks healthy. Last event \(relative)."
        }

        return "Telemetry may be idle. Last event \(relative)."
    }

    private func refreshTelemetryStatus() {
        telemetryStatus = appState.telemetryStorage.statusSnapshot()
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()
}
