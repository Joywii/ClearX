import Foundation

/// UI-facing, lazy snapshot query surface. In-memory and persistent adapters keep storage details out of views.
protocol SnapshotColumnLoading: Sendable {
    func loadColumn(for source: ScanSource, parent: ScanNodeSummary?) async throws -> SnapshotBrowserColumn
}

struct SnapshotBrowserColumn: Sendable, Equatable {
    let parent: ScanNodeSummary?
    let nodes: [ScanNodeSummary]
    let state: SnapshotBrowserColumnState
    let estimatingNodeIDs: Set<ScanNodeID>

    init(parent: ScanNodeSummary?, nodes: [ScanNodeSummary], state: SnapshotBrowserColumnState = .complete, estimatingNodeIDs: Set<ScanNodeID> = [], sortsNodes: Bool = true) {
        self.parent = parent
        self.nodes = sortsNodes ? nodes.sorted(by: ScanNodeSummary.browserOrder) : nodes
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

/// Callers publish the complete set known for one visible directory. While the
/// update is partial, existing rows retain their position to avoid jitter.
struct SnapshotBrowserColumnUpdate: Sendable, Equatable {
    let parent: ScanNodeSummary?
    let nodes: [ScanNodeSummary]
    let state: SnapshotBrowserColumnState
    let estimatingNodeIDs: Set<ScanNodeID>

    init(parent: ScanNodeSummary?, nodes: [ScanNodeSummary], state: SnapshotBrowserColumnState, estimatingNodeIDs: Set<ScanNodeID> = []) {
        self.parent = parent
        self.nodes = nodes
        self.state = state
        self.estimatingNodeIDs = estimatingNodeIDs
    }
}
