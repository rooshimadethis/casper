import XCTest
@testable import Casper

final class MicroStoreTests: XCTestCase {

    func testRecordAndRetrieve() {
        let store = MicroStore()
        store.record(value: "killall Finder", forContext: "ctx")
        let result = store.predict(for: "ctx")
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.value, "killall Finder")
        XCTAssertEqual(result.first?.count, 1)
    }

    func testMultipleValuesSortedByCount() {
        let store = MicroStore()
        for _ in 0..<5 { store.record(value: "a", forContext: "ctx") }
        for _ in 0..<3 { store.record(value: "b", forContext: "ctx") }
        store.record(value: "c", forContext: "ctx")
        let result = store.predict(for: "ctx")
        XCTAssertEqual(result.map(\.value), ["a", "b", "c"])
        XCTAssertEqual(result.map(\.count), [5, 3, 1])
    }

    func testUnknownContextReturnsEmpty() {
        let store = MicroStore()
        let result = store.predict(for: "nonexistent")
        XCTAssertTrue(result.isEmpty)
    }

    func testWeightedInsertion() {
        let store = MicroStore()
        store.record(value: "a", forContext: "ctx", weight: 3)
        let result = store.predict(for: "ctx")
        XCTAssertEqual(result.first?.count, 3)
    }

    func testCountFloorPrunesRareValues() {
        let store = MicroStore()
        for _ in 0..<5 { store.record(value: "a", forContext: "ctx") }
        store.record(value: "b", forContext: "ctx")
        store.prune(floor: 3)
        let result = store.predict(for: "ctx")
        XCTAssertEqual(result.map(\.value), ["a"])
        XCTAssertEqual(result.first?.count, 5)
    }

    func testPruneRemovesEmptyContext() {
        let store = MicroStore()
        store.record(value: "a", forContext: "ctx1", weight: 2)
        store.prune(floor: 3)
        let result = store.predict(for: "ctx1")
        XCTAssertTrue(result.isEmpty)
    }

    func testSerializationRoundTrip() throws {
        let store = MicroStore()
        store.record(value: "a", forContext: "ctx1")
        store.record(value: "b", forContext: "ctx1")
        store.record(value: "x", forContext: "ctx2")

        let data = try JSONEncoder().encode(store)
        let loaded = try JSONDecoder().decode(MicroStore.self, from: data)

        let result1 = loaded.predict(for: "ctx1")
        XCTAssertEqual(result1.map(\.value).sorted(), ["a", "b"])

        let result2 = loaded.predict(for: "ctx2")
        XCTAssertEqual(result2.first?.value, "x")
    }

    func testEmptyStore() {
        let store = MicroStore()
        XCTAssertTrue(store.predict(for: "anything").isEmpty)
        XCTAssertTrue(store.predict(for: "").isEmpty)
    }

    func testConcurrentWrites() {
        let store = MicroStore()
        let queue = DispatchQueue(label: "test.concurrent", attributes: .concurrent)
        let group = DispatchGroup()
        let iterations = 500

        for i in 0..<iterations {
            queue.async(group: group) {
                store.record(value: "v\(i % 10)", forContext: "ctx")
            }
        }

        group.wait()

        let result = store.predict(for: "ctx")
        let totalCount = result.reduce(0) { $0 + $1.count }
        XCTAssertEqual(totalCount, iterations)
    }
}
