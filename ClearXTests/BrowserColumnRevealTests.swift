import AppKit
import SwiftUI
import XCTest
@testable import ClearX

final class BrowserColumnRevealTests: XCTestCase {
    func testNavigationRetainsOnlyEnoughWidthToKeepCurrentViewport() {
        var retention = BrowserViewportRetention()
        retention.capture(frames: [0: BrowserColumnGeometry(parentID: nil, frame: CGRect(x: -424, y: 0, width: 228, height: 440))],
                          viewportWidth: 720)
        XCTAssertEqual(retention.minimumContentWidth, 1144)
        // Returning left can release the reserved area on the next selection.
        retention.capture(frames: [0: BrowserColumnGeometry(parentID: nil, frame: CGRect(x: -100, y: 0, width: 228, height: 440))],
                          viewportWidth: 720)
        XCTAssertEqual(retention.minimumContentWidth, 820)
        retention.reset()
        XCTAssertEqual(retention.minimumContentWidth, 0)
    }

    func testViewportRetentionIgnoresMissingLayoutAndLeadingOverscroll() {
        var retention = BrowserViewportRetention()
        retention.capture(frames: [:], viewportWidth: 720)
        XCTAssertEqual(retention.minimumContentWidth, 0)
        retention.capture(frames: [0: BrowserColumnGeometry(parentID: nil, frame: CGRect(x: 20, y: 0, width: 228, height: 440))],
                          viewportWidth: 720)
        XCTAssertEqual(retention.minimumContentWidth, 720)
    }

    func testClickingLastColumnDirectoryCanRevealItsNewChildColumn() {
        var state = BrowserColumnRevealState()
        let parentID = ScanNodeID()
        let request = state.begin(parentID: parentID, kind: .directory, inColumn: 1, columnCount: 2)
        XCTAssertNotNil(request)
        state.complete(request, succeeded: true)
        XCTAssertEqual(state.consume(frames: frames(parentID: parentID), viewportWidth: 720),
                       .init(columnIndex: 2, alignment: .trailing))
    }

    func testClickingEarlierColumnDoesNotRevealEvenWhenChildIsClipped() {
        var state = BrowserColumnRevealState()
        let parentID = ScanNodeID()
        // The rightmost visible column is not the last column if deeper columns exist.
        let request = state.begin(parentID: parentID, kind: .directory, inColumn: 1, columnCount: 4)
        XCTAssertNil(request)
        state.complete(request, succeeded: true)
        XCTAssertNil(state.consume(frames: frames(parentID: parentID), viewportWidth: 720))
        XCTAssertNil(state.pending)
    }

    func testClickingEarlierColumnCancelsAnOlderPendingReveal() {
        var state = BrowserColumnRevealState()
        let parentID = ScanNodeID()
        let earlierRequest = state.begin(parentID: parentID, kind: .directory, inColumn: 1, columnCount: 2)
        XCTAssertNil(state.begin(parentID: ScanNodeID(), kind: .directory, inColumn: 0, columnCount: 2))
        state.complete(earlierRequest, succeeded: true)
        XCTAssertNil(state.consume(frames: frames(parentID: parentID), viewportWidth: 720))
    }

    func testSingleRootColumnCanRevealOnlyWhenNewColumnIsClipped() {
        for x in [298.0, 600.0] {
            var state = BrowserColumnRevealState()
            let parentID = ScanNodeID()
            let request = state.begin(parentID: parentID, kind: .directory, inColumn: 0, columnCount: 1)
            XCTAssertNotNil(request)
            state.complete(request, succeeded: true)
            let frame = BrowserColumnGeometry(parentID: parentID, frame: CGRect(x: x, y: 0, width: 298, height: 440))
            let target = state.consume(frames: [1: frame], viewportWidth: 720)
            XCTAssertEqual(target?.alignment, x == 298 ? nil : .trailing)
        }
    }

    func testLastColumnLeafSelectionCancelsRevealWithoutCreatingAnother() {
        for kind in [ScanNodeKind.file, .symbolicLink, .mountPoint, .other] {
            var state = BrowserColumnRevealState()
            let parentID = ScanNodeID()
            let earlierRequest = state.begin(parentID: parentID, kind: .directory, inColumn: 1, columnCount: 2)
            XCTAssertNil(state.begin(parentID: ScanNodeID(), kind: kind, inColumn: 1, columnCount: 2))
            state.complete(earlierRequest, succeeded: true)
            XCTAssertNil(state.pending)
        }
    }

    func testFullyVisibleColumnDoesNotScrollAndConsumesRequest() {
        assertReveal(x: 298, width: 298, alignment: nil)
        assertReveal(x: 422, width: 298, alignment: nil)
    }

    func testRightClippedColumnAlignsTrailingEdge() {
        assertReveal(x: 596, width: 298, alignment: .trailing)
        assertReveal(x: 894, width: 298, alignment: .trailing)
    }

    func testLeftClippedColumnAlignsLeadingEdge() {
        assertReveal(x: -90, width: 298, alignment: .leading)
    }

    func testOversizedColumnAlwaysPrefersLeadingEdge() {
        assertReveal(x: 596, width: 1088, alignment: .leading)
        assertReveal(x: -90, width: 1088, alignment: .leading)
        assertReveal(x: 0, width: 1088, alignment: nil)
    }

    func testViewportWidthColumnFitsExactly() {
        assertReveal(x: 0, width: 720, alignment: nil)
        assertReveal(x: 298, width: 720, alignment: .trailing)
    }

    func testWaitsForBothLoadCompletionAndMatchingLayout() {
        var state = BrowserColumnRevealState()
        let parentID = ScanNodeID()
        let request = state.begin(parentID: parentID, kind: .directory, inColumn: 1, columnCount: 2)
        let frames = frames(parentID: parentID)
        XCTAssertNil(state.consume(frames: frames, viewportWidth: 720))
        XCTAssertNotNil(state.pending)

        state.complete(request, succeeded: true)
        XCTAssertNil(state.consume(frames: [:], viewportWidth: 720))
        XCTAssertNil(state.consume(frames: self.frames(parentID: ScanNodeID()), viewportWidth: 720))
        XCTAssertNil(state.consume(frames: frames, viewportWidth: 0))
        XCTAssertNotNil(state.pending)
        XCTAssertEqual(state.consume(frames: frames, viewportWidth: 720)?.alignment, .trailing)
        XCTAssertNil(state.pending)
    }

    func testManualScrollDuringLoadCancelsRevealButNextClickCanReveal() {
        var state = BrowserColumnRevealState()
        let parentID = ScanNodeID()
        let request = state.begin(parentID: parentID, kind: .directory, inColumn: 1, columnCount: 2)
        state.cancel()
        state.complete(request, succeeded: true)
        XCTAssertNil(state.consume(frames: frames(parentID: parentID), viewportWidth: 720))

        let next = state.begin(parentID: parentID, kind: .directory, inColumn: 1, columnCount: 2)
        state.complete(next, succeeded: true)
        XCTAssertNotNil(state.consume(frames: frames(parentID: parentID), viewportWidth: 720))
    }

    func testManualScrollAfterLoadButBeforeLayoutCancelsReveal() {
        var state = BrowserColumnRevealState()
        let parentID = ScanNodeID()
        let request = state.begin(parentID: parentID, kind: .directory, inColumn: 1, columnCount: 2)
        state.complete(request, succeeded: true)
        state.cancel()
        XCTAssertNil(state.consume(frames: frames(parentID: parentID), viewportWidth: 720))
    }

    func testRapidSelectionIgnoresEarlierCompletionEvenForSameDirectory() {
        var state = BrowserColumnRevealState()
        let parentID = ScanNodeID()
        let first = state.begin(parentID: parentID, kind: .directory, inColumn: 1, columnCount: 2)
        let second = state.begin(parentID: parentID, kind: .directory, inColumn: 1, columnCount: 2)
        state.complete(first, succeeded: true)
        XCTAssertFalse(state.pending?.isReady ?? true)
        XCTAssertEqual(state.pending?.id, second)
        state.complete(second, succeeded: true)
        XCTAssertNotNil(state.consume(frames: frames(parentID: parentID), viewportWidth: 720))
    }

    func testFailedLoadDoesNotReveal() {
        var state = BrowserColumnRevealState()
        let parentID = ScanNodeID()
        let request = state.begin(parentID: parentID, kind: .directory, inColumn: 1, columnCount: 2)
        state.complete(request, succeeded: false)
        XCTAssertNil(state.pending)
        XCTAssertNil(state.consume(frames: frames(parentID: parentID), viewportWidth: 720))
    }

    func testRefreshPaginationAndResizingCannotRepeatConsumedReveal() {
        var state = BrowserColumnRevealState()
        let parentID = ScanNodeID()
        let request = state.begin(parentID: parentID, kind: .directory, inColumn: 1, columnCount: 2)
        state.complete(request, succeeded: true)
        XCTAssertNotNil(state.consume(frames: frames(parentID: parentID), viewportWidth: 720))
        for width in [720.0, 900.0, 600.0] {
            XCTAssertNil(state.consume(frames: frames(parentID: parentID), viewportWidth: width))
        }
    }

    private func assertReveal(
        x: CGFloat, width: CGFloat, alignment: BrowserColumnRevealState.Alignment?,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        var state = BrowserColumnRevealState()
        let parentID = ScanNodeID()
        let request = state.begin(parentID: parentID, kind: .directory, inColumn: 1, columnCount: 2)
        state.complete(request, succeeded: true)
        let frames = [2: BrowserColumnGeometry(parentID: parentID, frame: CGRect(x: x, y: 0, width: width, height: 440))]
        let target = state.consume(frames: frames, viewportWidth: 720)
        XCTAssertEqual(target?.alignment, alignment, file: file, line: line)
        if alignment != nil { XCTAssertEqual(target?.columnIndex, 2, file: file, line: line) }
        XCTAssertNil(state.pending, file: file, line: line)
    }

    private func frames(parentID: ScanNodeID) -> [Int: BrowserColumnGeometry] {
        [2: BrowserColumnGeometry(parentID: parentID, frame: CGRect(x: 596, y: 0, width: 298, height: 440))]
    }
}

@MainActor
final class BrowserHorizontalScrollInputTests: XCTestCase {
    func testClickingEarlierColumnKeepsHostedScrollOffsetWhenBranchShrinks() async throws {
        let enhancedUI = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previousAccessibility = NSApp.accessibilityAttributeValue(enhancedUI)
        NSApp.accessibilitySetValue(true, forAttribute: enhancedUI)
        defer { NSApp.accessibilitySetValue(previousAccessibility, forAttribute: enhancedUI) }
        let source = ScanSource(kind: .folder, rootURL: URL(fileURLWithPath: "/fixture"))
        let chain = (0..<6).map { index in
            ScanNodeSummary(parentID: nil, url: source.rootURL.appending(path: "level-\(index)"),
                            kind: .directory, allocatedSize: 100)
        }
        let sibling = ScanNodeSummary(parentID: nil, url: source.rootURL.appending(path: "alternate"),
                                      kind: .directory, allocatedSize: 50)
        let file = ScanNodeSummary(parentID: nil, url: source.rootURL.appending(path: "leaf"),
                                   kind: .file, allocatedSize: 10)
        var columns: [ScanNodeID?: SnapshotBrowserColumn] = [nil: SnapshotBrowserColumn(parent: nil, nodes: [chain[0]])]
        for index in chain.indices {
            let nodes = index + 1 < chain.count ? [chain[index + 1]] : []
            columns[chain[index].id] = SnapshotBrowserColumn(parent: chain[index], nodes: nodes + (index == 2 ? [sibling, file] : []))
        }
        let model = ResultBrowserModel(source: source, columnLoader: NavigationColumnLoader(columns: columns))
        await model.loadInitialColumn()
        for index in chain.indices { await model.select(chain[index], inColumn: index) }
        let hostingView = NSHostingView(rootView: ResultWindowView(model: model, onRequestFullRescan: {}, onCancelScan: {}))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 720, height: 440),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        window.orderFront(nil)
        defer {
            window.contentView = nil
            window.close()
        }
        try await settleLayout(hostingView)
        let scrollView = try XCTUnwrap(findInput(in: hostingView)?.enclosingScrollView)
        // Column 3 is visible, but keeping this offset requires blank space after
        // selecting its leaf (four remaining columns are narrower than the viewport end).
        scrollView.contentView.scroll(to: CGPoint(x: 700, y: 0))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        try await settleLayout(hostingView)
        let originalOffset = scrollView.contentView.bounds.minX
        XCTAssertGreaterThan(originalOffset, 600)

        let directoryButton = try XCTUnwrap(findButton(label: sibling.name, in: hostingView))
        XCTAssertEqual(directoryButton.accessibilityPerformPress?(), true)
        try await settleLayout(hostingView)
        XCTAssertEqual(model.columns.count, 5)
        XCTAssertEqual(model.columns.last?.parent?.id, sibling.id)
        XCTAssertEqual(scrollView.contentView.bounds.minX, originalOffset, accuracy: 1)

        let repeatedButton = try XCTUnwrap(findButton(label: sibling.name, in: hostingView))
        XCTAssertEqual(repeatedButton.accessibilityPerformPress?(), true)
        try await settleLayout(hostingView)
        XCTAssertEqual(scrollView.contentView.bounds.minX, originalOffset, accuracy: 1)

        let fileButton = try XCTUnwrap(findButton(label: file.name, in: hostingView))
        XCTAssertEqual(fileButton.accessibilityPerformPress?(), true)
        try await settleLayout(hostingView)
        XCTAssertEqual(model.columns.count, 4)
        XCTAssertEqual(scrollView.contentView.bounds.minX, originalOffset, accuracy: 1)

        for index in 3..<6 {
            let button = try XCTUnwrap(findButton(label: chain[index].name, in: hostingView))
            XCTAssertEqual(button.accessibilityPerformPress?(), true)
            try await settleLayout(hostingView)
            if index < 5 {
                XCTAssertEqual(scrollView.contentView.bounds.minX, originalOffset, accuracy: 1)
            }
        }
        // Only the last expansion is clipped; reveal its trailing edge once.
        XCTAssertEqual(scrollView.contentView.bounds.minX, 7 * 228 - 720, accuracy: 1)
        await model.loadInitialColumn(resetNavigation: true)
        try await settleLayout(hostingView)
        XCTAssertEqual(model.columns.count, 1)
        let resetScrollView = try XCTUnwrap(findInput(in: hostingView)?.enclosingScrollView)
        XCTAssertEqual(resetScrollView.contentView.bounds.minX, 0, accuracy: 1)
        XCTAssertEqual(resetScrollView.documentView?.frame.width ?? 0, 720, accuracy: 1)
    }

    private func settleLayout(_ view: NSView) async throws {
        for _ in 0..<20 {
            view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func findButton(label: String, in element: Any) -> AnyObject? {
        // SwiftUI's lazy nodes expose selectors without conforming to the
        // complete AppKit accessibility protocol.
        let element = element as AnyObject
        if element.accessibilityRole?() == .button, element.accessibilityLabel?() == label { return element }
        for child in element.accessibilityChildren?() ?? [] {
            if let button = findButton(label: label, in: child) { return button }
        }
        // NSViewRepresentable hosts a separate native accessibility subtree.
        if let view = element as? NSView {
            for child in view.subviews {
                if let button = findButton(label: label, in: child) { return button }
            }
        }
        return nil
    }

    func testInputMonitorIsMountedInsideOuterHorizontalScrollView() async throws {
        let source = ScanSource(kind: .folder, rootURL: URL(fileURLWithPath: "/fixture"))
        let model = ResultBrowserModel(source: source, columnLoader: EmptyColumnLoader())
        await model.loadInitialColumn()
        let hostingView = NSHostingView(rootView: ResultWindowView(
            model: model, onRequestFullRescan: {}, onCancelScan: {}
        ))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 720, height: 440),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        defer {
            window.contentView = nil
            window.close()
        }

        var input: BrowserHorizontalScrollInput.InputView?
        for _ in 0..<100 {
            hostingView.layoutSubtreeIfNeeded()
            input = findInput(in: hostingView)
            if input?.enclosingScrollView != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let scrollView = try XCTUnwrap(input?.enclosingScrollView)
        XCTAssertTrue(scrollView.hasHorizontalScroller)
        XCTAssertFalse(scrollView.hasVerticalScroller)
    }

    func testOnlyHorizontalScrollerInputCancelsPendingReveal() throws {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 720, height: 440),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let scrollView = NSScrollView(frame: CGRect(x: 0, y: 0, width: 720, height: 440))
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .legacy
        scrollView.autohidesScrollers = false
        let document = NSView(frame: CGRect(x: 0, y: 0, width: 1800, height: 900))
        let input = BrowserHorizontalScrollInput.InputView()
        document.addSubview(input)
        scrollView.documentView = document
        window.contentView = scrollView
        scrollView.tile()
        var cancellations = 0
        input.onManualScroll = { cancellations += 1 }

        func click(_ view: NSView) throws {
            let location = view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: .leftMouseDown, location: location, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            ))
            // Exercise the monitor's handler without posting input to the desktop.
            input.handleInput(event)
        }

        try click(scrollView.contentView)
        try click(XCTUnwrap(scrollView.verticalScroller))
        XCTAssertEqual(cancellations, 0)
        try click(XCTUnwrap(scrollView.horizontalScroller))
        XCTAssertEqual(cancellations, 1)
        input.stopMonitoring()
        try click(XCTUnwrap(scrollView.horizontalScroller))
        XCTAssertEqual(cancellations, 1)
    }

    private func findInput(in view: NSView) -> BrowserHorizontalScrollInput.InputView? {
        if let input = view as? BrowserHorizontalScrollInput.InputView { return input }
        for subview in view.subviews {
            if let input = findInput(in: subview) { return input }
        }
        return nil
    }
}

private struct EmptyColumnLoader: SnapshotColumnLoading {
    func loadColumn(for source: ScanSource, parent: ScanNodeSummary?, offset: Int, limit: Int) async throws -> SnapshotBrowserColumn {
        SnapshotBrowserColumn(parent: parent, nodes: [])
    }
}

private struct NavigationColumnLoader: SnapshotColumnLoading {
    let columns: [ScanNodeID?: SnapshotBrowserColumn]

    func loadColumn(for source: ScanSource, parent: ScanNodeSummary?, offset: Int, limit: Int) async throws -> SnapshotBrowserColumn {
        columns[parent?.id] ?? SnapshotBrowserColumn(parent: parent, nodes: [])
    }
}
