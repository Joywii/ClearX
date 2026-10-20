import Combine
import XCTest
@testable import ClearX

@MainActor
final class ResultBrowserModelTests: XCTestCase {
    func testOnlyActiveScanHidesTrashIncludingRescansDisplayingPreviousResults() {
        let model = ResultBrowserModel(source: makeSource(), columnLoader: ColumnLoaderStub(columns: [:]))
        let progress = ScanProgress(discoveredNodeCount: 1, completedDirectoryCount: 0, currentURL: nil)
        for previous in [false, true] {
            model.updatePresentationState(.scanning(progress), displayingPreviousResult: previous)
            XCTAssertTrue(model.isScanning)
            for state in [ScanPresentationState.idle, .cancelled, .synchronizationFailed("test"),
                          .unavailable(model.source.rootURL), .permissionRestricted(model.source.rootURL),
                          .incomplete(.permissionRestricted),
                          .completed(.incomplete([.cancelled])), .completed(.complete)] {
                model.updatePresentationState(state, displayingPreviousResult: previous)
                XCTAssertFalse(model.isScanning, "Stopped state must not hide Trash: \(state)")
            }
        }
    }

    func testClearingAncestorColumnKeepsLeftHighlightsAndRemovesDescendants() async {
        let a = makeNode(name: "A", kind: .directory, size: 3)
        let b = makeNode(name: "B", kind: .directory, size: 2)
        let c = makeNode(name: "C", size: 1)
        let loader = ColumnLoaderStub(columns: [nil: SnapshotBrowserColumn(parent: nil, nodes: [a]),
                                                a.id: SnapshotBrowserColumn(parent: a, nodes: [b]),
                                                b.id: SnapshotBrowserColumn(parent: b, nodes: [c])])
        let model = ResultBrowserModel(source: makeSource(), columnLoader: loader)
        await model.loadInitialColumn()
        await model.select(a, inColumn: 0)
        await model.select(b, inColumn: 1)
        await model.select(c, inColumn: 2)
        model.beginSelectionGesture(inColumn: 1)
        model.updateSelection([], inColumn: 1)
        await model.finishSelectionGesture(inColumn: 1)
        XCTAssertEqual(model.columns.count, 2)
        XCTAssertEqual(model.highlightedIDs(inColumn: 0), [a.id])
        XCTAssertTrue(model.highlightedIDs(inColumn: 1).isEmpty)
        XCTAssertTrue(model.selectedItemIDs.isEmpty)
        XCTAssertEqual(model.selectedNodeIDs, [a.id])
        model.beginSelectionGesture(inColumn: 0)
        model.updateSelection([], inColumn: 0)
        await model.finishSelectionGesture(inColumn: 0)
        XCTAssertEqual(model.columns.count, 1)
        XCTAssertTrue(model.selectedNodeIDs.isEmpty)
    }

    func testMultiSelectionCollapsesAndSingleDirectoryExpandsOnlyOnRelease() async {
        let a = makeNode(name: "A", kind: .directory, size: 2)
        let b = makeNode(name: "B", kind: .directory, size: 1)
        let loader = ColumnLoaderStub(columns: [nil: SnapshotBrowserColumn(parent: nil, nodes: [a, b])])
        let model = ResultBrowserModel(source: makeSource(), columnLoader: loader)
        await model.loadInitialColumn()
        await model.select(a, inColumn: 0)
        model.beginSelectionGesture(inColumn: 0)
        model.updateSelection([a.id, b.id], inColumn: 0)
        XCTAssertEqual(model.columns.count, 1)
        XCTAssertEqual(model.contextTargets(for: a, inColumn: 0).map(\.id), [a.id, b.id])
        model.updateSelection([b.id], inColumn: 0)
        XCTAssertEqual(model.columns.count, 1)
        await model.finishSelectionGesture(inColumn: 0)
        XCTAssertEqual(model.columns.count, 2)
        XCTAssertEqual(model.columns[1].parent?.id, b.id)
        model.beginSelectionGesture(inColumn: 0)
        model.updateSelection([], inColumn: 0)
        await model.finishSelectionGesture(inColumn: 0)
        XCTAssertEqual(model.columns.count, 1)
        XCTAssertTrue(model.selectedItemIDs.isEmpty)
    }

    func testAncestorHighlightsAreNotBatchMembersAndContextClickDoesNotMutateSelection() async {
        let a = makeNode(name: "A", kind: .directory, size: 2)
        let b = makeNode(name: "B", size: 1)
        let c = makeNode(name: "C", size: 1)
        let d = makeNode(name: "D", size: 1)
        let loader = ColumnLoaderStub(columns: [nil: SnapshotBrowserColumn(parent: nil, nodes: [a]),
                                                a.id: SnapshotBrowserColumn(parent: a, nodes: [b, c, d])])
        let model = ResultBrowserModel(source: makeSource(), columnLoader: loader)
        await model.loadInitialColumn()
        await model.select(a, inColumn: 0)
        model.updateSelection([b.id, c.id], inColumn: 1)
        XCTAssertEqual(model.highlightedIDs(inColumn: 0), [a.id])
        XCTAssertEqual(model.contextTargets(for: a, inColumn: 0).map(\.id), [a.id])
        XCTAssertEqual(model.contextTargets(for: d, inColumn: 1).map(\.id), [d.id])
        XCTAssertEqual(model.selectedItemIDs, [b.id, c.id])
        XCTAssertEqual(model.selectedNodeIDs, [a.id])
    }

    func testDragFreezesOrderAndRestoresSortingWithoutLosingIDs() async {
        let a = makeNode(name: "A", size: 2)
        let b = makeNode(name: "B", size: 1)
        let loader = ColumnLoaderStub(columns: [nil: SnapshotBrowserColumn(parent: nil, nodes: [a, b])])
        let model = ResultBrowserModel(source: makeSource(), columnLoader: loader)
        await model.loadInitialColumn()
        model.beginSelectionGesture(inColumn: 0)
        model.updateSelection([a.id, b.id], inColumn: 0)
        let biggerB = ScanNodeSummary(id: b.id, parentID: nil, url: b.url, kind: .file, allocatedSize: 100)
        await loader.setColumn(SnapshotBrowserColumn(parent: nil, nodes: [a, biggerB]), for: nil)
        await model.refreshAllColumns()
        XCTAssertEqual(model.columns[0].nodes.map(\.id), [a.id, b.id])
        await model.finishSelectionGesture(inColumn: 0)
        XCTAssertEqual(model.columns[0].nodes.map(\.id), [b.id, a.id])
        XCTAssertEqual(model.selectedItemIDs, [a.id, b.id])
    }

    func testStaleNoticeSurvivesCancelledAndFailedRescans() {
        let model = ResultBrowserModel(source: makeSource(), columnLoader: ColumnLoaderStub(columns: [:]))
        model.isStale = true
        model.updatePresentationState(.cancelled)
        XCTAssertTrue(model.scanNotice?.contains("过期") == true)
        model.updatePresentationState(.synchronizationFailed("test"))
        XCTAssertTrue(model.scanNotice?.contains("过期") == true)
        XCTAssertTrue(model.sizeSummaryStatus.contains("过期"))
    }

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

    func testSwitchingSiblingKeepsChildSlotThroughoutSuspendedLoad() async throws {
        let first = makeNode(name: "first", kind: .directory, size: 2)
        let second = makeNode(name: "second", kind: .directory, size: 1)
        let loader = ColumnLoaderStub(columns: [nil: SnapshotBrowserColumn(parent: nil, nodes: [first, second])])
        let model = ResultBrowserModel(source: makeSource(), columnLoader: loader)
        await model.loadInitialColumn()
        await model.select(first, inColumn: 0)
        var publishedCounts: [Int] = []
        let subscription = model.$columns.sink { publishedCounts.append($0.count) }
        defer { subscription.cancel() }

        await loader.pauseNextLoad(for: second.id)
        let selection = Task { await model.select(second, inColumn: 0) }
        await loader.waitUntilPaused()
        XCTAssertEqual(model.selectedNodeIDs, [second.id])
        let placeholder = try XCTUnwrap(model.columns.last)
        XCTAssertEqual(model.columns.count, 2)
        XCTAssertEqual(placeholder.parent?.id, second.id)
        XCTAssertEqual(placeholder.state, .loading)
        XCTAssertTrue(placeholder.nodes.isEmpty)

        await loader.resumeLoad()
        await selection.value
        XCTAssertEqual(model.columns[1].state, .complete)
        XCTAssertTrue(publishedCounts.allSatisfy { $0 == 2 }, "No transient removal before the replacement")
    }

    func testReselectingDirectoryKeepsLoadedChildPageButTruncatesDeeperNavigation() async {
        let directory = makeNode(name: "directory", kind: .directory, size: 500)
        let children = (0..<251).map { makeNode(name: "child-\($0)", parentID: directory.id, kind: .directory, size: Int64($0)) }
        let loader = ColumnLoaderStub(columns: [
            nil: SnapshotBrowserColumn(parent: nil, nodes: [directory]),
            directory.id: SnapshotBrowserColumn(parent: directory, nodes: children)
        ])
        let model = ResultBrowserModel(source: makeSource(), columnLoader: loader)
        await model.loadInitialColumn()
        await model.select(directory, inColumn: 0)
        await model.loadMore(inColumn: 1)
        await model.select(children[0], inColumn: 1)
        let childColumn = model.columns[1]
        let requestsBefore = await loader.requestedParents()

        await model.select(directory, inColumn: 0)

        XCTAssertEqual(model.columns.count, 2)
        XCTAssertEqual(model.columns[1], childColumn)
        XCTAssertEqual(model.columns[1].nodes.count, 251)
        XCTAssertEqual(model.selectedNodeIDs, [directory.id])
        let requestsAfter = await loader.requestedParents()
        XCTAssertEqual(requestsAfter, requestsBefore)
    }

    func testStaleChildLoadCannotOverwriteNewerSelection() async {
        let first = makeNode(name: "first", kind: .directory, size: 2)
        let second = makeNode(name: "second", kind: .directory, size: 1)
        let loader = ColumnLoaderStub(columns: [nil: SnapshotBrowserColumn(parent: nil, nodes: [first, second])])
        let model = ResultBrowserModel(source: makeSource(), columnLoader: loader)
        await model.loadInitialColumn()
        await loader.pauseNextLoad(for: first.id)
        let earlier = Task { await model.select(first, inColumn: 0) }
        await loader.waitUntilPaused()
        await model.select(second, inColumn: 0)
        await loader.resumeLoad()
        await earlier.value
        XCTAssertEqual(model.columns.count, 2)
        XCTAssertEqual(model.columns[1].parent?.id, second.id)
        XCTAssertEqual(model.selectedNodeIDs, [second.id])
    }

    func testLeafSelectionRemovesLoadingChildAndIgnoresItsCompletion() async {
        let directory = makeNode(name: "directory", kind: .directory, size: 2)
        let file = makeNode(name: "file", size: 1)
        let loader = ColumnLoaderStub(columns: [nil: SnapshotBrowserColumn(parent: nil, nodes: [directory, file])])
        let model = ResultBrowserModel(source: makeSource(), columnLoader: loader)
        await model.loadInitialColumn()
        await loader.pauseNextLoad(for: directory.id)
        let earlier = Task { await model.select(directory, inColumn: 0) }
        await loader.waitUntilPaused()
        await model.select(file, inColumn: 0)
        await loader.resumeLoad()
        await earlier.value
        XCTAssertEqual(model.columns.count, 1)
        XCTAssertEqual(model.selectedNodeIDs, [file.id])
    }

    func testFailedChildLoadRemovesPlaceholderAndAllowsRetry() async {
        let directory = makeNode(name: "directory", kind: .directory, size: 2)
        let loader = ColumnLoaderStub(columns: [nil: SnapshotBrowserColumn(parent: nil, nodes: [directory])])
        let model = ResultBrowserModel(source: makeSource(), columnLoader: loader)
        await model.loadInitialColumn()
        await loader.pauseNextLoad(for: directory.id)
        let selection = Task { await model.select(directory, inColumn: 0) }
        await loader.waitUntilPaused()
        await loader.resumeLoad(failing: true)
        await selection.value
        XCTAssertEqual(model.columns.count, 1)
        guard case .synchronizationFailed = model.presentationState else {
            return XCTFail("Expected a load failure, not a permanent loading column")
        }
        await model.select(directory, inColumn: 0)
        XCTAssertEqual(model.columns.count, 2)
        XCTAssertEqual(model.columns[1].state, .complete)
    }

    func testEarlierSelectionCannotReplaceLaterSelectionAfterPrioritization() async {
        let first = makeNode(name: "first", kind: .directory, size: 2)
        let second = makeNode(name: "second", kind: .directory, size: 1)
        let loader = ColumnLoaderStub(columns: [nil: SnapshotBrowserColumn(parent: nil, nodes: [first, second])])
        let prioritizer = SuspendedFirstPrioritizer()
        let model = ResultBrowserModel(source: makeSource(), columnLoader: loader, workPrioritizer: prioritizer)
        await model.loadInitialColumn()
        let earlierSelection = Task { await model.select(first, inColumn: 0) }
        await prioritizer.waitUntilSuspended()

        await model.select(second, inColumn: 0)
        await prioritizer.resume()
        await earlierSelection.value

        XCTAssertEqual(model.selectedNodeIDs, [second.id])
        XCTAssertEqual(model.columns.count, 2)
        XCTAssertEqual(model.columns[1].parent?.id, second.id)
        let requestedParents = await loader.requestedParents()
        XCTAssertEqual(requestedParents, [nil, second.id])
    }

    func testLoadFailureShowsSynchronizationFailure() async {
        let model = ResultBrowserModel(source: makeSource(), columnLoader: FailingColumnLoader())

        await model.loadInitialColumn()

        guard case .synchronizationFailed = model.presentationState else {
            return XCTFail("Expected a synchronization failure")
        }
    }

    func testSelectingTraversalBoundaryDoesNotLoadAnAdditionalColumn() async {
        for kind in [ScanNodeKind.symbolicLink, .mountPoint] {
            let node = makeNode(name: "boundary", kind: kind, size: 0)
            let loader = ColumnLoaderStub(columns: [nil: SnapshotBrowserColumn(parent: nil, nodes: [node])])
            let model = ResultBrowserModel(source: makeSource(), columnLoader: loader)
            await model.loadInitialColumn()
            await model.select(node, inColumn: 0)
            XCTAssertEqual(model.columns.count, 1)
            XCTAssertEqual(model.selectedNodeIDs, [node.id])
            let requestedParents = await loader.requestedParents()
            XCTAssertEqual(requestedParents, [nil])
        }
    }

    func testPartialLiveUpdateSortsByCurrentSize() async {
        let first = makeNode(name: "先发现", size: 10)
        let second = makeNode(name: "后发现", size: 100)
        let loader = ColumnLoaderStub(columns: [
            nil: SnapshotBrowserColumn(parent: nil, nodes: [first], state: .partial)
        ])
        let model = ResultBrowserModel(source: makeSource(), columnLoader: loader)

        await model.loadInitialColumn()
        await loader.setColumn(SnapshotBrowserColumn(parent: nil, nodes: [first, second], state: .partial), for: nil)
        await model.refreshVisibleColumns(for: makeProgress(changedParentIDs: [ScanNodeID()]))

        XCTAssertEqual(model.columns[0].nodes.map(\.id), [second.id, first.id])
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

    func testLiveLoadingColumnKeepsRealRowsAndEstimateMarkers() async {
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

        XCTAssertEqual(BrowserColumnWidthState.defaultWidth, BrowserColumnWidthState.minimumWidth)
        XCTAssertEqual(widths.width(for: 0), 220)

        widths.setWidth(480, for: 2)
        widths.setWidth(360, for: 1)

        XCTAssertEqual(widths.width(for: 0), BrowserColumnWidthState.defaultWidth)
        XCTAssertEqual(widths.width(for: 1), 360)
        XCTAssertEqual(widths.width(for: 2), 480)

        widths.resetWidth(for: 2)

        XCTAssertEqual(widths.width(for: 1), 360)
        XCTAssertEqual(widths.width(for: 2), BrowserColumnWidthState.defaultWidth)
        XCTAssertEqual(widths.width(for: 2), BrowserColumnWidthState.minimumWidth)
    }

    func testLiveResortingReloadsPrefixWithoutDuplicatesAndPreservesSelection() async {
        let source = makeSource()
        let store = ScanTreeStore()
        let root = await store.begin(rootURL: source.rootURL, kind: .directory)
        let items: [DiscoveredItem] = (0..<251).map { index in
            var info = stat()
            info.st_dev = 1
            info.st_ino = UInt64(index + 1)
            info.st_mode = mode_t(S_IFDIR)
            return .item(source.rootURL.appending(path: String(format: "folder-%03d", index)), FileStatus(info: info))
        }
        let work = await store.apply(items: items, to: root, expectedDevice: 1, childDepth: 1)
        let displayed = DisplayedScanSnapshot()
        await displayed.set(store)
        let model = ResultBrowserModel(source: source, columnLoader: InMemorySnapshotColumnLoader(displayedSnapshot: displayed))
        await model.loadInitialColumn()
        let selected = model.columns[0].nodes[0]
        await model.select(selected, inColumn: 0)

        var fileInfo = stat()
        fileInfo.st_dev = 1
        fileInfo.st_ino = 999
        fileInfo.st_mode = mode_t(S_IFREG)
        fileInfo.st_blocks = 8
        let last = work[250]
        _ = await store.apply(items: [.item(last.url.appending(path: "file"), FileStatus(info: fileInfo))],
                              to: last.nodeID, expectedDevice: 1, childDepth: 2)
        await model.loadMore(inColumn: 0)
        XCTAssertEqual(model.columns[0].nodes.first?.id, last.nodeID)
        XCTAssertEqual(model.columns[0].nodes.count, 251)
        XCTAssertEqual(Set(model.columns[0].nodes.map(\.id)).count, 251)
        XCTAssertEqual(model.selectedNodeIDs, [selected.id])

        await store.markCancelled()
        await store.finalizeCancelledDirectories()
        _ = await store.finishScan()
        await model.refreshAllColumns()
        XCTAssertEqual(model.columns.count, 2)
        XCTAssertTrue(model.columns.allSatisfy { $0.estimatingNodeIDs.isEmpty && $0.pendingNodeIDs.isEmpty })
        XCTAssertTrue(model.columns[1].isIncomplete)
        XCTAssertEqual(model.selectedNodeIDs, [selected.id])
        await model.loadInitialColumn(resetNavigation: true)
        XCTAssertEqual(model.columns.count, 1)
        XCTAssertTrue(model.selectedNodeIDs.isEmpty)
    }

    func testColumnWidthsClampToSupportedRange() {
        var widths = BrowserColumnWidthState()

        widths.setWidth(100, for: 0)
        widths.setWidth(2_000, for: 1)

        XCTAssertEqual(widths.width(for: 0), BrowserColumnWidthState.minimumWidth)
        XCTAssertEqual(widths.width(for: 1), BrowserColumnWidthState.maximumWidth)
    }

    func testResizeUsesStartWidthRatherThanAccumulatingTranslations() {
        let drag = BrowserColumnResizeDrag(startWidth: 290)
        var widths = BrowserColumnWidthState()

        for translation: CGFloat in [10, 20, 40, 80] {
            widths.setWidth(drag.width(forTranslation: translation), for: 1)
            XCTAssertEqual(widths.width(for: 1), 290 + translation)
            XCTAssertEqual(widths.width(for: 0), BrowserColumnWidthState.defaultWidth)
            XCTAssertEqual(widths.width(for: 2), BrowserColumnWidthState.defaultWidth)
        }
        // The final sample can differ from the last onChanged sample.
        widths.setWidth(drag.width(forTranslation: 85), for: 1)
        XCTAssertEqual(widths.width(for: 1), 375)
    }

    func testResizeReversesWithoutDriftAfterReachingWidthLimits() {
        let drag = BrowserColumnResizeDrag(startWidth: 290)

        XCTAssertEqual(drag.width(forTranslation: -100), 220)
        XCTAssertEqual(drag.width(forTranslation: -200), 220)
        XCTAssertEqual(drag.width(forTranslation: -60), 230)
        XCTAssertEqual(drag.width(forTranslation: 1_000), 1_080)
        XCTAssertEqual(drag.width(forTranslation: 800), 1_080)
        XCTAssertEqual(drag.width(forTranslation: 780), 1_070)
        XCTAssertEqual(drag.width(forTranslation: 0), 290)
    }

    func testNewResizeStartsFromPreviouslyCommittedWidth() {
        let firstDrag = BrowserColumnResizeDrag(startWidth: 290)
        let committedWidth = firstDrag.width(forTranslation: 87.5)
        let nextDrag = BrowserColumnResizeDrag(startWidth: committedWidth)

        XCTAssertEqual(nextDrag.width(forTranslation: -12.5), 365)
        XCTAssertEqual(nextDrag.width(forTranslation: 0), 377.5)
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
    private var pausedParentID: ScanNodeID?
    private var loadContinuation: CheckedContinuation<Void, Error>?
    private var pauseWaiter: CheckedContinuation<Void, Never>?

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
        if let pausedParentID, parent?.id == pausedParentID {
            self.pausedParentID = nil
            try await withCheckedThrowingContinuation { continuation in
                loadContinuation = continuation
                pauseWaiter?.resume()
                pauseWaiter = nil
            }
        }
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

    func pauseNextLoad(for parentID: ScanNodeID) {
        pausedParentID = parentID
    }

    func waitUntilPaused() async {
        guard loadContinuation == nil else { return }
        await withCheckedContinuation { pauseWaiter = $0 }
    }

    func resumeLoad(failing: Bool = false) {
        if failing {
            loadContinuation?.resume(throwing: CocoaError(.fileReadUnknown))
        } else {
            loadContinuation?.resume()
        }
        loadContinuation = nil
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

private actor SuspendedFirstPrioritizer: ScanWorkPrioritizing {
    private var continuation: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?
    private var hasSuspended = false

    func prioritize(directory: URL?, for sourceID: ScanSourceID) async {
        guard !hasSuspended else { return }
        hasSuspended = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            started?.resume()
            started = nil
        }
    }

    func waitUntilSuspended() async {
        guard !hasSuspended else { return }
        await withCheckedContinuation { started = $0 }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}
