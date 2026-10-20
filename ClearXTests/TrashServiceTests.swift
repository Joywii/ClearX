import XCTest
@testable import ClearX

final class TrashServiceTests: XCTestCase {
    func testComponentOverlapDoesNotConfuseSiblingPrefixes() {
        let root = URL(fileURLWithPath: "/Users/test/data")
        XCTAssertTrue(FileLocation.overlaps(root, root.appendingPathComponent("child")))
        XCTAssertTrue(FileLocation.overlaps(URL(fileURLWithPath: "/"), root))
        XCTAssertFalse(FileLocation.overlaps(root, URL(fileURLWithPath: "/Users/test/database")))
    }

    func testMountProtectionIncludesAncestorsButNotSiblingPrefixesOrLinks() {
        let mount = URL(fileURLWithPath: "/private/tmp/fixture/volume")
        let points = ScanMountPoints(urls: [mount])
        XCTAssertTrue(points.protectsEntry(FileLocation.resolved(mount), includeDescendants: false))
        XCTAssertTrue(points.protectsEntry(FileLocation.resolved(mount.deletingLastPathComponent()), includeDescendants: true))
        XCTAssertFalse(points.protectsEntry(FileLocation.resolved(mount.deletingLastPathComponent()), includeDescendants: false))
        XCTAssertFalse(points.protectsEntry(FileLocation.resolved(URL(fileURLWithPath: "/private/tmp/fixture/vol")), includeDescendants: true))
    }

    func testSymlinkIdentityRefersToLinkNotTarget() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let link = directory.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory.appendingPathComponent("missing"))
        XCTAssertEqual(FileLocation.entry(link).lastPathComponent, "link")
        let node = ScanNodeSummary(parentID: nil, url: link, kind: .symbolicLink, allocatedSize: 0)
        let assessment = TrashService.inspect([node], root: directory)
        XCTAssertNil(assessment.disabledReason, assessment.disabledReason ?? "")
        XCTAssertEqual(assessment.targets.first?.node.url, link)
    }

    func testTrashDirectoryIsProhibitedWithoutChangingItsContents() {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
        let node = ScanNodeSummary(parentID: nil, url: url, kind: .directory, allocatedSize: 0)
        let result = TrashService.inspect([node], root: URL(fileURLWithPath: "/"))
        XCTAssertNotNil(result.disabledReason)
    }

    func testRootMountMissingAndWholeBatchAreProhibited() {
        let root = URL(fileURLWithPath: NSHomeDirectory())
        let node = ScanNodeSummary(parentID: nil, url: root, kind: .directory, allocatedSize: 0)
        XCTAssertNotNil(TrashService.inspect([node], root: root).disabledReason)
        let mount = ScanNodeSummary(parentID: nil, url: URL(fileURLWithPath: "/"), kind: .mountPoint, allocatedSize: 0)
        XCTAssertNotNil(TrashService.inspect([node, mount], root: URL(fileURLWithPath: "/tmp")).disabledReason)
        let missing = ScanNodeSummary(parentID: nil, url: root.appendingPathComponent(UUID().uuidString), kind: .file, allocatedSize: 0)
        XCTAssertNotNil(TrashService.inspect([missing], root: root).disabledReason)
    }

    func testActualPreflightAllowsOwnedFileWithoutMovingIt() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("owned-file")
        try Data("test".utf8).write(to: url)
        let node = ScanNodeSummary(parentID: nil, url: url, kind: .file, allocatedSize: 4)
        let assessment = TrashService.inspect([node], root: directory)
        XCTAssertNil(assessment.disabledReason, assessment.disabledReason ?? "")
        XCTAssertEqual(assessment.targets.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testExecutionContinuesAfterFailureAndNeverRetriesOrDeletes() async {
        let recorder = MoveRecorder()
        let service = TrashService(coordinator: ScanCoordinator(), cache: InMemoryScanCache(),
                                   inspect: Self.allow, move: { url in try recorder.move(url) })
        let nodes = makeNodes()
        let report = await service.execute(Self.allow(nodes, URL(fileURLWithPath: "/")).targets, root: URL(fileURLWithPath: "/"))
        XCTAssertEqual(report.succeeded, [nodes[0].url, nodes[2].url])
        XCTAssertEqual(report.failures.map(\.url), [nodes[1].url])
        XCTAssertEqual(report.unprocessed, 0)
        XCTAssertEqual(recorder.urls, nodes.map(\.url))
    }

    func testIdentityChangeRejectsEntireBatchBeforeAnyMove() async {
        let recorder = MoveRecorder()
        let nodes = makeNodes()
        let service = TrashService(coordinator: ScanCoordinator(), cache: InMemoryScanCache(), inspect: { nodes, _ in
            TrashAssessment(targets: nodes.map { TrashTarget(node: $0, device: 1, inode: 2) }, disabledReason: nil)
        }, move: { try recorder.move($0) })
        let report = await service.execute(Self.allow(nodes, URL(fileURLWithPath: "/")).targets, root: URL(fileURLWithPath: "/"))
        XCTAssertTrue(recorder.urls.isEmpty)
        XCTAssertEqual(report.failures.count, 3)
    }

    func testStopLeavesRemainingItemsUnprocessed() async {
        let recorder = MoveRecorder()
        let service = TrashService(coordinator: ScanCoordinator(), cache: InMemoryScanCache(),
                                   inspect: Self.allow, move: { try recorder.move($0) })
        let targets = Self.allow(makeNodes(), URL(fileURLWithPath: "/")).targets
        let task = Task {
            await service.execute(targets, root: URL(fileURLWithPath: "/")) { count in
                if count == 1 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        let report = await task.value
        XCTAssertEqual(report.succeeded.count, 1)
        XCTAssertEqual(report.unprocessed, 2)
        XCTAssertEqual(recorder.urls.count, 1)
    }

    func testSuccessInvalidatesRelatedCachesOnly() async {
        let cache = InMemoryScanCache()
        let nodes = makeNodes()
        let root = nodes[0].url.deletingLastPathComponent()
        let related = ScanSource(kind: .folder, rootURL: root)
        let unrelated = ScanSource(kind: .folder, rootURL: URL(fileURLWithPath: "/private/tmp/unrelated"))
        for source in [related, unrelated] {
            let node = ScanNodeSummary(parentID: nil, url: source.rootURL, kind: .directory, allocatedSize: 0)
            await cache.store(ScanResult(source: source, nodes: [node], status: .complete))
        }
        let service = TrashService(coordinator: ScanCoordinator(), cache: cache, inspect: Self.allow, move: { _ in })
        _ = await service.execute(Self.allow([nodes[0]], root).targets, root: root)
        let stale = await cache.result(for: related)
        let retained = await cache.result(for: unrelated)
        XCTAssertNil(stale)
        XCTAssertNotNil(retained)
    }

    func testActiveAncestorScanBlocksTrashAcrossWindows() async throws {
        let coordinator = ScanCoordinator()
        let source = ScanSource(kind: .folder, rootURL: URL(fileURLWithPath: "/private/tmp/clearx-test"))
        let scanner = PausedTrashTestScanner()
        let scan = Task {
            try await coordinator.performScan(source: source, request: ScanRequest(rootURL: source.rootURL, sourceID: source.id), scanner: scanner,
                                               publishResult: { _ in
                let duringPublication = await coordinator.fileOperationBlockReason(for: [source.rootURL.appendingPathComponent("child")])
                XCTAssertNotNil(duringPublication, "Cache publication must still hold the scan range")
            })
        }
        await scanner.waitForStart()
        let blocked = await coordinator.fileOperationBlockReason(for: [source.rootURL.appendingPathComponent("child")])
        XCTAssertNotNil(blocked)
        let unrelated = await coordinator.fileOperationBlockReason(for: [URL(fileURLWithPath: "/private/tmp/clearx-other")])
        XCTAssertNil(unrelated)
        await scanner.finish()
        _ = try await scan.value
        let available = await coordinator.fileOperationBlockReason(for: [source.rootURL.appendingPathComponent("child")])
        XCTAssertNil(available)
    }

    func testWaitingScanCanBeCancelledWithoutWaitingForTrashToFinish() async throws {
        let coordinator = ScanCoordinator()
        let source = ScanSource(kind: .folder, rootURL: URL(fileURLWithPath: "/private/tmp/clearx-waiting"))
        let operation = await coordinator.beginFileOperation(urls: [source.rootURL.appendingPathComponent("file")])
        let lease = try XCTUnwrap(operation)
        let scan = Task {
            try await coordinator.performScan(source: source, request: ScanRequest(rootURL: source.rootURL, sourceID: source.id), scanner: PausedTrashTestScanner())
        }
        try await Task.sleep(for: .milliseconds(30))
        scan.cancel()
        do {
            _ = try await scan.value
            XCTFail("Cancelled waiting scan must not start")
        } catch { XCTAssertTrue(error is CancellationError) }
        await coordinator.endFileOperation(lease)
    }

    func testOverlappingOperationsAreRejectedButSiblingsAreAllowed() async throws {
        let coordinator = ScanCoordinator()
        let root = URL(fileURLWithPath: "/private/tmp/clearx-operation")
        let first = await coordinator.beginFileOperation(urls: [root])
        let lease = try XCTUnwrap(first)
        let blocked = await coordinator.beginFileOperation(urls: [root.appendingPathComponent("child")])
        XCTAssertNil(blocked)
        let sibling = await coordinator.beginFileOperation(urls: [URL(fileURLWithPath: "/private/tmp/clearx-operation-other")])
        XCTAssertNotNil(sibling)
        await coordinator.endFileOperation(lease)
        let reason = await coordinator.fileOperationBlockReason(for: [root])
        XCTAssertNil(reason)
        if let sibling { await coordinator.endFileOperation(sibling) }
    }

    private func makeNodes() -> [ScanNodeSummary] {
        ["one", "fail", "three"].map {
            ScanNodeSummary(parentID: nil, url: URL(fileURLWithPath: "/private/tmp/clearx-test/\($0)"), kind: .file, allocatedSize: 0)
        }
    }

    private static func allow(_ nodes: [ScanNodeSummary], _ root: URL) -> TrashAssessment {
        TrashAssessment(targets: nodes.map { TrashTarget(node: $0, device: 1, inode: 1) }, disabledReason: nil)
    }
}

private actor PausedTrashTestScanner: FileTreeScanning {
    private var started = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var finishWaiter: CheckedContinuation<Void, Never>?
    func waitForStart() async {
        if !started { await withCheckedContinuation { startWaiter = $0 } }
    }
    func finish() { finishWaiter?.resume(); finishWaiter = nil }
    func scan(source: ScanSource, request: ScanRequest, progress: (@Sendable (ScanProgress) async -> Void)?) async throws -> ScanResult {
        await withCheckedContinuation {
            finishWaiter = $0
            started = true
            startWaiter?.resume()
            startWaiter = nil
        }
        let root = ScanNodeSummary(parentID: nil, url: source.rootURL, kind: .directory, allocatedSize: 0)
        return ScanResult(source: source, nodes: [root], status: .complete)
    }
}

private final class MoveRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URL] = []
    var urls: [URL] { lock.withLock { recorded } }
    func move(_ url: URL) throws {
        lock.withLock { recorded.append(url) }
        if url.lastPathComponent == "fail" { throw CocoaError(.fileWriteNoPermission) }
    }
}
