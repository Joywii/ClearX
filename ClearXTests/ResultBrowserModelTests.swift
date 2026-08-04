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
        let model = ResultBrowserModel(source: makeSource(), columnLoader: ColumnLoaderStub(columns: [:]))

        model.applyLiveColumn(.init(parent: nil, nodes: [first], state: .partial))
        model.applyLiveColumn(.init(parent: nil, nodes: [second, first], state: .partial))

        XCTAssertEqual(model.columns[0].nodes.map(\.id), [first.id, second.id])
        XCTAssertEqual(model.columns[0].state, .partial)

        model.applyLiveColumn(.init(parent: nil, nodes: [first, second], state: .complete))

        XCTAssertEqual(model.columns[0].nodes.map(\.id), [second.id, first.id])
        XCTAssertEqual(model.columns[0].state, .complete)
    }

    func testLiveColumnShowsFirst250RowsAndLoadsMoreOnDemand() async {
        let nodes = (0..<251).map { index in
            makeNode(name: "项目-\(index)", size: Int64(index))
        }
        let model = ResultBrowserModel(source: makeSource(), columnLoader: ColumnLoaderStub(columns: [:]))

        model.applyLiveColumn(.init(parent: nil, nodes: nodes, state: .complete))

        XCTAssertEqual(model.visibleNodes(inColumn: 0).count, 250)
        XCTAssertEqual(model.remainingNodeCount(inColumn: 0), 1)

        model.loadMore(inColumn: 0)

        XCTAssertEqual(model.visibleNodes(inColumn: 0).count, 251)
        XCTAssertEqual(model.remainingNodeCount(inColumn: 0), 0)
    }

    func testLiveLoadingColumnSupportsSkeletonStateAndEstimateMarkers() async {
        let node = makeNode(name: "目录", kind: .directory, size: 0)
        let model = ResultBrowserModel(source: makeSource(), columnLoader: ColumnLoaderStub(columns: [:]))

        model.applyLiveColumn(.init(parent: nil, nodes: [node], state: .loading, estimatingNodeIDs: [node.id]))

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
}

private actor ColumnLoaderStub: SnapshotColumnLoading {
    private let columns: [ScanNodeID?: SnapshotBrowserColumn]
    private var parents: [ScanNodeID?] = []

    init(columns: [ScanNodeID?: SnapshotBrowserColumn]) {
        self.columns = columns
    }

    func loadColumn(for source: ScanSource, parent: ScanNodeSummary?) async throws -> SnapshotBrowserColumn {
        parents.append(parent?.id)
        return columns[parent?.id] ?? SnapshotBrowserColumn(parent: parent, nodes: [])
    }

    func requestedParents() -> [ScanNodeID?] {
        parents
    }
}

private struct FailingColumnLoader: SnapshotColumnLoading {
    func loadColumn(for source: ScanSource, parent: ScanNodeSummary?) async throws -> SnapshotBrowserColumn {
        throw ColumnLoadError.unavailable
    }

    private enum ColumnLoadError: Error {
        case unavailable
    }
}
