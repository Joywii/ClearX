import Darwin
import XCTest
@testable import ClearX

final class FileTreeScannerTests: XCTestCase {
    func testScannerAggregatesDirectoriesAndExcludesSymlinks() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appending(path: "nested", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(atPath: nested.appending(path: "large.bin").path, contents: Data(repeating: 7, count: 8_192)))
        XCTAssertEqual(symlink("nested", root.appending(path: "linked-nested").path), 0)

        let source = ScanSource(kind: .folder, rootURL: root)
        let result = try await FileTreeScanner().scan(source: source, request: ScanRequest(rootURL: root, sourceID: source.id))

        XCTAssertEqual(result.status, .complete)
        XCTAssertFalse(result.nodes.contains { $0.name == "linked-nested" })
        let rootNode = try XCTUnwrap(result.rootNode)
        let nestedNode = try XCTUnwrap(result.nodes.first { $0.name == "nested" })
        XCTAssertEqual(rootNode.allocatedSize, nestedNode.allocatedSize)
    }

    func testScannerCountsHardLinkedFileOnce() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appending(path: "first.bin")
        let second = root.appending(path: "second.bin")
        XCTAssertTrue(FileManager.default.createFile(atPath: first.path, contents: Data(repeating: 3, count: 4_096)))
        XCTAssertEqual(link(first.path, second.path), 0)

        let source = ScanSource(kind: .folder, rootURL: root)
        let result = try await FileTreeScanner().scan(source: source, request: ScanRequest(rootURL: root, sourceID: source.id))
        let linkedNodes = result.nodes.filter { $0.name == "first.bin" || $0.name == "second.bin" }

        XCTAssertEqual(linkedNodes.count, 2)
        XCTAssertEqual(linkedNodes.filter(\.countsTowardAllocatedSize).count, 1)
        XCTAssertEqual(linkedNodes.map(\.allocatedSize).reduce(0, +), try XCTUnwrap(result.rootNode).allocatedSize)
    }

    func testScannerMarksMissingRootIncomplete() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: UUID().uuidString)
        let source = ScanSource(kind: .folder, rootURL: root)

        let result = try await FileTreeScanner().scan(source: source, request: ScanRequest(rootURL: root, sourceID: source.id))

        XCTAssertEqual(result.status, .incomplete([.sourceUnavailable]))
        XCTAssertTrue(try XCTUnwrap(result.rootNode).isIncomplete)
    }

    func testScannerKeepsAccessibleSiblingsWhenDirectoryIsUnreadable() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let blocked = root.appending(path: "blocked", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(atPath: root.appending(path: "visible.bin").path, contents: Data(repeating: 1, count: 512)))
        XCTAssertEqual(chmod(blocked.path, 0), 0)
        defer { _ = chmod(blocked.path, S_IRWXU) }

        let source = ScanSource(kind: .folder, rootURL: root)
        let result = try await FileTreeScanner().scan(source: source, request: ScanRequest(rootURL: root, sourceID: source.id))

        XCTAssertTrue(result.nodes.contains { $0.name == "visible.bin" })
        XCTAssertEqual(result.status, .incomplete([.unreadableItem]))
    }

    func testScannerPublishesIncrementalNodesAndCompletedDirectories() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appending(path: "nested", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(atPath: nested.appending(path: "item.bin").path, contents: Data(repeating: 4, count: 2_048)))

        let source = ScanSource(kind: .folder, rootURL: root)
        let collector = ScanProgressCollector()
        _ = try await FileTreeScanner().scan(
            source: source,
            request: ScanRequest(rootURL: root, sourceID: source.id),
            progress: { progress in await collector.append(progress) }
        )

        let progress = await collector.values()
        XCTAssertTrue(progress.contains { $0.updatedNodes.contains(where: { $0.name == "item.bin" }) })
        XCTAssertTrue(progress.contains { $0.completedDirectoryURLs.contains(root.standardizedFileURL) })
        XCTAssertTrue(progress.allSatisfy { $0.completedDirectoryCount <= 2 })
    }

    func testScannerAggregatesDeepDirectoriesOncePerLevel() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appending(path: "first", directoryHint: .isDirectory)
        let second = first.appending(path: "second", directoryHint: .isDirectory)
        let third = second.appending(path: "third", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: third, withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(atPath: root.appending(path: "root.bin").path, contents: Data(repeating: 1, count: 4_096)))
        XCTAssertTrue(FileManager.default.createFile(atPath: third.appending(path: "leaf.bin").path, contents: Data(repeating: 2, count: 8_192)))

        let source = ScanSource(kind: .folder, rootURL: root)
        let result = try await FileTreeScanner().scan(source: source, request: ScanRequest(rootURL: root, sourceID: source.id))
        let rootNode = try XCTUnwrap(result.rootNode)
        let firstNode = try XCTUnwrap(result.nodes.first { $0.name == "first" })
        let secondNode = try XCTUnwrap(result.nodes.first { $0.name == "second" })
        let thirdNode = try XCTUnwrap(result.nodes.first { $0.name == "third" })
        let rootFile = try XCTUnwrap(result.nodes.first { $0.name == "root.bin" })
        let leafFile = try XCTUnwrap(result.nodes.first { $0.name == "leaf.bin" })

        XCTAssertEqual(thirdNode.allocatedSize, leafFile.allocatedSize)
        XCTAssertEqual(secondNode.allocatedSize, thirdNode.allocatedSize)
        XCTAssertEqual(firstNode.allocatedSize, secondNode.allocatedSize)
        XCTAssertEqual(rootNode.allocatedSize, rootFile.allocatedSize + firstNode.allocatedSize)
    }

    func testImmediatelyCancelledScanReturnsIncompletePartialTree() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appending(path: "nested", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(atPath: nested.appending(path: "item.bin").path, contents: Data(repeating: 3, count: 4_096)))

        let source = ScanSource(kind: .folder, rootURL: root)
        let task = Task {
            try await FileTreeScanner().scan(source: source, request: ScanRequest(rootURL: root, sourceID: source.id))
        }
        task.cancel()
        let result = try await task.value

        guard case let .incomplete(reasons) = result.status else {
            return XCTFail("Expected cancellation to keep an incomplete result")
        }
        XCTAssertTrue(reasons.contains(.cancelled))
        XCTAssertTrue(try XCTUnwrap(result.rootNode).isIncomplete)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "ClearXTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

final class DirectoryWorkQueueTests: XCTestCase {
    func testPerformanceMetricsMergeStageTotalsAndSlowestSamples() {
        var first = ScanWorkerPerformanceMetrics(workerID: 0, startedAtNanos: 1)
        first.recordEnumeration(
            DirectoryEnumerationPerformanceSample(childCount: 10, listingNanos: 20, metadataNanos: 30, isUnreadable: false),
            depth: 2,
            permitAndEnumerationNanos: 80
        )
        first.recordAccumulatorApply(nanos: 40, depth: 2, childCount: 10)
        var second = ScanWorkerPerformanceMetrics(workerID: 1, startedAtNanos: 1)
        second.recordEnumeration(
            DirectoryEnumerationPerformanceSample(childCount: 3, listingNanos: 50, metadataNanos: 60, isUnreadable: true),
            depth: 4,
            permitAndEnumerationNanos: 150
        )
        second.recordAccumulatorApply(nanos: 70, depth: 4, childCount: 3)

        first.merge(second)

        XCTAssertEqual(first.directoryCount, 2)
        XCTAssertEqual(first.discoveredItemCount, 13)
        XCTAssertEqual(first.unreadableDirectoryCount, 1)
        XCTAssertEqual(first.listingNanos, 70)
        XCTAssertEqual(first.metadataNanos, 90)
        XCTAssertEqual(first.permitWaitNanos, 70)
        XCTAssertEqual(first.accumulatorApplyNanos, 110)
        XCTAssertEqual(first.slowestEnumeration.depth, 4)
        XCTAssertEqual(first.slowestAccumulatorApply.depth, 4)
    }

    func testRingFIFOUsesFIFOOrderAcrossWrapAndGrowth() {
        var queue = RingFIFO<Int>(minimumCapacity: 2)
        queue.append(1)
        queue.append(2)
        XCTAssertEqual(queue.popFirst(), 1)
        queue.append(3)
        queue.append(4)

        XCTAssertEqual(queue.popFirst(), 2)
        XCTAssertEqual(queue.popFirst(), 3)
        XCTAssertEqual(queue.popFirst(), 4)
        XCTAssertNil(queue.popFirst())
    }

    func testFocusChangeLazilyPromotesExactQueuedDirectory() async {
        let sourceID = ScanSourceID()
        let coordinator = ScanCoordinator()
        let queue = DirectoryWorkQueue(sourceID: sourceID, coordinator: coordinator)
        let root = URL(fileURLWithPath: "/tmp/clearx-queue")
        let first = DirectoryWork(nodeID: ScanNodeID(), url: root.appending(path: "first"), depth: 1)
        let focused = DirectoryWork(nodeID: ScanNodeID(), url: root.appending(path: "focused"), depth: 1)
        await queue.enqueue([first, focused])

        await coordinator.prioritize(directory: focused.url, for: sourceID)

        let promotedWork = await queue.next()
        XCTAssertEqual(promotedWork?.nodeID, focused.nodeID)
        await queue.completeCurrentWork()
        let remainingWork = await queue.next()
        XCTAssertEqual(remainingWork?.nodeID, first.nodeID)
        await queue.completeCurrentWork()
        let performance = await queue.performanceSnapshot()
        XCTAssertEqual(performance.enqueuedCount, 2)
        XCTAssertEqual(performance.dequeuedCount, 2)
        XCTAssertEqual(performance.peakPendingCount, 2)
        XCTAssertEqual(performance.focusPromotionCount, 1)
        XCTAssertEqual(performance.staleEntryCount, 1)
    }

    func testNewFocusRunsBeforeRetiredFocusWithoutDroppingOldWork() async {
        let sourceID = ScanSourceID()
        let coordinator = ScanCoordinator()
        let queue = DirectoryWorkQueue(sourceID: sourceID, coordinator: coordinator)
        let root = URL(fileURLWithPath: "/tmp/clearx-focus-switch")
        let oldFocusRoot = root.appending(path: "old")
        let oldFocusedWork = DirectoryWork(nodeID: ScanNodeID(), url: oldFocusRoot.appending(path: "child"), depth: 2)
        let newFocusedWork = DirectoryWork(nodeID: ScanNodeID(), url: root.appending(path: "new"), depth: 1)
        await coordinator.prioritize(directory: oldFocusRoot, for: sourceID)
        await queue.enqueue([oldFocusedWork, newFocusedWork])

        await coordinator.prioritize(directory: newFocusedWork.url, for: sourceID)

        let promotedWork = await queue.next()
        XCTAssertEqual(promotedWork?.nodeID, newFocusedWork.nodeID)
        await queue.completeCurrentWork()
        let retiredWork = await queue.next()
        XCTAssertEqual(retiredWork?.nodeID, oldFocusedWork.nodeID)
        await queue.completeCurrentWork()
    }

    func testFocusedQueueYieldsToBackgroundAfterEightTasks() async {
        let sourceID = ScanSourceID()
        let coordinator = ScanCoordinator()
        let queue = DirectoryWorkQueue(sourceID: sourceID, coordinator: coordinator)
        let root = URL(fileURLWithPath: "/tmp/clearx-fairness")
        let focusRoot = root.appending(path: "focus")
        await coordinator.prioritize(directory: focusRoot, for: sourceID)
        let focused = (0..<9).map {
            DirectoryWork(nodeID: ScanNodeID(), url: focusRoot.appending(path: "child-\($0)"), depth: 2)
        }
        let background = DirectoryWork(nodeID: ScanNodeID(), url: root.appending(path: "background"), depth: 1)
        await queue.enqueue(focused + [background])

        var dequeued = [ScanNodeID]()
        for _ in 0..<9 {
            if let work = await queue.next() {
                dequeued.append(work.nodeID)
                await queue.completeCurrentWork()
            }
        }

        XCTAssertEqual(Array(dequeued.prefix(8)), focused.prefix(8).map(\.nodeID))
        XCTAssertEqual(dequeued[8], background.nodeID)
    }

    func testConcurrentWorkerCompletionDoesNotDoubleResumeWaitingWorkers() async {
        let sourceID = ScanSourceID()
        let queue = DirectoryWorkQueue(sourceID: sourceID, coordinator: ScanCoordinator())
        let root = URL(fileURLWithPath: "/tmp/clearx-waiter-stress")
        let initial = DirectoryWork(nodeID: ScanNodeID(), url: root, depth: 0)
        await queue.enqueue([initial])
        let initialWork = await queue.next()
        XCTAssertEqual(initialWork?.nodeID, initial.nodeID)

        let workers = (0..<8).map { _ in
            Task {
                var processed = 0
                while await queue.next() != nil {
                    processed += 1
                    await queue.completeCurrentWork()
                }
                return processed
            }
        }
        for _ in 0..<16 {
            await Task.yield()
        }

        let work = (0..<512).map { index in
            DirectoryWork(
                nodeID: ScanNodeID(),
                url: root.appending(path: "child-\(index)"),
                depth: 1
            )
        }
        await queue.enqueue(work)
        await queue.completeCurrentWork()

        var processed = 0
        for worker in workers {
            processed += await worker.value
        }
        XCTAssertEqual(processed, work.count)
        let performance = await queue.performanceSnapshot()
        XCTAssertEqual(performance.dequeuedCount, work.count + 1)
    }

    func testProgressPublisherPullsPeriodicSnapshotsAndPublishesFinalImmediately() async throws {
        let collector = ScanProgressCollector()
        let first = ScanProgress(discoveredNodeCount: 1, completedDirectoryCount: 0, currentURL: nil)
        let second = ScanProgress(discoveredNodeCount: 2, completedDirectoryCount: 1, currentURL: nil)
        let final = ScanProgress(discoveredNodeCount: 3, completedDirectoryCount: 2, currentURL: nil)
        let source = ScanProgressSource(first)
        let publisher = ProgressPublisher(
            publicationInterval: .milliseconds(10),
            snapshot: { await source.value() },
            sink: { progress in await collector.append(progress) }
        )

        await publisher.publish()
        let leadingValues = await collector.values()
        XCTAssertEqual(leadingValues.map(\.discoveredNodeCount), [1])

        await source.set(second)
        let periodicTask = Task { await publisher.publishPeriodically() }
        try await Task.sleep(for: .milliseconds(30))
        periodicTask.cancel()
        await periodicTask.value

        await source.set(final)
        await publisher.publish()
        let values = await collector.values()
        XCTAssertTrue(values.dropFirst().dropLast().contains { $0.discoveredNodeCount == 2 })
        XCTAssertEqual(values.last?.discoveredNodeCount, 3)
    }
}

private actor ScanProgressSource {
    private var progress: ScanProgress

    init(_ progress: ScanProgress) {
        self.progress = progress
    }

    func set(_ progress: ScanProgress) {
        self.progress = progress
    }

    func value() -> ScanProgress {
        progress
    }
}

private actor ScanProgressCollector {
    private var progress = [ScanProgress]()

    func append(_ value: ScanProgress) {
        progress.append(value)
    }

    func values() -> [ScanProgress] {
        progress
    }
}
