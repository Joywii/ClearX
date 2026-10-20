import Foundation

/// Keeps complete scan results for the lifetime of the current ClearX process.
/// It deliberately does not persist paths or metadata to disk.
actor InMemoryScanCache {
    static let shared = InMemoryScanCache()

    private var results: [URL: ScanResult] = [:]
    private var sourceUseCounts: [URL: Int] = [:]

    func retain(source: ScanSource) {
        let key = source.rootURL.standardizedFileURL
        sourceUseCounts[key, default: 0] += 1
    }

    func release(source: ScanSource) {
        let key = source.rootURL.standardizedFileURL
        let remaining = max(0, sourceUseCounts[key, default: 0] - 1)
        if remaining == 0 {
            sourceUseCounts.removeValue(forKey: key)
            results.removeValue(forKey: key)
        } else {
            sourceUseCounts[key] = remaining
        }
    }

    func result(for source: ScanSource) -> ScanResult? {
        results[source.rootURL.standardizedFileURL]
    }

    @discardableResult
    func store(_ result: ScanResult) -> Bool {
        guard case .complete = result.status else { return false }
        results[result.source.rootURL.standardizedFileURL] = result
        return true
    }

    func removeResult(for source: ScanSource) {
        results.removeValue(forKey: source.rootURL.standardizedFileURL)
    }

    func invalidate(overlapping urls: [URL]) {
        let entries = urls.map(FileLocation.entry)
        for root in Array(results.keys) {
            let canonical = FileLocation.resolved(root)
            if entries.contains(where: { FileLocation.overlaps(canonical, $0) }) {
                results.removeValue(forKey: root)
            }
        }
    }
}

actor DisplayedScanSnapshot {
    private var snapshot: ScanTreeStore?

    func set(_ snapshot: ScanTreeStore) {
        self.snapshot = snapshot
    }

    func clear() {
        snapshot = nil
    }

    func current() -> ScanTreeStore? {
        snapshot
    }
}

/// Adapts a session-cached scan tree to the result browser's lazy-column API.
struct InMemorySnapshotColumnLoader: SnapshotColumnLoading {
    let displayedSnapshot: DisplayedScanSnapshot

    init(displayedSnapshot: DisplayedScanSnapshot) {
        self.displayedSnapshot = displayedSnapshot
    }

    func loadColumn(
        for source: ScanSource,
        parent: ScanNodeSummary?,
        offset: Int,
        limit: Int
    ) async throws -> SnapshotBrowserColumn {
        guard let snapshot = await displayedSnapshot.current() else {
            return SnapshotBrowserColumn(parent: parent, nodes: [], totalNodeCount: 0, state: .loading)
        }
        let root = parent == nil ? await snapshot.rootNode() : nil
        guard let resolvedParent = parent ?? root else {
            return SnapshotBrowserColumn(parent: parent, nodes: [], totalNodeCount: 0, state: .loading)
        }
        let currentParent: ScanNodeSummary? = if let parent {
            await snapshot.node(withID: parent.id) ?? parent
        } else {
            nil
        }
        let page = await snapshot.page(parentID: resolvedParent.id, offset: offset, limit: limit)
        return SnapshotBrowserColumn(
            parent: currentParent,
            nodes: page.nodes,
            totalNodeCount: page.totalCount,
            state: columnState(from: page.state),
            estimatingNodeIDs: page.estimatingNodeIDs,
            pendingNodeIDs: page.pendingNodeIDs,
            isIncomplete: (currentParent ?? root)?.isIncomplete ?? false,
            sizeSummary: parent == nil ? page.sizeSummary : nil
        )
    }

    private func columnState(from state: ScanNodePageState) -> SnapshotBrowserColumnState {
        switch state {
        case .loading: .loading
        case .partial: .partial
        case .complete: .complete
        }
    }
}
