import Foundation

struct TelemetryEventRecord: Sendable, Codable {
    let recordedAt: Date
    let event: DesktopUserEvent
}

struct TelemetryStatusSnapshot: Sendable {
    let rawEventsDirectory: URL
    let sessionsDirectory: URL
    let todayLogURL: URL
    let todayEventCount: Int
    let latestEventAt: Date?
    let todaySummaryCount: Int
    let latestSummaryURL: URL?
}

/// Handles strictly local, daily-partitioned JSON Lines (JSONL) storage
/// and rotation of passive telemetry events.
final class TelemetryStorage: Sendable {
    let storageDirectory: URL

    var sessionsDirectory: URL {
        storageDirectory.appendingPathComponent("sessions", isDirectory: true)
    }

    /// Initializes the storage manager with a directory.
    /// If none is provided, it defaults to Casper's Application Support folder.
    init(storageDirectory: URL? = nil) {
        if let customDir = storageDirectory {
            self.storageDirectory = customDir
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.storageDirectory = appSupport
                .appendingPathComponent("Casper", isDirectory: true)
                .appendingPathComponent("telemetry", isDirectory: true)
        }
    }

    /// Appends a `DesktopUserEvent` to the current day's log partition.
    func appendEvent(_ event: DesktopUserEvent, recordedAt: Date = Date()) throws {
        try createDirectoryIfNeeded()

        let dateString = Self.dateString(for: recordedAt)
        let fileURL = storageDirectory.appendingPathComponent("telemetry_events_\(dateString).jsonl")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let record = TelemetryEventRecord(recordedAt: recordedAt, event: event)
        var eventData = try encoder.encode(record)
        eventData.append(contentsOf: "\n".data(using: .utf8)!)

        if FileManager.default.fileExists(atPath: fileURL.path) {
            let fileHandle = try FileHandle(forWritingTo: fileURL)
            defer {
                try? fileHandle.close()
            }
            try fileHandle.seekToEnd()
            try fileHandle.write(contentsOf: eventData)
        } else {
            try eventData.write(to: fileURL, options: .atomic)
        }
    }

    /// Reads events from a specific day's partition.
    func loadEvents(forDateString dateString: String) throws -> [DesktopUserEvent] {
        try loadEventRecords(forDateString: dateString).map(\.event)
    }

    /// Reads timestamped records from a specific day's partition.
    func loadEventRecords(forDateString dateString: String) throws -> [TelemetryEventRecord] {
        let fileURL = storageDirectory.appendingPathComponent("telemetry_events_\(dateString).jsonl")
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }

        let content = try String(contentsOf: fileURL, encoding: .utf8)
        let lines = content.components(separatedBy: .newlines)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        return lines.enumerated().compactMap { index, line -> TelemetryEventRecord? in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else {
                return nil
            }
            if let record = try? decoder.decode(TelemetryEventRecord.self, from: data) {
                return record
            }
            if let legacyEvent = try? JSONDecoder().decode(DesktopUserEvent.self, from: data) {
                return TelemetryEventRecord(
                    recordedAt: Self.fallbackRecordedAt(forDateString: dateString, lineOffset: index),
                    event: legacyEvent
                )
            }
            return nil
        }
    }

    /// Rotates logs by removing daily partition files older than 7 days.
    func rotateLogs() throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: storageDirectory.path) else {
            return
        }

        let contents = try fileManager.contentsOfDirectory(at: storageDirectory, includingPropertiesForKeys: nil)
        let calendar = Calendar.current
        let now = Date()
        guard let sevenDaysAgo = calendar.date(byAdding: .day, value: -7, to: now) else {
            return
        }

        // Format date key threshold as yyyy-MM-dd
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current

        for fileURL in contents {
            let filename = fileURL.lastPathComponent
            guard filename.hasPrefix("telemetry_events_") && filename.hasSuffix(".jsonl") else {
                continue
            }

            // Extract YYYY-MM-DD
            let prefixLength = "telemetry_events_".count
            let suffixLength = ".jsonl".count
            let startIdx = filename.index(filename.startIndex, offsetBy: prefixLength)
            let endIdx = filename.index(filename.endIndex, offsetBy: -suffixLength)
            let datePart = String(filename[startIdx..<endIdx])

            if let fileDate = formatter.date(from: datePart) {
                if fileDate < sevenDaysAgo {
                    try fileManager.removeItem(at: fileURL)
                }
            }
        }
    }

    func statusSnapshot(referenceDate: Date = Date()) -> TelemetryStatusSnapshot {
        let dateString = Self.dateString(for: referenceDate)
        let todayLogURL = storageDirectory.appendingPathComponent("telemetry_events_\(dateString).jsonl")
        let records = (try? loadEventRecords(forDateString: dateString)) ?? []
        let latestEventAt = records.last?.recordedAt

        let summaryFiles = ((try? FileManager.default.contentsOfDirectory(
            at: sessionsDirectory,
            includingPropertiesForKeys: nil
        )) ?? [])
            .filter { fileURL in
                let filename = fileURL.lastPathComponent
                return filename.hasPrefix("session_\(dateString)_") && filename.hasSuffix(".txt")
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        return TelemetryStatusSnapshot(
            rawEventsDirectory: storageDirectory,
            sessionsDirectory: sessionsDirectory,
            todayLogURL: todayLogURL,
            todayEventCount: records.count,
            latestEventAt: latestEventAt,
            todaySummaryCount: summaryFiles.count,
            latestSummaryURL: summaryFiles.last
        )
    }

    // MARK: - Helpers

    private func createDirectoryIfNeeded() throws {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: storageDirectory.path) {
            try fileManager.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
        }
    }

    private static func dateString(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        return formatter.string(from: date)
    }

    private static func fallbackRecordedAt(forDateString dateString: String, lineOffset: Int) -> Date {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current

        let startOfDay = formatter.date(from: dateString) ?? Date()
        return startOfDay.addingTimeInterval(TimeInterval(lineOffset))
    }
}
