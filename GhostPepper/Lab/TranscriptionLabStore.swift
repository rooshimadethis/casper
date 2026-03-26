import Foundation

final class TranscriptionLabStore {
    private let directoryURL: URL
    private let maxEntries: Int
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        directoryURL: URL? = nil,
        maxEntries: Int = 50
    ) {
        self.directoryURL = directoryURL ?? Self.defaultDirectoryURL
        self.maxEntries = maxEntries
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
    }

    func loadEntries() throws -> [TranscriptionLabEntry] {
        guard FileManager.default.fileExists(atPath: indexURL.path) else {
            return []
        }

        let data = try Data(contentsOf: indexURL)
        let entries = try decoder.decode([TranscriptionLabEntry].self, from: data)
        return entries.sorted { $0.createdAt > $1.createdAt }
    }

    func insert(_ entry: TranscriptionLabEntry, audioData: Data) throws {
        try FileManager.default.createDirectory(at: audioDirectoryURL, withIntermediateDirectories: true)
        try audioData.write(to: audioURL(for: entry.audioFileName), options: .atomic)

        var entries = try loadEntries()
        entries.removeAll { $0.id == entry.id }
        entries.append(entry)
        entries.sort { $0.createdAt > $1.createdAt }

        let prunedEntries = Array(entries.prefix(maxEntries))
        let prunedFileNames = Set(entries.dropFirst(maxEntries).map(\.audioFileName))
        for fileName in prunedFileNames {
            try? FileManager.default.removeItem(at: audioURL(for: fileName))
        }

        let data = try encoder.encode(prunedEntries)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try data.write(to: indexURL, options: .atomic)
    }

    func audioURL(for audioFileName: String) -> URL {
        audioDirectoryURL.appendingPathComponent(audioFileName)
    }

    private var indexURL: URL {
        directoryURL.appendingPathComponent("transcription-lab-index.json")
    }

    private var audioDirectoryURL: URL {
        directoryURL.appendingPathComponent("audio", isDirectory: true)
    }

    private static var defaultDirectoryURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("GhostPepper", isDirectory: true)
            .appendingPathComponent("transcription-lab", isDirectory: true)
    }
}
