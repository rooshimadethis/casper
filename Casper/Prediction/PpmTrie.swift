import Foundation

final class PpmTrieNode: Codable {
    var children: [String: PpmTrieNode] = [:]
    var count: Int = 0
}

final class PpmTrie: Codable {
    var root: PpmTrieNode = PpmTrieNode()
    private let lock = NSRecursiveLock()

    enum CodingKeys: CodingKey {
        case root
    }

    init() {}

    required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        root = try container.decode(PpmTrieNode.self, forKey: .root)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(root, forKey: .root)
    }

    static let maxDepth = 5
    static let escapeMultipliers: [Int: Double] = [
        5: 1.0,
        4: 1.0,
        3: 0.5,
        2: 0.3,
        1: 0.15,
    ]

    func insert(tokens: [String], weight: Double = 1.0) {
        lock.withLock {
            let weightInt = Int(weight)
            let maxLen = min(tokens.count, Self.maxDepth)
            for len in 1...maxLen {
                let suffix = Array(tokens.suffix(len))
                var node = root
                node.count += weightInt
                for token in suffix {
                    let child = node.children[token] ?? {
                        let new = PpmTrieNode()
                        node.children[token] = new
                        return new
                    }()
                    child.count += weightInt
                    node = child
                }
            }
        }
    }

    func predict(context: [String]) -> [(token: String, confidence: Double)] {
        lock.withLock {
            guard !context.isEmpty else {
                let total = root.children.values.reduce(0) { $0 + $1.count }
                guard total > 0 else { return [] }
                return root.children
                    .map { ($0.key, Double($0.value.count) / Double(total)) }
                    .sorted { $0.1 > $1.1 }
            }

            var weightedCounts: [String: Double] = [:]

            let maxDepth = min(context.count, Self.maxDepth)
            for depth in 1...maxDepth {
                let suffix = Array(context.suffix(depth))
                var node = root
                var found = true
                for token in suffix {
                    guard let child = node.children[token] else {
                        found = false
                        break
                    }
                    node = child
                }

                guard found else { continue }

                let multiplier = Self.escapeMultipliers[depth] ?? 1.0
                for (childToken, childNode) in node.children {
                    weightedCounts[childToken, default: 0] += Double(childNode.count) * multiplier
                }
            }

            guard !weightedCounts.isEmpty else { return [] }

            let total = weightedCounts.values.reduce(0, +)
            return weightedCounts
                .map { ($0.key, $0.value / total) }
                .sorted { $0.1 > $1.1 }
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

    static func load(from url: URL) throws -> PpmTrie {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(PpmTrie.self, from: data)
    }

    func nodeCount() -> Int {
        lock.withLock {
            func countNodes(_ node: PpmTrieNode) -> Int {
                1 + node.children.values.reduce(0) { $0 + countNodes($1) }
            }
            return countNodes(root)
        }
    }

    func snapshot() -> TrieNodeSnapshot {
        lock.withLock {
            func convert(_ token: String, _ node: PpmTrieNode) -> TrieNodeSnapshot {
                TrieNodeSnapshot(
                    token: token,
                    count: node.count,
                    children: node.children.map { convert($0.key, $0.value) }
                )
            }
            return convert("(root)", root)
        }
    }

    func prune(floor: Int) {
        lock.withLock {
            func shouldKeep(_ node: PpmTrieNode) -> Bool {
                node.children = node.children.filter { _, child in
                    shouldKeep(child)
                }
                return node.count >= floor || !node.children.isEmpty
            }
            root.children = root.children.filter { _, child in
                shouldKeep(child)
            }
        }
    }
}

struct TrieNodeSnapshot: Identifiable {
    let id = UUID()
    let token: String
    let count: Int
    let children: [TrieNodeSnapshot]

    func hasDescendant(matching filter: String) -> Bool {
        if token.localizedCaseInsensitiveContains(filter) { return true }
        return children.contains { $0.hasDescendant(matching: filter) }
    }
}
