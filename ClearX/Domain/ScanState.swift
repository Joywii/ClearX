import Foundation

enum ScanIncompleteReason: String, Codable, Sendable, Hashable {
    case cancelled
    case unreadableItem
    case permissionRestricted
    case sourceUnavailable
    case eventHistoryUnavailable
}

enum ScanResultStatus: Codable, Sendable, Hashable {
    case complete
    case incomplete(Set<ScanIncompleteReason>)
}

struct ScanProgress: Sendable, Hashable {
    let discoveredNodeCount: Int
    let completedDirectoryCount: Int
    let currentURL: URL?
    /// Storage already owns node values. Progress only invalidates visible columns.
    let changedParentIDs: Set<ScanNodeID>
    let completedDirectoryIDs: Set<ScanNodeID>

    init(
        discoveredNodeCount: Int,
        completedDirectoryCount: Int,
        currentURL: URL?,
        changedParentIDs: Set<ScanNodeID> = [],
        completedDirectoryIDs: Set<ScanNodeID> = []
    ) {
        self.discoveredNodeCount = discoveredNodeCount
        self.completedDirectoryCount = completedDirectoryCount
        self.currentURL = currentURL?.standardizedFileURL
        self.changedParentIDs = changedParentIDs
        self.completedDirectoryIDs = completedDirectoryIDs
    }
}

enum ScanNodePageState: Sendable, Equatable {
    case loading
    case partial
    case complete
}

struct ScanNodePage: Sendable, Equatable {
    let nodes: [ScanNodeSummary]
    let totalCount: Int
    let state: ScanNodePageState
    let estimatingNodeIDs: Set<ScanNodeID>
}

enum ScanPresentationState: Sendable, Hashable {
    case idle
    case scanning(ScanProgress)
    case completed(ScanResultStatus)
    case cancelled
    case incomplete(ScanIncompleteReason)
    case permissionRestricted(URL)
    case unavailable(URL)
    case synchronizationFailed(String)
}

struct ScanResult: Sendable {
    let source: ScanSource
    let snapshot: ScanTreeStore
    let status: ScanResultStatus
    let scannedAt: Date
    let nodeCount: Int

    init(source: ScanSource, snapshot: ScanTreeStore, status: ScanResultStatus, nodeCount: Int, scannedAt: Date = Date()) {
        self.source = source
        self.snapshot = snapshot
        self.status = status
        self.scannedAt = scannedAt
        self.nodeCount = nodeCount
    }

    init(source: ScanSource, nodes: [ScanNodeSummary], status: ScanResultStatus, scannedAt: Date = Date()) {
        self.init(
            source: source,
            snapshot: ScanTreeStore(snapshotNodes: nodes, status: status),
            status: status,
            nodeCount: nodes.count,
            scannedAt: scannedAt
        )
    }

    func allNodes() async -> [ScanNodeSummary] {
        await snapshot.allNodes()
    }
}
