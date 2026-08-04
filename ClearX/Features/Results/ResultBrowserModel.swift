import Combine
import Foundation

@MainActor
final class ResultBrowserModel: ObservableObject {
    @Published private(set) var columns: [SnapshotBrowserColumn] = []
    @Published private(set) var selectedNodeIDs: [ScanNodeID] = []
    @Published private(set) var presentationState: ScanPresentationState

    let source: ScanSource

    private let columnLoader: any SnapshotColumnLoading
    private let workPrioritizer: (any ScanWorkPrioritizing)?
    private var queryGeneration = 0
    private var visibleNodeCounts: [Int] = []

    static let initialColumnRowLimit = 250

    init(source: ScanSource, columnLoader: any SnapshotColumnLoading, workPrioritizer: (any ScanWorkPrioritizing)? = nil, presentationState: ScanPresentationState = .idle) {
        self.source = source
        self.columnLoader = columnLoader
        self.workPrioritizer = workPrioritizer
        self.presentationState = presentationState
    }

    func loadInitialColumn() async {
        queryGeneration &+= 1
        await replaceColumn(at: 0, parent: nil, generation: queryGeneration)
    }

    func select(_ node: ScanNodeSummary, inColumn columnIndex: Int) async {
        guard columns.indices.contains(columnIndex) else { return }

        queryGeneration &+= 1
        selectedNodeIDs = Array(selectedNodeIDs.prefix(columnIndex))
        selectedNodeIDs.append(node.id)
        columns.removeSubrange(columns.index(after: columnIndex)..<columns.endIndex)
        visibleNodeCounts.removeSubrange(columns.count..<visibleNodeCounts.count)

        guard node.kind == .directory else { return }
        await workPrioritizer?.prioritize(directory: node.url, for: source.id)
        await replaceColumn(at: columnIndex + 1, parent: node, generation: queryGeneration)
    }

    func updatePresentationState(_ newState: ScanPresentationState) {
        presentationState = newState
    }

    /// Accepts scanner-owned incremental results. Partial updates preserve the
    /// order users are already reading; a complete update applies browser sort.
    func applyLiveColumn(_ update: SnapshotBrowserColumnUpdate) {
        let index = visibleColumnIndex(for: update.parent)
        guard let index else { return }

        let replacement: SnapshotBrowserColumn
        if update.state == .complete {
            replacement = SnapshotBrowserColumn(parent: update.parent, nodes: update.nodes, state: .complete, estimatingNodeIDs: update.estimatingNodeIDs)
        } else if columns.indices.contains(index) {
            replacement = mergedPartialColumn(existing: columns[index], update: update)
        } else {
            replacement = SnapshotBrowserColumn(parent: update.parent, nodes: update.nodes, state: update.state, estimatingNodeIDs: update.estimatingNodeIDs)
        }

        replaceVisibleColumn(replacement, at: index)
    }

    func visibleNodes(inColumn index: Int) -> ArraySlice<ScanNodeSummary> {
        guard columns.indices.contains(index), visibleNodeCounts.indices.contains(index) else { return [] }
        return columns[index].nodes.prefix(visibleNodeCounts[index])
    }

    func remainingNodeCount(inColumn index: Int) -> Int {
        guard columns.indices.contains(index), visibleNodeCounts.indices.contains(index) else { return 0 }
        return max(0, columns[index].nodes.count - visibleNodeCounts[index])
    }

    func loadMore(inColumn index: Int) {
        guard columns.indices.contains(index), visibleNodeCounts.indices.contains(index) else { return }
        visibleNodeCounts[index] = min(
            columns[index].nodes.count,
            visibleNodeCounts[index] + Self.initialColumnRowLimit
        )
        objectWillChange.send()
    }

    func liveColumnParents() -> [ScanNodeSummary?] {
        columns.map(\.parent)
    }

    private func replaceColumn(at index: Int, parent: ScanNodeSummary?, generation: Int) async {
        do {
            let column = try await columnLoader.loadColumn(for: source, parent: parent)
            guard generation == queryGeneration else { return }
            if columns.indices.contains(index) {
                columns[index] = column
                updateVisibleCount(for: column, at: index)
            } else {
                columns.append(column)
                visibleNodeCounts.append(min(Self.initialColumnRowLimit, column.nodes.count))
            }
        } catch {
            guard generation == queryGeneration else { return }
            presentationState = .synchronizationFailed(error.localizedDescription)
        }
    }

    private func visibleColumnIndex(for parent: ScanNodeSummary?) -> Int? {
        if parent == nil {
            return 0
        }
        if let existingIndex = columns.firstIndex(where: { $0.parent?.id == parent?.id }) {
            return existingIndex
        }
        guard let selectionIndex = selectedNodeIDs.firstIndex(of: parent!.id) else { return nil }
        return selectionIndex + 1 <= columns.count ? selectionIndex + 1 : nil
    }

    private func mergedPartialColumn(existing: SnapshotBrowserColumn, update: SnapshotBrowserColumnUpdate) -> SnapshotBrowserColumn {
        let incomingByID = Dictionary(uniqueKeysWithValues: update.nodes.map { ($0.id, $0) })
        var merged = existing.nodes.compactMap { incomingByID[$0.id] ?? $0 }
        let existingIDs = Set(existing.nodes.map(\.id))
        merged.append(contentsOf: update.nodes.filter { !existingIDs.contains($0.id) })
        return SnapshotBrowserColumn(parent: update.parent, nodes: merged, state: update.state, estimatingNodeIDs: update.estimatingNodeIDs, sortsNodes: false)
    }

    private func replaceVisibleColumn(_ column: SnapshotBrowserColumn, at index: Int) {
        if columns.indices.contains(index) {
            columns[index] = column
            updateVisibleCount(for: column, at: index)
        } else {
            columns.append(column)
            visibleNodeCounts.append(min(Self.initialColumnRowLimit, column.nodes.count))
        }
    }

    private func updateVisibleCount(for column: SnapshotBrowserColumn, at index: Int) {
        let currentCount = visibleNodeCounts.indices.contains(index) ? visibleNodeCounts[index] : 0
        let nextCount = max(currentCount, min(Self.initialColumnRowLimit, column.nodes.count))
        if visibleNodeCounts.indices.contains(index) {
            visibleNodeCounts[index] = min(nextCount, column.nodes.count)
        } else {
            visibleNodeCounts.append(min(Self.initialColumnRowLimit, column.nodes.count))
        }
    }
}
