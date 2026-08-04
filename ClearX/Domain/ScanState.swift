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
    /// Changed nodes are an incremental, self-contained view of the live tree.
    /// Consumers retain the previous nodes and replace entries with matching IDs.
    let updatedNodes: [ScanNodeSummary]
    /// A directory appears here once all of its currently reachable descendants
    /// have been enumerated. Its size is exact unless it is marked incomplete.
    let completedDirectoryURLs: [URL]

    init(discoveredNodeCount: Int, completedDirectoryCount: Int, currentURL: URL?, updatedNodes: [ScanNodeSummary] = [], completedDirectoryURLs: [URL] = []) {
        self.discoveredNodeCount = discoveredNodeCount
        self.completedDirectoryCount = completedDirectoryCount
        self.currentURL = currentURL?.standardizedFileURL
        self.updatedNodes = updatedNodes
        self.completedDirectoryURLs = completedDirectoryURLs.map(\.standardizedFileURL)
    }
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
    let nodes: [ScanNodeSummary]
    let status: ScanResultStatus
    let scannedAt: Date

    init(source: ScanSource, nodes: [ScanNodeSummary], status: ScanResultStatus, scannedAt: Date = Date()) {
        self.source = source
        self.nodes = nodes
        self.status = status
        self.scannedAt = scannedAt
    }

    var rootNode: ScanNodeSummary? {
        nodes.first { $0.parentID == nil }
    }

    func children(of parentID: ScanNodeID) -> [ScanNodeSummary] {
        nodes.filter { $0.parentID == parentID }.sorted(by: ScanNodeSummary.browserOrder)
    }
}
