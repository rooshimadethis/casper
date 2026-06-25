import XCTest
@testable import Casper

final class PpmTrieTests: XCTestCase {

    func testInsertAndPredictExactMatch() {
        let trie = PpmTrie()
        trie.insert(tokens: ["a:com.apple.dt.Xcode", "a:com.google.Chrome"])
        let result = trie.predict(context: ["a:com.apple.dt.Xcode"])
        XCTAssertEqual(result.first?.token, "a:com.google.Chrome")
        XCTAssertGreaterThan(result.first?.confidence ?? 0, 0)
    }

    func testPPMBackoffToShorterContext() {
        let trie = PpmTrie()
        trie.insert(tokens: ["a:A", "a:B"])
        trie.insert(tokens: ["a:C", "a:D"])
        // Context [a:A, a:C]:
        // depth 2: root->a:A->a:C doesn't exist (a:A has child a:B, not a:C) → skip
        // depth 1: root->a:C has child a:D → predicts a:D
        let result = trie.predict(context: ["a:A", "a:C"])
        XCTAssertEqual(result.first?.token, "a:D")
    }

    func testPPMBlendingAcrossDepths() {
        let trie = PpmTrie()
        for _ in 0..<10 {
            trie.insert(tokens: ["a:A", "a:B"])
        }
        trie.insert(tokens: ["a:A", "a:C", "a:B"])
        // Query context [a:A, a:C]:
        // - depth 2: no match for [a:A, a:C] (a:B follows [a:A], a:D follows [a:A, a:C])
        // - depth 1: at "a:C" node, children are: a:B x1
        // So prediction should be "a:B"
        let result = trie.predict(context: ["a:A", "a:C"])
        XCTAssertEqual(result.first?.token, "a:B")
        XCTAssertGreaterThan(result.first?.confidence ?? 0, 0.5)
    }

    func testEmptyContextReturnsUnigramPredictions() {
        let trie = PpmTrie()
        trie.insert(tokens: ["a:X"])
        trie.insert(tokens: ["a:Y"])
        let result = trie.predict(context: [])
        // Empty context - should return root level unigram predictions
        XCTAssertFalse(result.isEmpty)
        let tokens = result.map { $0.token }.sorted()
        XCTAssertTrue(tokens.contains("a:X"))
        XCTAssertTrue(tokens.contains("a:Y"))
    }

    func testContextShorterThanMaxDepth() {
        let trie = PpmTrie()
        trie.insert(tokens: ["a:A", "a:B"])
        let result = trie.predict(context: ["a:A"])
        // 1 token context - depth 1 match only
        XCTAssertEqual(result.first?.token, "a:B")
    }

    func testEmptyTrieReturnsEmptyPrediction() {
        let trie = PpmTrie()
        let result = trie.predict(context: ["a:X"])
        XCTAssertTrue(result.isEmpty)
    }

    func testSerializationRoundTrip() throws {
        let trie = PpmTrie()
        trie.insert(tokens: ["a:A", "a:B"])
        trie.insert(tokens: ["a:B", "a:C"])

        let data = try JSONEncoder().encode(trie)
        let loaded = try JSONDecoder().decode(PpmTrie.self, from: data)

        let result1 = loaded.predict(context: ["a:A"])
        XCTAssertEqual(result1.first?.token, "a:B")

        let result2 = loaded.predict(context: ["a:B"])
        XCTAssertEqual(result2.first?.token, "a:C")
    }

    func testInsertWithWeight() {
        let trie = PpmTrie()
        trie.insert(tokens: ["a:A", "a:B"], weight: 2.0)
        let result = trie.predict(context: ["a:A"])
        // Weighted insertion should produce higher counts
        XCTAssertGreaterThan(result.first?.confidence ?? 0, 0)
    }

    func testPruneBelowFloor() {
        let trie = PpmTrie()
        trie.insert(tokens: ["a:A", "a:B"])
        trie.insert(tokens: ["a:A", "a:C"])
        trie.insert(tokens: ["a:A", "a:B"])
        trie.prune(floor: 3)
        // "a:B" appears 2 times, "a:C" appears 1 time — both should be pruned at floor 3
        let result = trie.predict(context: ["a:A"])
        XCTAssertTrue(result.isEmpty)
    }

    func testMultipleTokensMergeAcrossDepths() {
        let trie = PpmTrie()
        // a:B follows [a:A] 3 times
        for _ in 0..<3 {
            trie.insert(tokens: ["a:A", "a:B"])
        }
        // a:B follows [a:A, a:C] 1 time
        trie.insert(tokens: ["a:A", "a:C", "a:B"])

        // Context [a:A, a:C]:
        // depth 2 -> [a:A, a:C] has child a:B with weight 1.0 * 1.0 = 1.0
        // depth 1 -> [a:C] has children? No, a:C only appeared once as the middle token
        // Actually, with our insertion algorithm, each suffix creates nodes.
        // [a:A, a:C, a:B]:
        //   len 3 suffix -> walk root->a:A->a:C->a:B
        //   len 2 suffix -> walk root->a:C->a:B
        //   len 1 suffix -> walk root->a:B
        // So a:C as a unigram context has no direct children (it's a leaf in the len-3 path,
        // not a context node with its own children).
        // Actually, len 2 suffix [a:C, a:B] walks root->a:C, then creates child a:B at node a:C.
        // So node a:C does have child a:B.

        let result = trie.predict(context: ["a:A", "a:C"])
        // Should predict a:B with high confidence
        XCTAssertEqual(result.first?.token, "a:B")
    }

    func testSaveAndLoad() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("ppm_trie.json")

        let trie = PpmTrie()
        trie.insert(tokens: ["a:A", "a:B"])
        try trie.save(to: tempURL)

        let loaded = try PpmTrie.load(from: tempURL)
        let result = loaded.predict(context: ["a:A"])
        XCTAssertEqual(result.first?.token, "a:B")

        try? FileManager.default.removeItem(at: tempURL.deletingLastPathComponent())
    }
}
