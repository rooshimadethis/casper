import Foundation

final class PredictionTrainer: @unchecked Sendable {
    private struct TrainingProgress: Codable {
        var processedLineCounts: [String: Int] = [:]
    }

    var debugLogger: ((DebugLogCategory, String) -> Void)?

    private let storage: TelemetryStorage
    private let trie: PpmTrie
    let microStore: MicroStore
    private let powerMonitor: any TelemetryPowerMonitoring
    private let predictionDirectory: URL

    private var processTask: Task<Void, Never>?

    init(
        storage: TelemetryStorage,
        trie: PpmTrie,
        microStore: MicroStore = MicroStore(),
        powerMonitor: any TelemetryPowerMonitoring,
        predictionDirectory: URL? = nil
    ) {
        self.storage = storage
        self.trie = trie
        self.microStore = microStore
        self.powerMonitor = powerMonitor
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.predictionDirectory = predictionDirectory ?? appSupport
            .appendingPathComponent("Casper", isDirectory: true)
            .appendingPathComponent("prediction", isDirectory: true)
    }

    func train(force: Bool = false) {
        train(force: force, rebuild: false)
    }

    func train(force: Bool = false, rebuild: Bool) {
        guard processTask == nil else {
            debugLogger?(.prediction, "Training skipped: already in progress")
            return
        }

        debugLogger?(.prediction, "Training started (forced: \(force), rebuild: \(rebuild))")

        processTask = Task(priority: .background) {
            defer {
                self.processTask = nil
                self.debugLogger?(.prediction, "Training finished")
            }

            guard force || powerMonitor.isUserIdle(threshold: 600) else {
                debugLogger?(.prediction, "Training skipped: user not idle (force=\(force))")
                return
            }

            await processAllEvents(rebuild: rebuild)
        }
    }

    private func processAllEvents(rebuild: Bool) async {
        if rebuild {
            trie.reset()
            microStore.reset()
        } else if let loaded = try? MicroStore.load(from: microStoreURL) {
            microStore.store = loaded.store
        }

        let fileManager = FileManager.default
        let eventsDir = storage.eventsDirectory

        guard fileManager.fileExists(atPath: eventsDir.path) else {
            debugLogger?(.prediction, "Training: events directory does not exist")
            return
        }

        do {
            let files = try fileManager.contentsOfDirectory(at: eventsDir, includingPropertiesForKeys: nil)
            let logFiles = files
                .filter { $0.lastPathComponent.hasPrefix("telemetry_events_") && $0.lastPathComponent.hasSuffix(".jsonl") }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }

            debugLogger?(.prediction, "Training: processing \(logFiles.count) telemetry files")

            var progress = rebuild ? TrainingProgress() : loadProgress()

            for fileURL in logFiles {
                if Task.isCancelled {
                    debugLogger?(.prediction, "Training cancelled mid-file")
                    break
                }
                progress = await processFile(fileURL, progress: progress)
            }

            saveProgress(progress)
            try trie.save(to: trieURL)
            let nodeCount = trie.nodeCount()
            debugLogger?(.prediction, "Training: trie saved (\(nodeCount) nodes)")

            microStore.prune(floor: 3)
            try microStore.save(to: microStoreURL)
            debugLogger?(.prediction, "Training: microStore saved")
        } catch {
            debugLogger?(.prediction, "Training failed: \(error.localizedDescription)")
            print("PredictionTrainer: Failed to process events: \(error.localizedDescription)")
        }
    }

    private func processFile(_ fileURL: URL, progress: TrainingProgress) async -> TrainingProgress {
        let filename = fileURL.lastPathComponent
        let datePart = filename
            .replacingOccurrences(of: "telemetry_events_", with: "")
            .replacingOccurrences(of: ".jsonl", with: "")
        var updatedProgress = progress

        do {
            let records = try storage.loadEventRecords(forDateString: datePart)
            guard !records.isEmpty else {
                debugLogger?(.prediction, "Training: \(filename) has no records")
                return updatedProgress
            }

            let processedLineCount = updatedProgress.processedLineCounts[datePart] ?? 0
            guard processedLineCount < records.count else {
                debugLogger?(.prediction, "Training: \(filename) already fully processed (\(processedLineCount) lines)")
                return updatedProgress
            }

            let pendingRecords = Array(records.suffix(from: processedLineCount))
            let totalPending = pendingRecords.count
            debugLogger?(.prediction, "Training: processing \(totalPending) new records from \(filename)")

            var tokenWindow: [String] = []
            var activeAppName = ""
            var insertedCount = 0
            var skippedCount = 0
            var eventTypeCounts: [String: Int] = [:]
            var lastProgressLog = 0

            for (index, record) in pendingRecords.enumerated() {
                if Task.isCancelled {
                    debugLogger?(.prediction, "Training cancelled: \(filename)")
                    break
                }

                if case .appActivated(let name, _, _) = record.event {
                    activeAppName = name
                }

                let eventLabel = String(describing: type(of: record.event)).split(separator: "(").first.map(String.init) ?? "unknown"
                eventTypeCounts[eventLabel, default: 0] += 1

                guard let token = Tokenizer.tokenize(record.event, activeAppName: activeAppName) else {
                    skippedCount += 1
                    continue
                }

                insertedCount += 1

                let contextTokens = tokenWindow + [token]
                let contextHash = contextTokens.joined(separator: " → ")

                tokenWindow.append(token)
                if tokenWindow.count > PpmTrie.maxDepth {
                    tokenWindow = Array(tokenWindow.suffix(PpmTrie.maxDepth))
                }

                let weight = timeDecayWeight(for: record.recordedAt)
                trie.insert(tokens: tokenWindow, weight: weight)

                switch record.event {
                case .typingSession(_, _, let typedText, _):
                    if !isKeyboardShortcut(typedText),
                       let normalizedText = MicroValueNormalizer.normalizeTypedText(typedText, token: token) {
                        microStore.record(value: normalizedText, forContext: contextHash, weight: Int(weight))
                    }
                case .mouseClicked(_, let elementClicked, _, let selectedText):
                    if let normalizedTarget = MicroValueNormalizer.normalizeClickTarget(elementClicked) {
                        microStore.record(value: normalizedTarget, forContext: contextHash, weight: Int(weight))
                    }
                    if let selectedText, !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        microStore.record(value: selectedText, forContext: contextHash, weight: Int(weight))
                    }
                default:
                    break
                }

                if index - lastProgressLog >= 100 || index == totalPending - 1 {
                    lastProgressLog = index
                    debugLogger?(.prediction, "Training: \(filename) — \(index + 1)/\(totalPending) records (inserted: \(insertedCount), skipped: \(skippedCount), window: [\(tokenWindow.joined(separator: ", "))])")
                }
            }

            debugLogger?(.prediction, "Training: \(filename) event breakdown — \(eventTypeCounts.sorted(by: { $0.value > $1.value }).map { "\($0.key)=\($0.value)" }.joined(separator: ", "))")

            updatedProgress.processedLineCounts[datePart] = records.count
            debugLogger?(.prediction, "Training: \(filename) done (\(records.count) total records processed)")
        } catch {
            debugLogger?(.prediction, "Training failed for \(filename): \(error.localizedDescription)")
            print("PredictionTrainer: Failed to process \(filename): \(error.localizedDescription)")
        }

        return updatedProgress
    }

    private func isKeyboardShortcut(_ text: String) -> Bool {
        text.hasPrefix("<Cmd") || text.hasPrefix("<Ctrl") || text.hasPrefix("<Opt")
            || text.hasPrefix("<Shift") || text.hasPrefix("<Fn")
    }

    private func timeDecayWeight(for date: Date) -> Double {
        let elapsed = Date().timeIntervalSince(date)
        let oneDay: TimeInterval = 86400
        if elapsed < oneDay {
            return 2.0
        } else if elapsed < 2 * oneDay {
            return 1.0
        } else {
            return 0.5
        }
    }

    private var progressURL: URL {
        predictionDirectory.appendingPathComponent("prediction_progress.json")
    }

    private var trieURL: URL {
        predictionDirectory.appendingPathComponent("ppm_trie.json")
    }

    private var microStoreURL: URL {
        predictionDirectory.appendingPathComponent("micro_store.json")
    }

    private func loadProgress() -> TrainingProgress {
        guard let data = try? Data(contentsOf: progressURL),
              let progress = try? JSONDecoder().decode(TrainingProgress.self, from: data) else {
            return TrainingProgress()
        }
        return progress
    }

    private func saveProgress(_ progress: TrainingProgress) {
        try? FileManager.default.createDirectory(at: predictionDirectory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(progress) else { return }
        try? data.write(to: progressURL, options: .atomic)
    }
}
