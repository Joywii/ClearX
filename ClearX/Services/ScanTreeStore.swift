import Foundation

/// Canonical in-memory tree shared by the scanner, visible columns, and the
/// completed-result cache. Node values have exactly one owner for a scan.
actor ScanTreeStore {
    private struct DirectoryState {
        var hasStartedEnumeration = false
        var hasFinishedEnumeration = false
        var pendingChildDirectories = 0
        var isComplete = false
    }

    private struct FileIdentity: Hashable {
        let device: Int64
        let inode: UInt64
    }

    private var nodes: [ScanNodeSummary] = []
    private var nodeIndexByID: [ScanNodeID: Int] = [:]
    private var childIDsByParent: [ScanNodeID: [ScanNodeID]] = [:]
    private var sortedParentIDs = Set<ScanNodeID>()
    private var directoryStates: [ScanNodeID: DirectoryState] = [:]
    private var countedHardLinks = Set<FileIdentity>()
    private var uniqueAllocatedSize: Int64 = 0
    private var incompleteReasons = Set<ScanIncompleteReason>()
    private var completedDirectoryIDs = Set<ScanNodeID>()
    private var changedParentIDs = Set<ScanNodeID>()
    private var completedSinceProgress = Set<ScanNodeID>()
    private var rootNodeID: ScanNodeID?
    private var completedDirectories = 0
    private var currentURL: URL?
    private var isSealed = false

    init() {}

    init(snapshotNodes: [ScanNodeSummary], status: ScanResultStatus, uniqueAllocatedSize: Int64? = nil) {
        // Diagnostic fixtures have no filesystem identity from which to deduplicate.
        precondition(uniqueAllocatedSize != nil || !snapshotNodes.contains(where: \.isHardLink))
        nodes = snapshotNodes
        nodeIndexByID.reserveCapacity(snapshotNodes.count)
        childIDsByParent.reserveCapacity(snapshotNodes.count / 4)
        for (index, node) in snapshotNodes.enumerated() {
            nodeIndexByID[node.id] = index
            if let parentID = node.parentID {
                childIDsByParent[parentID, default: []].append(node.id)
            } else {
                rootNodeID = node.id
            }
        }
        self.uniqueAllocatedSize = uniqueAllocatedSize ?? snapshotNodes.first { $0.parentID == nil }?.allocatedSize ?? 0
        if case let .incomplete(reasons) = status { incompleteReasons = reasons }
        if case .complete = status {
            completedDirectoryIDs = Set(snapshotNodes.lazy.filter { $0.kind == .directory }.map(\.id))
            completedDirectories = completedDirectoryIDs.count
        }
        isSealed = true
    }

    func begin(rootURL: URL, kind: ScanNodeKind) -> ScanNodeID {
        precondition(nodes.isEmpty, "A scan tree cannot be reused for another scan")
        let root = ScanNodeSummary(
            parentID: nil,
            url: rootURL,
            kind: kind,
            allocatedSize: 0
        )
        append(root)
        rootNodeID = root.id
        currentURL = root.url
        if kind == .directory {
            directoryStates[root.id] = DirectoryState()
        }
        return root.id
    }

    func setRootFileSize(from status: FileStatus) {
        guard !isSealed, let rootNodeID else { return }
        uniqueAllocatedSize = status.allocatedSize
        updateNode(rootNodeID, allocatedSize: status.allocatedSize, isHardLink: status.linkCount > 1)
    }

    func apply(items: [DiscoveredItem], to parentID: ScanNodeID, expectedDevice: Int64, childDepth: Int,
               mountPoints: ScanMountPoints = ScanMountPoints(urls: [])) -> [DirectoryWork] {
        guard !isSealed, let parent = node(withID: parentID) else { return [] }
        currentURL = parent.url

        var directoryWork: [DirectoryWork] = []
        var allocatedSizeDelta: Int64 = 0
        var hasUnreadableItems = false
        directoryStates[parentID]?.hasStartedEnumeration = true
        for item in items {
            switch item {
            case .unreadableItem:
                hasUnreadableItems = true
            case let .item(url, status):
                if status.isSymbolicLink || status.deviceID != expectedDevice
                    || (status.isDirectory && mountPoints.contains(url)) {
                    // Traversal boundaries remain visible, but never enter the work
                    // queue or contribute the target filesystem's allocated size.
                    // APFS Data can share st_dev with /; also match mount paths.
                    // Only children reach apply, so the selected root is exempt.
                    append(ScanNodeSummary(
                        parentID: parentID,
                        url: url,
                        kind: status.isSymbolicLink ? .symbolicLink : .mountPoint,
                        allocatedSize: 0
                    ))
                    continue
                }

                let nodeID = ScanNodeID()
                if status.isDirectory {
                    let node = ScanNodeSummary(
                        id: nodeID,
                        parentID: parentID,
                        url: url,
                        kind: .directory,
                        allocatedSize: 0
                    )
                    append(node)
                    directoryStates[nodeID] = DirectoryState()
                    directoryWork.append(DirectoryWork(nodeID: nodeID, url: url, depth: childDepth))
                } else {
                    let identity = FileIdentity(device: status.deviceID, inode: status.inode)
                    let shouldCount = status.linkCount <= 1 || countedHardLinks.insert(identity).inserted
                    let node = ScanNodeSummary(
                        id: nodeID,
                        parentID: parentID,
                        url: url,
                        kind: .file,
                        allocatedSize: status.allocatedSize,
                        isHardLink: status.linkCount > 1
                    )
                    append(node)
                    // Deduplication belongs to the scan, never to a directory:
                    // worker/focus order must not change per-path content sizes.
                    allocatedSizeDelta += node.allocatedSize
                    if shouldCount { uniqueAllocatedSize += node.allocatedSize }
                }
            }
        }
        // apply does not suspend: no reader can observe the intermediate totals.
        // Propagate one delta per batch, not one ancestor walk per file.
        if allocatedSizeDelta > 0 || hasUnreadableItems {
            propagate(allocatedSizeDelta: allocatedSizeDelta, from: parentID, marksIncomplete: hasUnreadableItems)
        }
        if hasUnreadableItems { incompleteReasons.insert(.unreadableItem) }
        if !directoryWork.isEmpty, var parentState = directoryStates[parentID] {
            parentState.pendingChildDirectories += directoryWork.count
            directoryStates[parentID] = parentState
        }
        return directoryWork
    }

    func finishEnumeratingDirectory(_ nodeID: ScanNodeID) {
        guard var state = directoryStates[nodeID] else { return }
        state.hasStartedEnumeration = true
        state.hasFinishedEnumeration = true
        directoryStates[nodeID] = state
        resolveCompletedDirectories(startingAt: nodeID)
    }

    func markUnreadableDirectory(_ nodeID: ScanNodeID) {
        directoryStates[nodeID]?.hasStartedEnumeration = true
        propagate(allocatedSizeDelta: 0, from: nodeID, marksIncomplete: true)
        incompleteReasons.insert(.unreadableItem)
    }

    func startEnumeratingDirectory(_ nodeID: ScanNodeID) {
        directoryStates[nodeID]?.hasStartedEnumeration = true
        if let parentID = node(withID: nodeID)?.parentID {
            changedParentIDs.insert(parentID)
        }
    }

    func markCancelled() {
        guard let rootNodeID else { return }
        updateNode(rootNodeID, isIncomplete: true)
        incompleteReasons.insert(.cancelled)
    }

    func markIncomplete(_ reason: ScanIncompleteReason) {
        guard let rootNodeID else { return }
        updateNode(rootNodeID, isIncomplete: true)
        incompleteReasons.insert(reason)
    }

    func finalizeCancelledDirectories() {
        guard incompleteReasons.contains(.cancelled) else { return }

        for index in nodes.indices.reversed() {
            let storedNode = nodes[index]
            guard storedNode.kind == .directory else { continue }
            guard !completedDirectoryIDs.contains(storedNode.id) else { continue }
            updateNode(storedNode.id, isIncomplete: true)
        }
    }

    func takeProgress() -> ScanProgress {
        let progress = ScanProgress(
            discoveredNodeCount: nodes.count,
            completedDirectoryCount: completedDirectories,
            currentURL: currentURL,
            changedParentIDs: changedParentIDs,
            completedDirectoryIDs: completedSinceProgress
        )
        changedParentIDs.removeAll(keepingCapacity: true)
        completedSinceProgress.removeAll(keepingCapacity: true)
        return progress
    }

    func finishScan() -> (status: ScanResultStatus, nodeCount: Int) {
        let status: ScanResultStatus = incompleteReasons.isEmpty ? .complete : .incomplete(incompleteReasons)
        isSealed = true
        directoryStates.removeAll(keepingCapacity: false)
        countedHardLinks.removeAll(keepingCapacity: false)
        changedParentIDs.removeAll(keepingCapacity: false)
        completedSinceProgress.removeAll(keepingCapacity: false)
        return (status, nodes.count)
    }

    func rootNode() -> ScanNodeSummary? {
        rootNodeID.flatMap(node(withID:))
    }

    func sizeSummary() -> ScanSizeSummary {
        ScanSizeSummary(
            contentAllocatedSize: rootNode()?.allocatedSize ?? 0,
            uniqueAllocatedSize: uniqueAllocatedSize,
            isScanning: !isSealed,
            isIncomplete: !incompleteReasons.isEmpty || rootNode()?.isIncomplete == true
        )
    }

    func node(withID id: ScanNodeID) -> ScanNodeSummary? {
        guard let index = nodeIndexByID[id], nodes.indices.contains(index) else { return nil }
        return nodes[index]
    }

    func page(parentID: ScanNodeID, offset: Int, limit: Int) -> ScanNodePage {
        let parentIsComplete = completedDirectoryIDs.contains(parentID) || node(withID: parentID)?.kind != .directory
        if !sortedParentIDs.contains(parentID) {
            let indexes = nodeIndexByID
            let currentNodes = nodes
            childIDsByParent[parentID]?.sort { lhs, rhs in
                guard let leftIndex = indexes[lhs], let rightIndex = indexes[rhs] else { return false }
                let left = currentNodes[leftIndex]
                let right = currentNodes[rightIndex]
                return ScanNodeSummary.browserOrder(left, right)
            }
            sortedParentIDs.insert(parentID)
        }
        let childIDs = childIDsByParent[parentID] ?? []

        let lowerBound = min(max(0, offset), childIDs.count)
        let upperBound = min(childIDs.count, lowerBound + max(1, limit))
        let pageNodes = childIDs[lowerBound..<upperBound].compactMap(node(withID:))
        let estimatingNodeIDs = Set(pageNodes.lazy.filter {
            !self.isSealed && $0.kind == .directory && !self.completedDirectoryIDs.contains($0.id)
        }.map(\.id))
        let pendingNodeIDs = Set(pageNodes.lazy.filter {
            !self.isSealed && self.directoryStates[$0.id]?.hasStartedEnumeration == false
        }.map(\.id))
        let state: ScanNodePageState
        if parentIsComplete {
            state = .complete
        } else if childIDs.isEmpty && !isSealed {
            state = .loading
        } else {
            state = .partial
        }
        return ScanNodePage(
            nodes: pageNodes,
            totalCount: childIDs.count,
            state: state,
            estimatingNodeIDs: estimatingNodeIDs,
            pendingNodeIDs: pendingNodeIDs,
            sizeSummary: parentID == rootNodeID ? sizeSummary() : nil
        )
    }

    /// Explicit full-tree materialization is reserved for tests and diagnostics.
    func allNodes() -> [ScanNodeSummary] {
        nodes
    }

    private func append(_ node: ScanNodeSummary) {
        nodeIndexByID[node.id] = nodes.count
        nodes.append(node)
        if let parentID = node.parentID {
            childIDsByParent[parentID, default: []].append(node.id)
            sortedParentIDs.remove(parentID)
            changedParentIDs.insert(parentID)
        }
    }

    private func updateNode(
        _ nodeID: ScanNodeID,
        allocatedSize: Int64? = nil,
        isHardLink: Bool? = nil,
        isIncomplete: Bool? = nil
    ) {
        guard let index = nodeIndexByID[nodeID], nodes.indices.contains(index) else { return }
        if let allocatedSize {
            nodes[index].allocatedSize = max(0, allocatedSize)
        }
        if let isHardLink {
            nodes[index].isHardLink = isHardLink
        }
        if let isIncomplete {
            nodes[index].isIncomplete = isIncomplete
        }
        if let parentID = nodes[index].parentID {
            if allocatedSize != nil { sortedParentIDs.remove(parentID) }
            changedParentIDs.insert(parentID)
        }
    }

    private func propagate(allocatedSizeDelta: Int64, from nodeID: ScanNodeID, marksIncomplete: Bool = false) {
        var currentID: ScanNodeID? = nodeID
        while let id = currentID, let node = node(withID: id) {
            updateNode(id, allocatedSize: allocatedSizeDelta == 0 ? nil : node.allocatedSize + allocatedSizeDelta,
                       isIncomplete: marksIncomplete ? true : nil)
            currentID = node.parentID
        }
    }

    private func resolveCompletedDirectories(startingAt nodeID: ScanNodeID) {
        var currentID: ScanNodeID? = nodeID
        while let id = currentID,
              var state = directoryStates[id],
              state.hasFinishedEnumeration,
              state.pendingChildDirectories == 0,
              !state.isComplete {
            state.isComplete = true
            directoryStates[id] = state
            completedDirectories += 1
            completedDirectoryIDs.insert(id)
            completedSinceProgress.insert(id)
            if let parentID = node(withID: id)?.parentID { changedParentIDs.insert(parentID) }

            guard let node = node(withID: id),
                  let parentID = node.parentID,
                  var parentState = directoryStates[parentID] else {
                break
            }
            parentState.pendingChildDirectories -= 1
            directoryStates[parentID] = parentState
            // Sizes and unreadable flags already propagated when the batch arrived.
            currentID = parentID
        }
    }
}
