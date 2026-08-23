import Foundation

/// UI-facing, lazy snapshot query surface. In-memory and persistent adapters keep storage details out of views.
protocol SnapshotColumnLoading: Sendable {
    func loadColumn(
        for source: ScanSource,
        parent: ScanNodeSummary?,
        offset: Int,
        limit: Int
    ) async throws -> SnapshotBrowserColumn
}

struct SnapshotBrowserColumn: Sendable, Equatable {
    let parent: ScanNodeSummary?
    let nodes: [ScanNodeSummary]
    let totalNodeCount: Int
    let state: SnapshotBrowserColumnState
    let estimatingNodeIDs: Set<ScanNodeID>

    init(
        parent: ScanNodeSummary?,
        nodes: [ScanNodeSummary],
        totalNodeCount: Int? = nil,
        state: SnapshotBrowserColumnState = .complete,
        estimatingNodeIDs: Set<ScanNodeID> = []
    ) {
        self.parent = parent
        self.nodes = state == .complete ? nodes.sorted(by: ScanNodeSummary.browserOrder) : nodes
        self.totalNodeCount = totalNodeCount ?? nodes.count
        self.state = state
        self.estimatingNodeIDs = estimatingNodeIDs
    }
}

/// A column can receive partial scan results without coupling the browser to a
/// particular scanner or persistence implementation.
enum SnapshotBrowserColumnState: Sendable, Equatable {
    case loading
    case partial
    case complete
}
