import XCTest
@testable import ClearX

final class InMemoryScanCacheTests: XCTestCase {
    func testCachesCompleteResultByRootURL() async {
        let root = URL(fileURLWithPath: "/tmp/clearx-session-cache")
        let source = ScanSource(kind: .folder, rootURL: root)
        let rootNode = ScanNodeSummary(parentID: nil, url: root, kind: .directory, allocatedSize: 8)
        let child = ScanNodeSummary(parentID: rootNode.id, url: root.appending(path: "report"), kind: .file, allocatedSize: 8)
        let cache = InMemoryScanCache()

        await cache.store(ScanResult(source: source, nodes: [rootNode, child], status: .complete))

        let cached = await cache.result(for: ScanSource(kind: .folder, rootURL: root))
        let cachedNodes = await cached?.allNodes()
        XCTAssertEqual(cachedNodes, [rootNode, child])
    }

    func testDoesNotCacheIncompleteResult() async {
        let root = URL(fileURLWithPath: "/tmp/clearx-session-cache-incomplete")
        let source = ScanSource(kind: .folder, rootURL: root)
        let rootNode = ScanNodeSummary(parentID: nil, url: root, kind: .directory, allocatedSize: 0)
        let cache = InMemoryScanCache()

        await cache.store(ScanResult(source: source, nodes: [rootNode], status: .incomplete([.cancelled])))

        let cached = await cache.result(for: source)
        XCTAssertNil(cached)
    }

    func testReleasesCompleteResultWhenLastWindowCloses() async {
        let root = URL(fileURLWithPath: "/tmp/clearx-session-cache-release")
        let source = ScanSource(kind: .folder, rootURL: root)
        let rootNode = ScanNodeSummary(parentID: nil, url: root, kind: .directory, allocatedSize: 1)
        let cache = InMemoryScanCache()

        await cache.retain(source: source)
        await cache.retain(source: source)
        await cache.store(ScanResult(source: source, nodes: [rootNode], status: .complete))
        await cache.release(source: source)

        let cachedWhileOneWindowRemains = await cache.result(for: source)
        XCTAssertNotNil(cachedWhileOneWindowRemains)

        await cache.release(source: source)
        let cached = await cache.result(for: source)
        XCTAssertNil(cached)
    }

    func testIncompleteCandidateDoesNotReplaceCompleteSnapshot() async {
        let root = URL(fileURLWithPath: "/tmp/clearx-session-cache-replacement")
        let source = ScanSource(kind: .folder, rootURL: root)
        let oldRoot = ScanNodeSummary(parentID: nil, url: root, kind: .directory, allocatedSize: 10)
        let newRoot = ScanNodeSummary(parentID: nil, url: root, kind: .directory, allocatedSize: 5, isIncomplete: true)
        let cache = InMemoryScanCache()
        let oldResult = ScanResult(source: source, nodes: [oldRoot], status: .complete)

        let storedOldResult = await cache.store(oldResult)
        let storedIncompleteResult = await cache.store(
            ScanResult(source: source, nodes: [newRoot], status: .incomplete([.cancelled]))
        )
        XCTAssertTrue(storedOldResult)
        XCTAssertFalse(storedIncompleteResult)

        let cached = await cache.result(for: source)
        XCTAssertTrue(cached?.snapshot === oldResult.snapshot)
    }

    func testCacheKeepsSameSnapshotInstance() async {
        let root = URL(fileURLWithPath: "/tmp/clearx-session-cache-identity")
        let source = ScanSource(kind: .folder, rootURL: root)
        let snapshot = ScanTreeStore(snapshotNodes: [ScanNodeSummary(parentID: nil, url: root, kind: .directory, allocatedSize: 0)], status: .complete)
        let result = ScanResult(source: source, snapshot: snapshot, status: .complete, nodeCount: 1)
        let cache = InMemoryScanCache()

        let didStoreResult = await cache.store(result)
        XCTAssertTrue(didStoreResult)

        let cached = await cache.result(for: source)
        XCTAssertTrue(cached?.snapshot === snapshot)
    }
}
