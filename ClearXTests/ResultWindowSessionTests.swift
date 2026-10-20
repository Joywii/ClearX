import XCTest
@testable import ClearX

@MainActor
final class ResultWindowSessionTests: XCTestCase {
    func testTrashRescanPreservesStaleSnapshotUntilCompleteReplacement() async {
        let source = ScanSource(kind: .folder, rootURL: URL(fileURLWithPath: "/private/tmp/clearx-session"))
        let root = ScanNodeSummary(parentID: nil, url: source.rootURL, kind: .directory, allocatedSize: 10)
        let child = ScanNodeSummary(parentID: root.id, url: source.rootURL.appendingPathComponent("child"), kind: .file, allocatedSize: 10)
        let old = ScanResult(source: source, nodes: [root, child], status: .complete)
        let partial = ScanResult(source: source, nodes: [root], status: .incomplete([.cancelled]))
        let fresh = ScanResult(source: source, nodes: [root], status: .complete)
        let scanner = SessionSequenceScanner(results: [old, partial, fresh])
        let cache = InMemoryScanCache()
        let session = ResultWindowSession(source: source, cache: cache, coordinator: ScanCoordinator(), makeScanner: { _ in scanner })
        session.beginIfNeeded()
        await session.scanTask?.value
        XCTAssertEqual(session.browser.columns.first?.nodes.map(\.id), [child.id])
        await cache.invalidate(overlapping: [child.url])
        await session.filesWereTrashed([child.url])
        await session.scanTask?.value
        XCTAssertTrue(session.browser.isStale)
        XCTAssertEqual(session.browser.columns.first?.nodes.map(\.id), [child.id])
        XCTAssertTrue(session.browser.scanNotice?.contains("过期") == true)
        XCTAssertTrue(session.browser.scanNotice?.contains("取消") == true)
        let invalidated = await cache.result(for: source)
        XCTAssertNil(invalidated)
        session.rescanCompletely()
        await session.scanTask?.value
        XCTAssertFalse(session.browser.isStale)
        XCTAssertEqual(session.browser.columns.first?.nodes.count, 0)
        let replacement = await cache.result(for: source)
        XCTAssertTrue(replacement?.snapshot === fresh.snapshot)
        session.end()
    }
}

private actor SessionSequenceScanner: FileTreeScanning {
    var results: [ScanResult]
    init(results: [ScanResult]) { self.results = results }
    func scan(source: ScanSource, request: ScanRequest, progress: (@Sendable (ScanProgress) async -> Void)?) async throws -> ScanResult {
        results.removeFirst()
    }
}
