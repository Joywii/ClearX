import XCTest
@testable import ClearX

final class InMemoryScanCacheTests: XCTestCase {
    @MainActor
    func testSummaryFollowsDisplayedSnapshotDuringRescanAndReplacement() async throws {
        let url = URL(fileURLWithPath: "/fixture")
        let source = ScanSource(kind: .folder, rootURL: url)
        let root = ScanNodeSummary(parentID: nil, url: url, kind: .directory, allocatedSize: 8_192)
        let file = ScanNodeSummary(parentID: root.id, url: url.appending(path: "link"), kind: .file,
                                   allocatedSize: 4_096, isHardLink: true)
        let old = ScanResult(source: source, nodes: [root, file], status: .complete, uniqueAllocatedSize: 4_096)
        let candidateRoot = ScanNodeSummary(parentID: nil, url: url, kind: .directory, allocatedSize: 1_024, isIncomplete: true)
        let candidate = ScanResult(source: source, nodes: [candidateRoot], status: .incomplete([.cancelled]), uniqueAllocatedSize: 512)
        let cache = InMemoryScanCache()
        await cache.retain(source: source)
        await cache.store(old)
        let cached = await cache.result(for: source)
        XCTAssertTrue(cached?.snapshot === old.snapshot)
        let displayed = DisplayedScanSnapshot()
        await displayed.set(old.snapshot)
        let model = ResultBrowserModel(source: source, columnLoader: InMemorySnapshotColumnLoader(displayedSnapshot: displayed))
        await model.loadInitialColumn()
        XCTAssertEqual(model.sizeSummary?.contentAllocatedSize, 8_192)
        XCTAssertEqual(model.sizeSummary?.uniqueAllocatedSize, 4_096)
        model.updatePresentationState(.scanning(ScanProgress(discoveredNodeCount: 1, completedDirectoryCount: 0, currentURL: nil)), displayingPreviousResult: true)
        await model.refreshAllColumns()
        XCTAssertEqual(model.sizeSummaryStatus, "上次完整结果")
        XCTAssertEqual(model.sizeSummary?.isScanning, false)
        let accepted = await cache.store(candidate)
        XCTAssertFalse(accepted)
        model.updatePresentationState(.completed(candidate.status), displayingPreviousResult: true)
        await model.refreshAllColumns()
        XCTAssertEqual(model.sizeSummary?.uniqueAllocatedSize, 4_096)
        XCTAssertEqual(model.sizeSummary?.isIncomplete, false)

        // A first scan without an older complete result displays the partial tree.
        await displayed.set(candidate.snapshot)
        model.updatePresentationState(.completed(candidate.status), displayingPreviousResult: false)
        await model.loadInitialColumn(resetNavigation: true)
        XCTAssertEqual(model.sizeSummary?.contentAllocatedSize, 1_024)
        XCTAssertEqual(model.sizeSummary?.uniqueAllocatedSize, 512)
        XCTAssertEqual(model.sizeSummaryStatus, "部分结果，统计不完整")

        let replacementRoot = ScanNodeSummary(parentID: nil, url: url, kind: .directory, allocatedSize: 16_384)
        let replacement = ScanResult(source: source, nodes: [replacementRoot], status: .complete, uniqueAllocatedSize: 8_192)
        await cache.store(replacement)
        await displayed.set(replacement.snapshot)
        model.updatePresentationState(.completed(.complete), displayingPreviousResult: false)
        await model.loadInitialColumn(resetNavigation: true)
        XCTAssertEqual(model.sizeSummary?.contentAllocatedSize, 16_384)
        XCTAssertEqual(model.sizeSummary?.uniqueAllocatedSize, 8_192)
        XCTAssertEqual(model.sizeSummaryStatus, "完整结果")
        await cache.release(source: source)
        let released = await cache.result(for: source)
        XCTAssertNil(released)
    }

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
