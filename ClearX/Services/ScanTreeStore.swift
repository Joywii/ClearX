import Foundation

/// Canonical in-memory tree shared by the scanner, visible columns, and the
/// completed-result cache. Node values have exactly one owner for a scan.
actor ScanTreeStore {
    private struct DirectoryState {
        var hasFinishedEnumeration = false
        var pendingChildDirectories = 0
        var hasCommittedSizeToParent = false
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
    private var incompleteReasons = Set<ScanIncompleteReason>()
    private var completedDirectoryIDs = Set<ScanNodeID>()
    private var changedParentIDs = Set<ScanNodeID>()
    private var completedSinceProgress = Set<ScanNodeID>()
    private var rootNodeID: ScanNodeID?
    private var completedDirectories = 0
    private var currentURL: URL?
    private var isSealed = false

    init() {}

    init(snapshotNodes: [ScanNodeSummary], status: ScanResultStatus) {
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
        guard let rootNodeID else { return }
        let identity = FileIdentity(device: status.deviceID, inode: status.inode)
        let shouldCount = status.linkCount <= 1 || countedHardLinks.insert(identity).inserted
        updateNode(rootNodeID, allocatedSize: shouldCount ? status.allocatedSize : 0, countsTowardAllocatedSize: shouldCount)
    }

    func apply(items: [DiscoveredItem], to parentID: ScanNodeID, expectedDevice: Int64, childDepth: Int) -> [DirectoryWork] {
        guard !isSealed, let parent = node(withID: parentID) else { return [] }
        currentURL = parent.url

        var directoryWork: [DirectoryWork] = []
        for item in items {
            switch item {
            case .unreadableItem:
                markUnreadableDirectory(parentID)
            case let .item(url, status):
                guard !status.isSymbolicLink, status.deviceID == expectedDevice else { continue }

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
                    if var parentState = directoryStates[parentID] {
                        parentState.pendingChildDirectories += 1
                        directoryStates[parentID] = parentState
                    }
                    directoryWork.append(DirectoryWork(nodeID: nodeID, url: url, depth: childDepth))
                } else {
                    let identity = FileIdentity(device: status.deviceID, inode: status.inode)
                    let shouldCount = status.linkCount <= 1 || countedHardLinks.insert(identity).inserted
                    let node = ScanNodeSummary(
                        id: nodeID,
                        parentID: parentID,
                        url: url,
                        kind: .file,
                        allocatedSize: shouldCount ? status.allocatedSize : 0,
                        countsTowardAllocatedSize: shouldCount
                    )
                    append(node)
                    if shouldCount {
                        addAllocatedSize(status.allocatedSize, to: parentID)
                    }
                }
            }
        }
        return directoryWork
    }

    func finishEnumeratingDirectory(_ nodeID: ScanNodeID) {
        guard var state = directoryStates[nodeID] else { return }
        state.hasFinishedEnumeration = true
        directoryStates[nodeID] = state
        resolveCompletedDirectories(startingAt: nodeID)
    }

    func markUnreadableDirectory(_ nodeID: ScanNodeID) {
        updateNode(nodeID, isIncomplete: true)
        incompleteReasons.insert(.unreadableItem)
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
            guard var state = directoryStates[storedNode.id], !state.hasCommittedSizeToParent else { continue }
            state.hasCommittedSizeToParent = true
            directoryStates[storedNode.id] = state
            updateNode(storedNode.id, isIncomplete: true)

            guard let parentID = storedNode.parentID, let current = node(withID: storedNode.id) else { continue }
            addAllocatedSize(current.allocatedSize, to: parentID, marksIncomplete: true)
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

    func node(withID id: ScanNodeID) -> ScanNodeSummary? {
        guard let index = nodeIndexByID[id], nodes.indices.contains(index) else { return nil }
        return nodes[index]
    }

    func page(parentID: ScanNodeID, offset: Int, limit: Int) -> ScanNodePage {
        let parentIsComplete = completedDirectoryIDs.contains(parentID) || node(withID: parentID)?.kind != .directory
        if parentIsComplete, !sortedParentIDs.contains(parentID) {
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
            $0.kind == .directory && !self.completedDirectoryIDs.contains($0.id)
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
            estimatingNodeIDs: estimatingNodeIDs
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
            changedParentIDs.insert(parentID)
        }
    }

    private func updateNode(
        _ nodeID: ScanNodeID,
        allocatedSize: Int64? = nil,
        countsTowardAllocatedSize: Bool? = nil,
        isIncomplete: Bool? = nil
    ) {
        guard let index = nodeIndexByID[nodeID], nodes.indices.contains(index) else { return }
        if let allocatedSize {
            nodes[index].allocatedSize = max(0, allocatedSize)
        }
        if let countsTowardAllocatedSize {
            nodes[index].countsTowardAllocatedSize = countsTowardAllocatedSize
        }
        if let isIncomplete {
            nodes[index].isIncomplete = isIncomplete
        }
        if let parentID = nodes[index].parentID {
            changedParentIDs.insert(parentID)
        }
    }

    private func addAllocatedSize(_ allocatedSize: Int64, to nodeID: ScanNodeID, marksIncomplete: Bool = false) {
        guard let node = node(withID: nodeID) else { return }
        updateNode(
            nodeID,
            allocatedSize: node.allocatedSize + allocatedSize,
            isIncomplete: marksIncomplete ? true : node.isIncomplete
        )
    }

    private func resolveCompletedDirectories(startingAt nodeID: ScanNodeID) {
        var currentID: ScanNodeID? = nodeID
        while let id = currentID,
              var state = directoryStates[id],
              state.hasFinishedEnumeration,
              state.pendingChildDirectories == 0,
              !state.hasCommittedSizeToParent {
            state.hasCommittedSizeToParent = true
            directoryStates[id] = state
            completedDirectories += 1
            completedDirectoryIDs.insert(id)
            completedSinceProgress.insert(id)

            guard let node = node(withID: id),
                  let parentID = node.parentID,
                  var parentState = directoryStates[parentID] else {
                break
            }
            parentState.pendingChildDirectories -= 1
            directoryStates[parentID] = parentState
            addAllocatedSize(node.allocatedSize, to: parentID, marksIncomplete: node.isIncomplete)
            if node.isIncomplete {
                incompleteReasons.insert(.unreadableItem)
            }
            currentID = parentID
        }
    }
}
