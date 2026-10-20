import Combine
import Foundation

@MainActor
final class ResultBrowserModel: ObservableObject {
    @Published private(set) var columns: [SnapshotBrowserColumn] = []
    @Published private(set) var selectedNodeIDs: [ScanNodeID] = []
    @Published private(set) var presentationState: ScanPresentationState
    @Published private(set) var isDisplayingPreviousResult = false
    @Published private(set) var selectionColumn: Int?
    @Published private(set) var selectedItemIDs: Set<ScanNodeID> = []
    @Published var isStale = false
    private var frozenColumn: Int?
    private var selectedItems: [ScanNodeSummary] = []

    let source: ScanSource

    private let columnLoader: any SnapshotColumnLoading
    private let workPrioritizer: (any ScanWorkPrioritizing)?
    private var queryGeneration = 0

    static let initialColumnRowLimit = 250

    var sizeSummary: ScanSizeSummary? { columns.first?.sizeSummary }

    var isScanning: Bool {
        if case .scanning = presentationState { return true }
        return false
    }

    var sizeSummaryStatus: String {
        if isStale { return "过期结果，等待完整重扫" }
        guard let summary = sizeSummary else { return "尚无统计结果" }
        if isDisplayingPreviousResult { return "上次完整结果" }
        if summary.isScanning { return "当前已统计，扫描尚未结束" }
        return summary.isIncomplete ? "部分结果，统计不完整" : "完整结果"
    }

    init(source: ScanSource, columnLoader: any SnapshotColumnLoading, workPrioritizer: (any ScanWorkPrioritizing)? = nil, presentationState: ScanPresentationState = .idle) {
        self.source = source
        self.columnLoader = columnLoader
        self.workPrioritizer = workPrioritizer
        self.presentationState = presentationState
    }

    func loadInitialColumn(resetNavigation: Bool = false) async {
        queryGeneration &+= 1
        if resetNavigation {
            selectionColumn = nil
            selectedItemIDs.removeAll()
            selectedItems.removeAll()
            frozenColumn = nil
            selectedNodeIDs.removeAll()
            columns.removeAll()
        }
        await replaceColumn(at: 0, parent: nil, generation: queryGeneration)
    }

    func refreshAllColumns() async {
        guard !columns.isEmpty else {
            await loadInitialColumn()
            return
        }
        queryGeneration &+= 1
        let generation = queryGeneration
        for index in columns.indices {
            guard generation == queryGeneration, columns.indices.contains(index) else { return }
            await reloadColumn(at: index, parent: columns[index].parent,
                               limit: max(Self.initialColumnRowLimit, columns[index].nodes.count), generation: generation)
        }
    }

    func select(_ node: ScanNodeSummary, inColumn columnIndex: Int) async {
        guard columns.indices.contains(columnIndex) else { return }
        frozenColumn = nil
        selectionColumn = columnIndex
        selectedItemIDs = [node.id]
        selectedItems = [node]

        queryGeneration &+= 1
        let generation = queryGeneration
        selectedNodeIDs = Array(selectedNodeIDs.prefix(columnIndex))
        selectedNodeIDs.append(node.id)

        let childIndex = columnIndex + 1
        guard node.kind == .directory else {
            columns = Array(columns.prefix(childIndex))
            return
        }
        let existingChild = columns.indices.contains(childIndex) ? columns[childIndex] : nil
        if let existingChild, existingChild.parent?.id == node.id, existingChild.state != .loading {
            columns = Array(columns.prefix(childIndex)) + [existingChild]
            return
        }
        // Publish the replacement slot before suspending. Removing it first lets
        // the horizontal scroll view clamp its offset to a transient short tree.
        columns = Array(columns.prefix(childIndex)) + [
            SnapshotBrowserColumn(parent: node, nodes: [], state: .loading)
        ]
        await workPrioritizer?.prioritize(directory: node.url, for: source.id)
        guard generation == queryGeneration else { return }
        await replaceColumn(at: columnIndex + 1, parent: node, generation: generation)
    }

    func highlightedIDs(inColumn index: Int) -> Set<ScanNodeID> {
        if selectionColumn == index { return selectedItemIDs }
        return selectedNodeIDs.indices.contains(index) ? [selectedNodeIDs[index]] : []
    }

    func contextTargets(for node: ScanNodeSummary, inColumn index: Int) -> [ScanNodeSummary] {
        guard selectionColumn == index, selectedItemIDs.contains(node.id),
              selectedItemIDs.count > 1, columns.indices.contains(index) else { return [node] }
        return selectedItems
    }

    func beginSelectionGesture(inColumn index: Int) {
        // Invalidate in-flight page queries as well as future refreshes.
        queryGeneration &+= 1
        frozenColumn = index
    }

    func updateSelection(_ ids: Set<ScanNodeID>, inColumn index: Int) {
        guard columns.indices.contains(index) else { return }
        if selectionColumn == index, selectedItemIDs == ids { return }
        queryGeneration &+= 1
        let previous = selectionColumn == index ? selectedItems : []
        let visibleIDs = Set(columns[index].nodes.map(\.id))
        let candidates = columns[index].nodes + previous.filter { !visibleIDs.contains($0.id) }
        selectionColumn = index
        selectedItemIDs = ids.intersection(candidates.map(\.id))
        selectedItems = candidates.filter { selectedItemIDs.contains($0.id) }
        selectedNodeIDs = Array(selectedNodeIDs.prefix(index))
        columns = Array(columns.prefix(index + 1))
    }

    func finishSelectionGesture(inColumn index: Int) async {
        frozenColumn = nil
        if selectedItemIDs.count == 1, columns.indices.contains(index), let node = selectedItems.first {
            await select(node, inColumn: index)
        }
        await refreshAllColumns()
    }

    func updatePresentationState(_ newState: ScanPresentationState, displayingPreviousResult: Bool? = nil) {
        if let displayingPreviousResult { isDisplayingPreviousResult = displayingPreviousResult }
        presentationState = newState
    }

    var scanNotice: String? {
        if isStale {
            let status: String
            switch presentationState {
            case .scanning: status = "正在重新扫描"
            case .cancelled: status = "重新扫描已取消"
            case let .completed(.incomplete(reasons)):
                status = reasons.contains(.cancelled) ? "重新扫描已取消" : "重新扫描未完整完成"
            case let .incomplete(reason):
                status = reason == .cancelled ? "重新扫描已取消" : "重新扫描未完整完成"
            case let .synchronizationFailed(detail): status = "重新扫描失败：\(detail)"
            case .unavailable: status = "扫描源不可用"
            case .permissionRestricted: status = "无法读取扫描源"
            default: status = "等待完整重扫"
            }
            return "\(status)；文件已发生变化，当前仍显示过期结果。"
        }
        let message: String
        switch presentationState {
        case .idle, .scanning, .completed(.complete): return nil
        case .cancelled: message = "扫描已取消"
        case .unavailable: message = "扫描源不可用"
        case .permissionRestricted: message = "无法读取扫描源"
        case let .synchronizationFailed(detail): message = "扫描失败：\(detail)"
        case let .incomplete(reason): return notice(for: [reason])
        case let .completed(.incomplete(reasons)): return notice(for: reasons)
        }
        return message + (isDisplayingPreviousResult ? "，仍显示上次完整结果。" : "。")
    }

    private func notice(for reasons: Set<ScanIncompleteReason>) -> String? {
        let message: String
        if reasons.contains(.sourceUnavailable) { message = "扫描源不可用" }
        else if reasons.contains(.permissionRestricted) { message = "无法读取扫描源" }
        else if reasons.contains(.cancelled) { message = "扫描已取消" }
        else if isDisplayingPreviousResult { message = "本次扫描不完整" }
        else { return nil }
        return message + (isDisplayingPreviousResult ? "，仍显示上次完整结果。" : "，当前结果可能不完整。")
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
            guard generation == queryGeneration, columns.indices.contains(index) else { return }
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
            if columns.indices.contains(index), columns[index].state == .loading {
                columns = Array(columns.prefix(index))
            }
            presentationState = .synchronizationFailed(error.localizedDescription)
        }
    }

    private func reloadColumn(
        at index: Int,
        parent: ScanNodeSummary?,
        limit: Int,
        generation: Int
    ) async {
        guard frozenColumn != index else { return }
        do {
            let column = try await columnLoader.loadColumn(
                for: source,
                parent: parent,
                offset: 0,
                limit: limit
            )
            guard generation == queryGeneration, frozenColumn != index, columns.indices.contains(index) else { return }
            columns[index] = column
        } catch {
            guard generation == queryGeneration else { return }
            presentationState = .synchronizationFailed(error.localizedDescription)
        }
    }
}
