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

        guard node.kind == .directory else { return }
        await workPrioritizer?.prioritize(directory: node.url, for: source.id)
        await replaceColumn(at: columnIndex + 1, parent: node, generation: queryGeneration)
    }

    func updatePresentationState(_ newState: ScanPresentationState) {
        presentationState = newState
    }

    func visibleNodes(inColumn index: Int) -> ArraySlice<ScanNodeSummary> {
        guard columns.indices.contains(index) else { return [] }
        return columns[index].nodes[...]
    }

    func remainingNodeCount(inColumn index: Int) -> Int {
        guard columns.indices.contains(index) else { return 0 }
        return max(0, columns[index].totalNodeCount - columns[index].nodes.count)
    }

    func loadMore(inColumn index: Int) async {
        guard columns.indices.contains(index) else { return }
        let column = columns[index]
        let requestedCount = min(column.totalNodeCount, column.nodes.count + Self.initialColumnRowLimit)
        await reloadColumn(at: index, parent: column.parent, limit: requestedCount, generation: queryGeneration)
    }

    func refreshVisibleColumns(for progress: ScanProgress) async {
        guard !columns.isEmpty else { return }
        let generation = queryGeneration
        for index in columns.indices {
            let parentID = columns[index].parent?.id
            let shouldRefreshRoot = index == 0 && (!progress.changedParentIDs.isEmpty || !progress.completedDirectoryIDs.isEmpty)
            let shouldRefreshParent = parentID.map {
                progress.changedParentIDs.contains($0) || progress.completedDirectoryIDs.contains($0)
            } ?? false
            guard shouldRefreshRoot || shouldRefreshParent else { continue }
            let limit = max(Self.initialColumnRowLimit, columns[index].nodes.count)
            await reloadColumn(at: index, parent: columns[index].parent, limit: limit, generation: generation)
        }
    }

    private func replaceColumn(at index: Int, parent: ScanNodeSummary?, generation: Int) async {
        do {
            let column = try await columnLoader.loadColumn(
                for: source,
                parent: parent,
                offset: 0,
                limit: Self.initialColumnRowLimit
            )
            guard generation == queryGeneration else { return }
            if columns.indices.contains(index) {
                columns[index] = column
            } else {
                columns.append(column)
            }
        } catch {
            guard generation == queryGeneration else { return }
            presentationState = .synchronizationFailed(error.localizedDescription)
        }
    }

    private func reloadColumn(
        at index: Int,
        parent: ScanNodeSummary?,
        limit: Int,
        generation: Int
    ) async {
        do {
            let column = try await columnLoader.loadColumn(
                for: source,
                parent: parent,
                offset: 0,
                limit: limit
            )
            guard generation == queryGeneration, columns.indices.contains(index) else { return }
            columns[index] = column
        } catch {
            guard generation == queryGeneration else { return }
            presentationState = .synchronizationFailed(error.localizedDescription)
        }
    }
}
