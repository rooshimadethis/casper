import Foundation

final class MicroStore: Codable {
    var store: [String: [String: Double]] = [:]
    private let lock = NSRecursiveLock()

    enum CodingKeys: CodingKey {
        case store
    }

    init() {}

    required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let decoded = try? container.decode([String: [String: Double]].self, forKey: .store) {
            store = decoded
        } else {
            let legacy = try container.decode([String: [String: Int]].self, forKey: .store)
            store = legacy.mapValues { values in
                values.mapValues(Double.init)
            }
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(store, forKey: .store)
    }

    func record(value: String, forContext contextHash: String, weight: Double = 1) {
        lock.withLock {
            store[contextHash, default: [:]][value, default: 0] += weight
        }
    }

    func reset() {
        lock.withLock {
            store = [:]
        }
    }

    func predict(for contextHash: String) -> [(value: String, count: Double)] {
        lock.withLock {
            guard let entries = store[contextHash] else { return [] }
            return entries
                .map { ($0.key, $0.value) }
                .sorted { $0.1 > $1.1 }
        }
    }

    func predict(forContext context: [String], targetToken: String) -> [(value: String, count: Double)] {
        lock.withLock {
            let maxDepth = min(context.count, PpmTrie.maxDepth)
            for depth in stride(from: maxDepth, through: 0, by: -1) {
                let keyTokens: [String]
                if depth == 0 {
                    keyTokens = [targetToken]
                } else {
                    keyTokens = Array(context.suffix(depth)) + [targetToken]
                }
                let contextHash = keyTokens.joined(separator: " → ")
                guard let entries = store[contextHash] else { continue }
                return entries
                    .map { ($0.key, $0.value) }
                    .sorted { $0.1 > $1.1 }
            }
            return []
        }
    }

    var allEntries: [(context: String, values: [(value: String, count: Double)])] {
        lock.withLock {
            store.map { context, values in
                (context, values.map { ($0.key, $0.value) }.sorted { $0.1 > $1.1 })
            }
            .sorted { $0.context < $1.context }
        }
    }

    func prune(floor: Double) {
        lock.withLock {
            for (context, values) in store {
                let filtered = values.filter { $0.value >= floor }
                if filtered.isEmpty {
                    store.removeValue(forKey: context)
                } else {
                    store[context] = filtered
                }
            }
        }
    }

    func save(to url: URL) throws {
        lock.withLock {
            let dir = url.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let data = try JSONEncoder().encode(self)
        try data.write(to: url, options: .atomic)
    }

    static func load(from url: URL) throws -> MicroStore {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(MicroStore.self, from: data)
    }
}
