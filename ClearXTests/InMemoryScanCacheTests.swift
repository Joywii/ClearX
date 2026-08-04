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
        XCTAssertEqual(cached?.nodes, [rootNode, child])
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
        await cache.store(ScanResult(source: source, nodes: [rootNode], status: .complete))
        await cache.release(source: source)

        let cached = await cache.result(for: source)
        XCTAssertNil(cached)
    }
}
