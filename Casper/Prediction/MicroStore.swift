import Foundation

final class MicroStore: Codable {
    var store: [String: [String: Int]] = [:]
    private let lock = NSRecursiveLock()

    enum CodingKeys: CodingKey {
        case store
    }

    init() {}

    required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        store = try container.decode([String: [String: Int]].self, forKey: .store)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(store, forKey: .store)
    }

    func record(value: String, forContext contextHash: String, weight: Int = 1) {
        lock.withLock {
            store[contextHash, default: [:]][value, default: 0] += weight
        }
    }

    func predict(for contextHash: String) -> [(value: String, count: Int)] {
        lock.withLock {
            guard let entries = store[contextHash] else { return [] }
            return entries
                .map { ($0.key, $0.value) }
                .sorted { $0.1 > $1.1 }
        }
    }

    func prune(floor: Int) {
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
