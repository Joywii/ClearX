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

    func store(_ result: ScanResult) {
        guard case .complete = result.status else { return }
        results[result.source.rootURL.standardizedFileURL] = result
    }

    func removeResult(for source: ScanSource) {
        results.removeValue(forKey: source.rootURL.standardizedFileURL)
    }
}

/// Holds the mutable tree for one in-flight scan. It is separate from the
/// complete-result cache so cancelled scans remain browsable but are never reused.
actor LiveScanTree {
    private var nodes: [ScanNodeID: ScanNodeSummary] = [:]
    private var childrenByParent: [ScanNodeID: [ScanNodeID]] = [:]
    private var rootNodeID: ScanNodeID?
    private var completedDirectoryURLs = Set<URL>()

    func reset() {
        nodes.removeAll(keepingCapacity: true)
        childrenByParent.removeAll(keepingCapacity: true)
        rootNodeID = nil
        completedDirectoryURLs.removeAll(keepingCapacity: true)
    }

    func apply(_ progress: ScanProgress) {
        for node in progress.updatedNodes {
            if nodes[node.id] == nil, let parentID = node.parentID {
                childrenByParent[parentID, default: []].append(node.id)
            }
            nodes[node.id] = node
            if node.parentID == nil {
                rootNodeID = node.id
            }
        }
        completedDirectoryURLs.formUnion(progress.completedDirectoryURLs)
    }

    func column(for parent: ScanNodeSummary?) -> SnapshotBrowserColumnUpdate {
        guard let resolvedParent = parent ?? rootNodeID.flatMap({ nodes[$0] }) else {
            return SnapshotBrowserColumnUpdate(parent: parent, nodes: [], state: .loading)
        }
        let childNodes = (childrenByParent[resolvedParent.id] ?? []).compactMap { nodes[$0] }
        let isComplete = completedDirectoryURLs.contains(resolvedParent.url.standardizedFileURL)
        let estimates = Set(childNodes.compactMap { node in
            node.kind == .directory && !completedDirectoryURLs.contains(node.url.standardizedFileURL) ? node.id : nil
        })
        return SnapshotBrowserColumnUpdate(
            parent: parent,
            nodes: childNodes,
            state: isComplete ? .complete : .partial,
            estimatingNodeIDs: estimates
        )
    }
}

/// Adapts a session-cached scan tree to the result browser's lazy-column API.
struct InMemorySnapshotColumnLoader: SnapshotColumnLoading {
    let cache: InMemoryScanCache
    let liveTree: LiveScanTree?

    init(cache: InMemoryScanCache = .shared, liveTree: LiveScanTree? = nil) {
        self.cache = cache
        self.liveTree = liveTree
    }

    func loadColumn(for source: ScanSource, parent: ScanNodeSummary?) async throws -> SnapshotBrowserColumn {
        if let result = await cache.result(for: source), let root = result.rootNode {
            let parentNode = parent ?? root
            return SnapshotBrowserColumn(parent: parent, nodes: result.children(of: parentNode.id))
        }
        guard let liveTree else {
            return SnapshotBrowserColumn(parent: parent, nodes: [], state: .loading)
        }
        let update = await liveTree.column(for: parent)
        return SnapshotBrowserColumn(
            parent: update.parent,
            nodes: update.nodes,
            state: update.state,
            estimatingNodeIDs: update.estimatingNodeIDs,
            sortsNodes: update.state == .complete
        )
    }
}
