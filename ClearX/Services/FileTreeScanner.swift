import Darwin
import Foundation

/// Breadth-first scanner that keeps the disk I/O budget in `ScanCoordinator`.
/// Tree mutation lives in an actor because up to four directory workers may
/// discover siblings concurrently for the same source.
struct FileTreeScanner: FileTreeScanning {
    private let workersPerSource = 8

    func scan(source: ScanSource, request: ScanRequest, progress: (@Sendable (ScanProgress) async -> Void)? = nil) async throws -> ScanResult {
        let collectsPerformanceMetrics = ScanPerformanceDiagnostics.isEnabled
        let scanID = ScanPerformanceDiagnostics.makeScanID()
        let scanStartedAt = ScanPerformanceDiagnostics.now()
        let rootURL = request.rootURL.standardizedFileURL
        guard let rootStatus = Self.fileStatus(at: rootURL), !rootStatus.isSymbolicLink else {
            return ScanResult(source: source, nodes: [Self.rootNode(for: rootURL, incomplete: true)], status: .incomplete([.sourceUnavailable]))
        }

        let root = WorkingNode(
            id: ScanNodeID(),
            parentID: nil,
            url: rootURL,
            kind: rootStatus.isDirectory ? .directory : .file,
            allocatedSize: 0,
            countsTowardAllocatedSize: true,
            isIncomplete: false
        )
        let state = ScanAccumulator(root: root)
        let publisher = ProgressPublisher(
            snapshot: { await state.takeProgress() },
            sink: progress
        )

        guard rootStatus.isDirectory else {
            await state.setRootFileSize(from: rootStatus)
            await publisher.publish()
            return await state.result(for: source)
        }

        await publisher.publish()
        let progressTask = Task {
            await publisher.publishPeriodically()
        }
        let queue = DirectoryWorkQueue(sourceID: source.id, coordinator: .shared)
        await queue.enqueue([DirectoryWork(nodeID: root.id, url: rootURL, depth: 0)])

        var combinedMetrics = ScanWorkerPerformanceMetrics(workerID: -1, startedAtNanos: scanStartedAt)
        await withTaskGroup(of: ScanWorkerPerformanceMetrics.self) { group in
            for workerID in 0..<workersPerSource {
                group.addTask {
                    await Self.runWorker(
                        workerID: workerID,
                        scanID: scanID,
                        collectsPerformanceMetrics: collectsPerformanceMetrics,
                        sourceID: source.id,
                        expectedDevice: rootStatus.deviceID,
                        queue: queue,
                        state: state
                    )
                }
            }
            for await metrics in group {
                combinedMetrics.merge(metrics)
            }
        }
        progressTask.cancel()
        await progressTask.value

        let finalizationStartedAt = collectsPerformanceMetrics ? ScanPerformanceDiagnostics.now() : 0
        await state.finalizeCancelledDirectories()
        let finalizationNanos = collectsPerformanceMetrics ? ScanPerformanceDiagnostics.elapsed(since: finalizationStartedAt) : 0
        await publisher.publish()

        let resultStartedAt = collectsPerformanceMetrics ? ScanPerformanceDiagnostics.now() : 0
        let result = await state.result(for: source)
        let resultMaterializationNanos = collectsPerformanceMetrics ? ScanPerformanceDiagnostics.elapsed(since: resultStartedAt) : 0
        if collectsPerformanceMetrics {
            let queueSnapshot = await queue.performanceSnapshot()
            let publisherSnapshot = await publisher.performanceSnapshot()
            ScanPerformanceDiagnostics.final(
                scanID: scanID,
                result: result,
                metrics: combinedMetrics,
                queue: queueSnapshot,
                publisher: publisherSnapshot,
                elapsedNanos: ScanPerformanceDiagnostics.elapsed(since: scanStartedAt),
                finalizationNanos: finalizationNanos,
                resultMaterializationNanos: resultMaterializationNanos
            )
        }
        return result
    }

    private static func runWorker(
        workerID: Int,
        scanID: String,
        collectsPerformanceMetrics: Bool,
        sourceID: ScanSourceID,
        expectedDevice: Int64,
        queue: DirectoryWorkQueue,
        state: ScanAccumulator
    ) async -> ScanWorkerPerformanceMetrics {
        var metrics = ScanWorkerPerformanceMetrics(workerID: workerID)
        while let work = await queue.next() {
            do {
                try Task.checkCancellation()
                let permitStartedAt = collectsPerformanceMetrics ? ScanPerformanceDiagnostics.now() : 0
                let enumeration = try await ScanCoordinator.shared.withDirectoryPermit(for: sourceID) {
                    try Task.checkCancellation()
                    return Self.enumerateDirectory(at: work.url, collectsPerformanceMetrics: collectsPerformanceMetrics)
                }
                let permitAndEnumerationNanos = collectsPerformanceMetrics ? ScanPerformanceDiagnostics.elapsed(since: permitStartedAt) : 0
                let sample = enumeration.performanceSample
                if collectsPerformanceMetrics {
                    metrics.recordEnumeration(sample, depth: work.depth, permitAndEnumerationNanos: permitAndEnumerationNanos)
                }

                let applyStartedAt = collectsPerformanceMetrics ? ScanPerformanceDiagnostics.now() : 0
                let childDirectories = await state.apply(enumeration: enumeration, to: work.nodeID, expectedDevice: expectedDevice, childDepth: work.depth + 1)
                if collectsPerformanceMetrics {
                    metrics.recordAccumulatorApply(
                        nanos: ScanPerformanceDiagnostics.elapsed(since: applyStartedAt),
                        depth: work.depth,
                        childCount: sample.childCount
                    )
                }
                let queueStartedAt = collectsPerformanceMetrics ? ScanPerformanceDiagnostics.now() : 0
                await queue.enqueue(childDirectories)
                if collectsPerformanceMetrics {
                    metrics.queueNanos &+= ScanPerformanceDiagnostics.elapsed(since: queueStartedAt)
                }
                let finishStartedAt = collectsPerformanceMetrics ? ScanPerformanceDiagnostics.now() : 0
                await state.finishEnumeratingDirectory(work.nodeID)
                if collectsPerformanceMetrics {
                    metrics.accumulatorFinishNanos &+= ScanPerformanceDiagnostics.elapsed(since: finishStartedAt)
                }
            } catch is CancellationError {
                await state.markCancelled()
                await queue.cancelPendingWork()
            } catch {
                // Unexpected enumeration failures are isolated to this branch.
                await state.markUnreadableDirectory(work.nodeID)
                await state.finishEnumeratingDirectory(work.nodeID)
            }

            await queue.completeCurrentWork()
            if collectsPerformanceMetrics {
                ScanPerformanceDiagnostics.checkpointIfNeeded(scanID: scanID, metrics: metrics)
            }
        }
        return metrics
    }

    private static func enumerateDirectory(at url: URL, collectsPerformanceMetrics: Bool) -> DirectoryEnumeration {
        let listingStartedAt = collectsPerformanceMetrics ? ScanPerformanceDiagnostics.now() : 0
        let childURLs: [URL]
        do {
            // Includes dot files and traverses package contents by design.
            childURLs = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: nil,
                options: []
            )
        } catch {
            let sample = DirectoryEnumerationPerformanceSample(
                childCount: 0,
                listingNanos: collectsPerformanceMetrics ? ScanPerformanceDiagnostics.elapsed(since: listingStartedAt) : 0,
                metadataNanos: 0,
                isUnreadable: true
            )
            return .unreadable(sample)
        }

        let listingNanos = collectsPerformanceMetrics ? ScanPerformanceDiagnostics.elapsed(since: listingStartedAt) : 0
        let metadataStartedAt = collectsPerformanceMetrics ? ScanPerformanceDiagnostics.now() : 0
        var items = [DiscoveredItem]()
        items.reserveCapacity(childURLs.count)
        for childURL in childURLs {
            guard let status = fileStatus(at: childURL) else {
                items.append(.unreadableItem)
                continue
            }
            items.append(.item(childURL, status))
        }
        let sample = DirectoryEnumerationPerformanceSample(
            childCount: childURLs.count,
            listingNanos: listingNanos,
            metadataNanos: collectsPerformanceMetrics ? ScanPerformanceDiagnostics.elapsed(since: metadataStartedAt) : 0,
            isUnreadable: false
        )
        return .children(items, sample)
    }

    private static func rootNode(for url: URL, incomplete: Bool) -> ScanNodeSummary {
        ScanNodeSummary(
            parentID: nil,
            url: url,
            kind: .directory,
            allocatedSize: 0,
            countsTowardAllocatedSize: true,
            isIncomplete: incomplete
        )
    }

    fileprivate static func fileStatus(at url: URL) -> FileStatus? {
        var info = stat()
        let result = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return -1 }
            return Int(lstat(path, &info))
        }
        guard result == 0 else { return nil }
        return FileStatus(info: info)
    }
}

struct DirectoryWork: Sendable {
    let nodeID: ScanNodeID
    let url: URL
    let depth: Int
}

private enum DirectoryEnumeration: Sendable {
    case children([DiscoveredItem], DirectoryEnumerationPerformanceSample)
    case unreadable(DirectoryEnumerationPerformanceSample)

    var performanceSample: DirectoryEnumerationPerformanceSample {
        switch self {
        case let .children(_, sample), let .unreadable(sample):
            sample
        }
    }
}

private enum DiscoveredItem: Sendable {
    case item(URL, FileStatus)
    case unreadableItem
}

private struct FileIdentity: Hashable, Sendable {
    let device: Int64
    let inode: UInt64
}

private struct WorkingNode: Sendable {
    let id: ScanNodeID
    let parentID: ScanNodeID?
    let url: URL
    let kind: ScanNodeKind
    var allocatedSize: Int64
    let countsTowardAllocatedSize: Bool
    var isIncomplete: Bool
    var hasFinishedEnumeration = false
    var pendingChildDirectories = 0
    var hasCommittedSizeToParent = false

    var summary: ScanNodeSummary {
        ScanNodeSummary(
            id: id,
            parentID: parentID,
            url: url,
            kind: kind,
            allocatedSize: allocatedSize,
            countsTowardAllocatedSize: countsTowardAllocatedSize,
            isIncomplete: isIncomplete
        )
    }
}

private actor ScanAccumulator {
    private var nodes: [ScanNodeID: WorkingNode]
    private var nodeOrder: [ScanNodeID]
    private var countedHardLinks = Set<FileIdentity>()
    private var incompleteReasons = Set<ScanIncompleteReason>()
    private var changedNodeIDs = Set<ScanNodeID>()
    private var completedDirectoryURLs = Set<URL>()
    private var completedDirectories = 0
    private var currentURL: URL

    init(root: WorkingNode) {
        nodes = [root.id: root]
        nodeOrder = [root.id]
        changedNodeIDs = [root.id]
        currentURL = root.url
    }

    func setRootFileSize(from status: FileStatus) {
        guard var root = nodes[nodeOrder[0]] else { return }
        let identity = FileIdentity(device: status.deviceID, inode: status.inode)
        let shouldCount = status.linkCount <= 1 || countedHardLinks.insert(identity).inserted
        root.allocatedSize = shouldCount ? status.allocatedSize : 0
        nodes[root.id] = root
        changedNodeIDs.insert(root.id)
    }

    func apply(enumeration: DirectoryEnumeration, to parentID: ScanNodeID, expectedDevice: Int64, childDepth: Int) -> [DirectoryWork] {
        guard let parent = nodes[parentID] else { return [] }
        currentURL = parent.url
        guard case let .children(items, _) = enumeration else {
            markUnreadableDirectory(parentID)
            return []
        }

        var directoryWork = [DirectoryWork]()
        for item in items {
            switch item {
            case .unreadableItem:
                markUnreadableDirectory(parentID)
            case let .item(url, status):
                guard !status.isSymbolicLink else { continue }
                guard status.deviceID == expectedDevice else { continue }

                let nodeID = ScanNodeID()
                if status.isDirectory {
                    let node = WorkingNode(
                        id: nodeID,
                        parentID: parentID,
                        url: url,
                        kind: .directory,
                        allocatedSize: 0,
                        countsTowardAllocatedSize: true,
                        isIncomplete: false
                    )
                    nodes[nodeID] = node
                    nodeOrder.append(nodeID)
                    changedNodeIDs.insert(nodeID)
                    nodes[parentID]?.pendingChildDirectories += 1
                    changedNodeIDs.insert(parentID)
                    directoryWork.append(DirectoryWork(nodeID: nodeID, url: url, depth: childDepth))
                } else {
                    let identity = FileIdentity(device: status.deviceID, inode: status.inode)
                    let shouldCount = status.linkCount <= 1 || countedHardLinks.insert(identity).inserted
                    let node = WorkingNode(
                        id: nodeID,
                        parentID: parentID,
                        url: url,
                        kind: .file,
                        allocatedSize: shouldCount ? status.allocatedSize : 0,
                        countsTowardAllocatedSize: shouldCount,
                        isIncomplete: false
                    )
                    nodes[nodeID] = node
                    nodeOrder.append(nodeID)
                    changedNodeIDs.insert(nodeID)
                    if shouldCount {
                        addDirectFileSize(status.allocatedSize, to: parentID)
                    }
                }
            }
        }
        return directoryWork
    }

    func finishEnumeratingDirectory(_ nodeID: ScanNodeID) {
        guard var node = nodes[nodeID] else { return }
        node.hasFinishedEnumeration = true
        nodes[nodeID] = node
        changedNodeIDs.insert(nodeID)
        resolveCompletedDirectories(startingAt: nodeID)
    }

    func markUnreadableDirectory(_ nodeID: ScanNodeID) {
        guard var node = nodes[nodeID] else { return }
        node.isIncomplete = true
        nodes[nodeID] = node
        changedNodeIDs.insert(nodeID)
        incompleteReasons.insert(.unreadableItem)
    }

    func markCancelled() {
        guard let rootID = nodeOrder.first, var root = nodes[rootID] else { return }
        root.isIncomplete = true
        nodes[rootID] = root
        changedNodeIDs.insert(rootID)
        incompleteReasons.insert(.cancelled)
    }

    /// Cancellation leaves some directories enumerated only in part. Commit
    /// their partial totals bottom-up once so every visible ancestor still
    /// represents all nodes that were discovered before cancellation.
    func finalizeCancelledDirectories() {
        guard incompleteReasons.contains(.cancelled) else { return }

        for nodeID in nodeOrder.reversed() {
            guard var node = nodes[nodeID],
                  node.kind == .directory,
                  !node.hasCommittedSizeToParent else {
                continue
            }

            node.isIncomplete = true
            node.hasCommittedSizeToParent = true
            nodes[nodeID] = node
            changedNodeIDs.insert(nodeID)

            guard let parentID = node.parentID, var parent = nodes[parentID] else { continue }
            parent.allocatedSize += node.allocatedSize
            parent.isIncomplete = true
            nodes[parentID] = parent
            changedNodeIDs.insert(parentID)
        }
    }

    func takeProgress() -> ScanProgress {
        let updated = changedNodeIDs.compactMap { nodes[$0]?.summary }
        changedNodeIDs.removeAll(keepingCapacity: true)
        let completed = Array(completedDirectoryURLs)
        completedDirectoryURLs.removeAll(keepingCapacity: true)
        return ScanProgress(
            discoveredNodeCount: nodeOrder.count,
            completedDirectoryCount: completedDirectories,
            currentURL: currentURL,
            updatedNodes: updated,
            completedDirectoryURLs: completed
        )
    }

    func result(for source: ScanSource) -> ScanResult {
        let status: ScanResultStatus = incompleteReasons.isEmpty ? .complete : .incomplete(incompleteReasons)
        return ScanResult(source: source, nodes: nodeOrder.compactMap { nodes[$0]?.summary }, status: status)
    }

    private func addDirectFileSize(_ allocated: Int64, to nodeID: ScanNodeID) {
        guard var node = nodes[nodeID] else { return }
        node.allocatedSize += allocated
        nodes[nodeID] = node
        changedNodeIDs.insert(nodeID)
    }

    private func resolveCompletedDirectories(startingAt nodeID: ScanNodeID) {
        var currentID: ScanNodeID? = nodeID
        while let id = currentID,
              var node = nodes[id],
              node.hasFinishedEnumeration,
              node.pendingChildDirectories == 0,
              !node.hasCommittedSizeToParent {
            node.hasCommittedSizeToParent = true
            nodes[id] = node
            completedDirectories += 1
            completedDirectoryURLs.insert(node.url)
            guard let parentID = node.parentID, var parent = nodes[parentID] else { break }
            parent.pendingChildDirectories -= 1
            parent.allocatedSize += node.allocatedSize
            if node.isIncomplete {
                parent.isIncomplete = true
                incompleteReasons.insert(.unreadableItem)
            }
            nodes[parentID] = parent
            changedNodeIDs.insert(parentID)
            currentID = parentID
        }
    }
}

struct RingFIFO<Element> {
    private var storage: [Element?]
    private var head = 0
    private(set) var count = 0

    init(minimumCapacity: Int = 16) {
        storage = Array(repeating: nil, count: max(1, minimumCapacity))
    }

    var isEmpty: Bool { count == 0 }

    mutating func append(_ element: Element) {
        if count == storage.count {
            grow()
        }
        storage[(head + count) % storage.count] = element
        count += 1
    }

    mutating func popFirst() -> Element? {
        guard count > 0 else { return nil }
        let element = storage[head]
        storage[head] = nil
        head = (head + 1) % storage.count
        count -= 1
        if count == 0 {
            head = 0
        }
        return element
    }

    mutating func removeAll(keepingCapacity: Bool) {
        storage = Array(repeating: nil, count: keepingCapacity ? storage.count : 16)
        head = 0
        count = 0
    }

    private mutating func grow() {
        var expanded = Array<Element?>(repeating: nil, count: storage.count * 2)
        for index in 0..<count {
            expanded[index] = storage[(head + index) % storage.count]
        }
        storage = expanded
        head = 0
    }
}

private struct QueuedDirectoryWork {
    let work: DirectoryWork
    let generation: UInt64
}

private struct QueuedDirectoryState {
    let work: DirectoryWork
    var generation: UInt64
}

actor DirectoryWorkQueue {
    private static let maximumFocusedBurst = 8

    private let sourceID: ScanSourceID
    private let coordinator: ScanCoordinator
    private var focused = RingFIFO<QueuedDirectoryWork>()
    private var retiredFocused = RingFIFO<RingFIFO<QueuedDirectoryWork>>()
    private var background = RingFIFO<QueuedDirectoryWork>()
    private var queuedStates = [ScanNodeID: QueuedDirectoryState]()
    private var queuedNodeIDsByURL = [URL: ScanNodeID]()
    private var waitingWorkers = [CheckedContinuation<DirectoryWork?, Never>]()
    private var isServingWaitingWorkers = false
    private var inFlight = 0
    private var isCancelled = false
    private var currentFocusedDirectory: URL?
    private var focusedBurstCount = 0
    private var enqueuedCount = 0
    private var dequeuedCount = 0
    private var peakPendingCount = 0
    private var focusPromotionCount = 0
    private var staleEntryCount = 0

    init(sourceID: ScanSourceID, coordinator: ScanCoordinator) {
        self.sourceID = sourceID
        self.coordinator = coordinator
    }

    func enqueue(_ work: [DirectoryWork]) async {
        guard !isCancelled else { return }
        await refreshFocusedDirectory()
        guard !isCancelled else { return }

        for item in work {
            let state = QueuedDirectoryState(work: item, generation: 0)
            queuedStates[item.nodeID] = state
            queuedNodeIDsByURL[item.url.standardizedFileURL] = item.nodeID
            let queued = QueuedDirectoryWork(work: item, generation: state.generation)
            if isInsideFocusedSubtree(item.url) {
                focused.append(queued)
            } else {
                background.append(queued)
            }
        }
        enqueuedCount += work.count
        peakPendingCount = max(peakPendingCount, queuedStates.count)
        await serveWaitingWorkers()
    }

    func next() async -> DirectoryWork? {
        if let work = await dequeueNext() {
            inFlight += 1
            return work
        }
        guard inFlight > 0, !isCancelled else { return nil }
        return await withCheckedContinuation { waitingWorkers.append($0) }
    }

    func completeCurrentWork() async {
        inFlight = max(0, inFlight - 1)
        await serveWaitingWorkers()
    }

    func cancelPendingWork() {
        isCancelled = true
        focused.removeAll(keepingCapacity: false)
        retiredFocused.removeAll(keepingCapacity: false)
        background.removeAll(keepingCapacity: false)
        queuedStates.removeAll(keepingCapacity: false)
        queuedNodeIDsByURL.removeAll(keepingCapacity: false)
        if inFlight == 0 {
            resumeIdleWorkers()
        }
    }

    func performanceSnapshot() -> DirectoryQueuePerformanceSnapshot {
        DirectoryQueuePerformanceSnapshot(
            enqueuedCount: enqueuedCount,
            dequeuedCount: dequeuedCount,
            peakPendingCount: peakPendingCount,
            focusPromotionCount: focusPromotionCount,
            staleEntryCount: staleEntryCount
        )
    }

    private func serveWaitingWorkers() async {
        // `dequeueNext` consults the coordinator and therefore yields this actor.
        // Keep a single dispatcher active so reentrant enqueue/complete calls
        // cannot consume the same waiter based on a stale non-empty check.
        guard !isServingWaitingWorkers else { return }
        isServingWaitingWorkers = true
        defer { isServingWaitingWorkers = false }

        while !waitingWorkers.isEmpty, let work = await dequeueNext() {
            inFlight += 1
            waitingWorkers.removeFirst().resume(returning: work)
        }
        if !hasQueuedWork, inFlight == 0 {
            resumeIdleWorkers()
        }
    }

    private var hasQueuedWork: Bool {
        !queuedStates.isEmpty
    }

    private func dequeueNext() async -> DirectoryWork? {
        guard !isCancelled else { return nil }
        await refreshFocusedDirectory()
        guard !isCancelled else { return nil }

        if focusedBurstCount < Self.maximumFocusedBurst,
           let work = popValidFocused() {
            focusedBurstCount += 1
            return work
        }
        if let work = popValidBackground() {
            focusedBurstCount = 0
            return work
        }
        if let work = popValidFocused() {
            focusedBurstCount = min(Self.maximumFocusedBurst, focusedBurstCount + 1)
            return work
        }
        return nil
    }

    private func refreshFocusedDirectory() async {
        let prioritizedDirectory = await coordinator.prioritizedDirectory(for: sourceID)?.standardizedFileURL
        guard !isCancelled, prioritizedDirectory != currentFocusedDirectory else { return }

        if !focused.isEmpty {
            retiredFocused.append(focused)
            focused = RingFIFO()
        }
        currentFocusedDirectory = prioritizedDirectory
        focusedBurstCount = 0

        guard let prioritizedDirectory,
              let nodeID = queuedNodeIDsByURL[prioritizedDirectory],
              var state = queuedStates[nodeID] else {
            return
        }
        state.generation &+= 1
        queuedStates[nodeID] = state
        focused.append(QueuedDirectoryWork(work: state.work, generation: state.generation))
        focusPromotionCount += 1
        staleEntryCount += 1
    }

    private func isInsideFocusedSubtree(_ candidate: URL) -> Bool {
        guard let currentFocusedDirectory else { return false }
        let candidatePath = candidate.standardizedFileURL.path
        let focusedPath = currentFocusedDirectory.path
        return candidatePath == focusedPath || candidatePath.hasPrefix(focusedPath + "/")
    }

    private func popValidFocused() -> DirectoryWork? {
        while let queued = focused.popFirst() {
            if let work = accept(queued) {
                return work
            }
        }
        return nil
    }

    private func popValidBackground() -> DirectoryWork? {
        while var queue = retiredFocused.popFirst() {
            while let queued = queue.popFirst() {
                if !queue.isEmpty {
                    retiredFocused.append(queue)
                }
                if let work = accept(queued) {
                    return work
                }
                break
            }
        }

        while let queued = background.popFirst() {
            if let work = accept(queued) {
                return work
            }
        }
        return nil
    }

    private func accept(_ queued: QueuedDirectoryWork) -> DirectoryWork? {
        guard let state = queuedStates[queued.work.nodeID],
              state.generation == queued.generation else {
            return nil
        }
        queuedStates.removeValue(forKey: queued.work.nodeID)
        queuedNodeIDsByURL.removeValue(forKey: queued.work.url.standardizedFileURL)
        dequeuedCount += 1
        return queued.work
    }

    private func resumeIdleWorkers() {
        let workers = waitingWorkers
        waitingWorkers.removeAll(keepingCapacity: false)
        workers.forEach { $0.resume(returning: nil) }
    }
}

actor ProgressPublisher {
    private let publicationInterval: Duration
    private let snapshot: @Sendable () async -> ScanProgress
    private let sink: (@Sendable (ScanProgress) async -> Void)?
    private let collectsPerformanceMetrics: Bool
    private var submissionCount = 0
    private var deliveryCount = 0
    private var snapshotNanos: UInt64 = 0
    private var sinkNanos: UInt64 = 0
    private var snapshotNodeCount = 0
    private var maximumSnapshotNodeCount = 0

    init(
        publicationInterval: Duration = .seconds(2),
        snapshot: @escaping @Sendable () async -> ScanProgress,
        sink: (@Sendable (ScanProgress) async -> Void)?
    ) {
        self.publicationInterval = publicationInterval
        self.snapshot = snapshot
        self.sink = sink
        self.collectsPerformanceMetrics = ScanPerformanceDiagnostics.isEnabled
    }

    func publishPeriodically() async {
        guard sink != nil else { return }
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: publicationInterval)
            } catch {
                return
            }
            await publish()
        }
    }

    func publish() async {
        guard let sink else { return }
        let snapshotStartedAt = collectsPerformanceMetrics ? ScanPerformanceDiagnostics.now() : 0
        let progress = await snapshot()
        if collectsPerformanceMetrics {
            submissionCount += 1
            snapshotNanos &+= ScanPerformanceDiagnostics.elapsed(since: snapshotStartedAt)
            snapshotNodeCount += progress.updatedNodes.count
            maximumSnapshotNodeCount = max(maximumSnapshotNodeCount, progress.updatedNodes.count)
        }
        let sinkStartedAt = collectsPerformanceMetrics ? ScanPerformanceDiagnostics.now() : 0
        await sink(progress)
        if collectsPerformanceMetrics {
            deliveryCount += 1
            sinkNanos &+= ScanPerformanceDiagnostics.elapsed(since: sinkStartedAt)
        }
    }

    func performanceSnapshot() -> ProgressPublisherPerformanceSnapshot {
        ProgressPublisherPerformanceSnapshot(
            submissionCount: submissionCount,
            deliveryCount: deliveryCount,
            snapshotNanos: snapshotNanos,
            sinkNanos: sinkNanos,
            snapshotNodeCount: snapshotNodeCount,
            maximumSnapshotNodeCount: maximumSnapshotNodeCount
        )
    }
}

private struct FileStatus: Sendable {
    let deviceID: Int64
    let inode: UInt64
    let linkCount: UInt32
    let allocatedSize: Int64
    let isDirectory: Bool
    let isSymbolicLink: Bool

    init(info: stat) {
        deviceID = Int64(info.st_dev)
        inode = UInt64(info.st_ino)
        linkCount = UInt32(info.st_nlink)
        allocatedSize = max(0, Int64(info.st_blocks) * 512)
        isDirectory = (info.st_mode & S_IFMT) == S_IFDIR
        isSymbolicLink = (info.st_mode & S_IFMT) == S_IFLNK
    }
}
