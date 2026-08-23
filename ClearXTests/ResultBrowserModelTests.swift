import XCTest
@testable import ClearX

@MainActor
final class ResultBrowserModelTests: XCTestCase {
    func testInitialLoadUsesRootColumn() async {
        let source = makeSource()
        let loader = ColumnLoaderStub(columns: [nil: SnapshotBrowserColumn(parent: nil, nodes: [makeNode(name: "B", size: 1), makeNode(name: "A", size: 2)])])
        let model = ResultBrowserModel(source: source, columnLoader: loader)

        await model.loadInitialColumn()

        XCTAssertEqual(model.columns.count, 1)
        XCTAssertEqual(model.columns[0].nodes.map(\.name), ["A", "B"])
        let requestedParents = await loader.requestedParents()
        XCTAssertEqual(requestedParents, [nil])
    }

    func testSelectingDirectoryLoadsOnlyItsChildren() async {
        let source = makeSource()
        let directory = makeNode(name: "资料", kind: .directory, size: 100)
        let leaf = makeNode(name: "报告.pdf", parentID: directory.id, kind: .file, size: 30)
        let loader = ColumnLoaderStub(columns: [
            nil: SnapshotBrowserColumn(parent: nil, nodes: [directory]),
            directory.id: SnapshotBrowserColumn(parent: directory, nodes: [leaf])
        ])
        let model = ResultBrowserModel(source: source, columnLoader: loader)

        await model.loadInitialColumn()
        await model.select(directory, inColumn: 0)

        XCTAssertEqual(model.columns.count, 2)
        XCTAssertEqual(model.columns[1].nodes, [leaf])
        XCTAssertEqual(model.selectedNodeIDs, [directory.id])
        let requestedParents = await loader.requestedParents()
        XCTAssertEqual(requestedParents, [nil, directory.id])
    }

    func testSelectingFileDoesNotLoadAnAdditionalColumn() async {
        let source = makeSource()
        let file = makeNode(name: "日志", kind: .file, size: 5)
        let loader = ColumnLoaderStub(columns: [nil: SnapshotBrowserColumn(parent: nil, nodes: [file])])
        let model = ResultBrowserModel(source: source, columnLoader: loader)

        await model.loadInitialColumn()
        await model.select(file, inColumn: 0)

        XCTAssertEqual(model.columns.count, 1)
        let requestedParents = await loader.requestedParents()
        XCTAssertEqual(requestedParents, [nil])
    }

    func testLoadFailureShowsSynchronizationFailure() async {
        let model = ResultBrowserModel(source: makeSource(), columnLoader: FailingColumnLoader())

        await model.loadInitialColumn()

        guard case .synchronizationFailed = model.presentationState else {
            return XCTFail("Expected a synchronization failure")
        }
    }

    func testPartialLiveUpdateKeepsExistingRowOrderUntilColumnCompletes() async {
        let first = makeNode(name: "先发现", size: 10)
        let second = makeNode(name: "后发现", size: 100)
        let loader = ColumnLoaderStub(columns: [
            nil: SnapshotBrowserColumn(parent: nil, nodes: [first], state: .partial)
        ])
        let model = ResultBrowserModel(source: makeSource(), columnLoader: loader)

        await model.loadInitialColumn()
        await loader.setColumn(SnapshotBrowserColumn(parent: nil, nodes: [first, second], state: .partial), for: nil)
        await model.refreshVisibleColumns(for: makeProgress(changedParentIDs: [ScanNodeID()]))

        XCTAssertEqual(model.columns[0].nodes.map(\.id), [first.id, second.id])
        XCTAssertEqual(model.columns[0].state, .partial)

        await loader.setColumn(SnapshotBrowserColumn(parent: nil, nodes: [first, second], state: .complete), for: nil)
        await model.refreshVisibleColumns(for: makeProgress(completedDirectoryIDs: [ScanNodeID()]))

        XCTAssertEqual(model.columns[0].nodes.map(\.id), [second.id, first.id])
        XCTAssertEqual(model.columns[0].state, .complete)
    }

    func testLiveColumnShowsFirst250RowsAndLoadsMoreOnDemand() async {
        let nodes = (0..<251).map { index in
            makeNode(name: "项目-\(index)", size: Int64(index))
        }
        let loader = ColumnLoaderStub(columns: [nil: SnapshotBrowserColumn(parent: nil, nodes: nodes)])
        let model = ResultBrowserModel(source: makeSource(), columnLoader: loader)

        await model.loadInitialColumn()

        XCTAssertEqual(model.visibleNodes(inColumn: 0).count, 250)
        XCTAssertEqual(model.remainingNodeCount(inColumn: 0), 1)

        await model.loadMore(inColumn: 0)

        XCTAssertEqual(model.visibleNodes(inColumn: 0).count, 251)
        XCTAssertEqual(model.remainingNodeCount(inColumn: 0), 0)
    }

    func testLiveLoadingColumnSupportsSkeletonStateAndEstimateMarkers() async {
        let node = makeNode(name: "目录", kind: .directory, size: 0)
        let loader = ColumnLoaderStub(columns: [
            nil: SnapshotBrowserColumn(parent: nil, nodes: [node], state: .loading, estimatingNodeIDs: [node.id])
        ])
        let model = ResultBrowserModel(source: makeSource(), columnLoader: loader)

        await model.loadInitialColumn()

        XCTAssertEqual(model.columns[0].state, .loading)
        XCTAssertEqual(model.columns[0].estimatingNodeIDs, [node.id])
    }

    func testColumnWidthsAreRetainedByDepthAndResetIndependently() {
        var widths = BrowserColumnWidthState()

        widths.setWidth(480, for: 2)
        widths.setWidth(360, for: 1)

        XCTAssertEqual(widths.width(for: 0), BrowserColumnWidthState.defaultWidth)
        XCTAssertEqual(widths.width(for: 1), 360)
        XCTAssertEqual(widths.width(for: 2), 480)

        widths.resetWidth(for: 2)

        XCTAssertEqual(widths.width(for: 1), 360)
        XCTAssertEqual(widths.width(for: 2), BrowserColumnWidthState.defaultWidth)
    }

    func testColumnWidthsClampToSupportedRange() {
        var widths = BrowserColumnWidthState()

        widths.setWidth(100, for: 0)
        widths.setWidth(2_000, for: 1)

        XCTAssertEqual(widths.width(for: 0), BrowserColumnWidthState.minimumWidth)
        XCTAssertEqual(widths.width(for: 1), BrowserColumnWidthState.maximumWidth)
    }

    private func makeSource() -> ScanSource {
        ScanSource(kind: .folder, rootURL: URL(fileURLWithPath: "/tmp/clearx-tests"), displayName: "测试")
    }

    private func makeNode(name: String, parentID: ScanNodeID? = nil, kind: ScanNodeKind = .file, size: Int64) -> ScanNodeSummary {
        ScanNodeSummary(parentID: parentID, url: URL(fileURLWithPath: "/tmp/clearx-tests/\(name)"), kind: kind, allocatedSize: size)
    }

    private func makeProgress(
        changedParentIDs: Set<ScanNodeID> = [],
        completedDirectoryIDs: Set<ScanNodeID> = []
    ) -> ScanProgress {
        ScanProgress(
            discoveredNodeCount: 0,
            completedDirectoryCount: 0,
            currentURL: nil,
            changedParentIDs: changedParentIDs,
            completedDirectoryIDs: completedDirectoryIDs
        )
    }
}

private actor ColumnLoaderStub: SnapshotColumnLoading {
    private var columns: [ScanNodeID?: SnapshotBrowserColumn]
    private var parents: [ScanNodeID?] = []

    init(columns: [ScanNodeID?: SnapshotBrowserColumn]) {
        self.columns = columns
    }

    func loadColumn(
        for source: ScanSource,
        parent: ScanNodeSummary?,
        offset: Int,
        limit: Int
    ) async throws -> SnapshotBrowserColumn {
        parents.append(parent?.id)
        let column = columns[parent?.id] ?? SnapshotBrowserColumn(parent: parent, nodes: [])
        let lowerBound = min(max(0, offset), column.nodes.count)
        let upperBound = min(column.nodes.count, lowerBound + limit)
        let pageNodes = Array(column.nodes[lowerBound..<upperBound])
        return SnapshotBrowserColumn(
            parent: column.parent,
            nodes: pageNodes,
            totalNodeCount: column.totalNodeCount,
            state: column.state,
            estimatingNodeIDs: column.estimatingNodeIDs.intersection(pageNodes.map(\.id))
        )
    }

    func setColumn(_ column: SnapshotBrowserColumn, for parentID: ScanNodeID?) {
        columns[parentID] = column
    }

    func requestedParents() -> [ScanNodeID?] {
        parents
    }
}

private struct FailingColumnLoader: SnapshotColumnLoading {
    func loadColumn(
        for source: ScanSource,
        parent: ScanNodeSummary?,
        offset: Int,
        limit: Int
    ) async throws -> SnapshotBrowserColumn {
        throw ColumnLoadError.unavailable
    }

    private enum ColumnLoadError: Error {
        case unavailable
    }
}
