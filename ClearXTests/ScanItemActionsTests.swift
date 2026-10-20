import AppKit
import SwiftUI
import XCTest
@testable import ClearX

@MainActor
final class ScanItemActionsTests: XCTestCase {
    func testCopiesPlainAbsolutePathWithoutCheckingExistence() async {
        let url = URL(fileURLWithPath: "/missing/中文 folder/a 'quoted' #file")
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let actions = ScanItemActions(copyPath: { url in
            ScanItemActions.writePath(url, to: pasteboard)
        }, revealInFinder: { _ in XCTFail("Copy must not open Finder") }, itemExists: { _ in
            XCTFail("Copy must not access the filesystem")
            return false
        })
        let failure = await actions.perform(.copyPath, at: url)
        XCTAssertNil(failure)
        XCTAssertEqual(pasteboard.string(forType: .string), url.path)
        XCTAssertTrue(pasteboard.types?.contains(.string) == true)
        XCTAssertFalse(pasteboard.types?.contains(.fileURL) == true)
    }

    func testClipboardFailureIsReported() async {
        let url = URL(fileURLWithPath: "/missing")
        let failure = await ScanItemActions(copyPath: { _ in false }).perform(.copyPath, at: url)
        XCTAssertEqual(failure, .clipboardUnavailable(url))
    }

    func testRevealChecksOffMainThreadAndKeepsOriginalURL() async {
        let url = URL(fileURLWithPath: "/fixture/item")
        var revealed: [URL] = []
        let actions = ScanItemActions(revealInFinder: { revealed.append($0) }, itemExists: { checked in
            XCTAssertFalse(Thread.isMainThread)
            XCTAssertEqual(checked, url)
            return true
        })
        let failure = await actions.perform(.revealInFinder, at: url)
        XCTAssertNil(failure)
        XCTAssertEqual(revealed, [url])
    }

    func testUnavailableItemDoesNotRevealParentOrAnyOtherURL() async {
        let url = URL(fileURLWithPath: "/unmounted/item")
        let actions = ScanItemActions(revealInFinder: { _ in XCTFail("No fallback allowed") },
                                      itemExists: { _ in false })
        let failure = await actions.perform(.revealInFinder, at: url)
        XCTAssertEqual(failure, .unavailable(url))
        XCTAssertEqual(failure?.message, "项目已不存在或当前无法访问。")
    }

    func testExistingFilesDirectoriesPackagesAndDanglingLinksUseOwnURL() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "file")
        try Data().write(to: file)
        let package = root.appending(path: "Example.app", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: false)
        let link = root.appending(path: "link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        var revealed: [URL] = []
        let actions = ScanItemActions(revealInFinder: { revealed.append($0) })
        for url in [file, root, package, link] {
            let failure = await actions.perform(.revealInFinder, at: url)
            XCTAssertNil(failure)
        }
        try FileManager.default.removeItem(at: file)
        let linkFailure = await actions.perform(.revealInFinder, at: link)
        XCTAssertNil(linkFailure, "A dangling link still has a revealable directory entry")
        XCTAssertEqual(revealed, [file, root, package, link, link])
        let removedFailure = await actions.perform(.revealInFinder, at: file)
        XCTAssertEqual(removedFailure, .unavailable(file))
        XCTAssertEqual(revealed.count, 5)
    }

    func testNonFileURLsAreRejectedBeforeSystemActions() async throws {
        let actions = ScanItemActions(copyPath: { _ in XCTFail(); return true },
                                      revealInFinder: { _ in XCTFail() },
                                      itemExists: { _ in XCTFail(); return true })
        let url = try XCTUnwrap(URL(string: "https://example.com/file"))
        for action in ScanItemAction.allCases {
            let failure = await actions.perform(action, at: url)
            XCTAssertEqual(failure, .unavailable(url))
        }
    }
}

@MainActor
final class ScanNodeContextMenuTests: XCTestCase {
    func testMenuFreezesTargetAndRestoresHighlightWithoutSelecting() throws {
        let original = node("original", kind: .directory)
        var highlights: [ScanNodeID?] = []
        var performed: [(ScanItemAction, URL)] = []
        let session = ScanNodeMenuSession(node: original, onTrackingChange: { highlights.append($0) },
                                          onAction: { performed.append(($0, $1)) })
        session.beginTracking()
        session.endTracking()
        // AppKit may dispatch the chosen action after tracking ends.
        session.menu.performActionForItem(at: 0)
        session.menu.performActionForItem(at: 1)
        XCTAssertEqual(highlights, [original.id, nil])
        XCTAssertEqual(performed.map(\.0), [.copyPath, .revealInFinder])
        XCTAssertEqual(performed.map(\.1), [original.url, original.url])
    }

    func testAllNodeKindsHaveExactlyTwoEnabledActionsWithoutShortcuts() {
        for kind in [ScanNodeKind.directory, .file, .symbolicLink, .mountPoint, .other] {
            let session = ScanNodeMenuSession(node: node("item", kind: kind),
                                              onTrackingChange: { _ in }, onAction: { _, _ in })
            XCTAssertEqual(session.menu.items.map(\.title), ["拷贝路径", "在 Finder 中显示"])
            XCTAssertTrue(session.menu.items.allSatisfy(\.isEnabled))
            XCTAssertTrue(session.menu.items.allSatisfy { $0.keyEquivalent.isEmpty })
        }
    }

    func testBatchMenuOnlyOffersTrashAndStartsDisabled() {
        let first = node("first", kind: .file)
        let second = node("second", kind: .directory)
        let session = ScanNodeMenuSession(node: first, onTrackingChange: { _ in }, onAction: { _, _ in },
                                          trashNodes: [first, second], root: URL(fileURLWithPath: "/fixture"), onTrash: { _ in })
        XCTAssertEqual(session.menu.items.count, 1)
        XCTAssertTrue(session.menu.items[0].title.hasPrefix("移到废纸篓"))
        XCTAssertFalse(session.menu.items[0].isEnabled)
    }

    func testTrashValidationCompletesWhileNativeMenuIsTracking() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("owned")
        try Data("test".utf8).write(to: url)
        let item = ScanNodeSummary(parentID: nil, url: url, kind: .file, allocatedSize: 4)
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 100))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        let session = ScanNodeMenuSession(node: item, onTrackingChange: { _ in }, onAction: { _, _ in },
                                          trashNodes: [item], root: directory, onTrash: { _ in XCTFail("No file operations in menu test") })
        let timer = Timer(timeInterval: 0.7, repeats: false) { _ in
            MainActor.assumeIsolated {
                XCTAssertEqual(session.menu.items.count, 3)
                XCTAssertTrue(session.menu.items[2].isEnabled, session.menu.items[2].title)
                session.menu.cancelTracking()
            }
        }
        RunLoop.main.add(timer, forMode: .eventTracking)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: NSPoint(x: 20, y: 20),
                                                    modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        session.beginTracking()
        NSMenu.popUpContextMenu(session.menu, with: event, for: view)
        session.endTracking()
        timer.invalidate()
    }

    func testHostedMenuPreservesNavigationAcrossScanStatesAndReordering() async throws {
        let first = node("first", kind: .directory)
        let second = node("second", kind: .directory)
        let child = node("child", kind: .file)
        let source = ScanSource(kind: .folder, rootURL: URL(fileURLWithPath: "/fixture"))
        let loader = ContextMenuColumnLoader(first: first, second: second, child: child)
        let model = ResultBrowserModel(source: source, columnLoader: loader)
        await model.loadInitialColumn()
        await model.select(first, inColumn: 0)
        let hosting = NSHostingView(rootView: ResultWindowView(model: model, onRequestFullRescan: {}, onCancelScan: {}))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 720, height: 440),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        for _ in 0..<20 {
            hosting.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        let table = try XCTUnwrap(findTable(second.id, in: hosting))
        func rowView(_ node: ScanNodeSummary) throws -> NSView {
            let row = try XCTUnwrap(table.nodes.firstIndex { $0.id == node.id })
            return try XCTUnwrap(table.view(atColumn: 0, row: row, makeIfNecessary: true))
        }
        let selectedBackground = try backgroundColor(of: rowView(first), in: hosting)
        let unselectedBackground = try backgroundColor(of: rowView(second), in: hosting)
        XCTAssertGreaterThan(abs(selectedBackground.redComponent - unselectedBackground.redComponent)
                             + abs(selectedBackground.greenComponent - unselectedBackground.greenComponent)
                             + abs(selectedBackground.blueComponent - unselectedBackground.blueComponent), 0.1)
        for contextNode in [second, first] {
          for (type, flags) in [(NSEvent.EventType.rightMouseDown, NSEvent.ModifierFlags()),
                                (.leftMouseDown, .control)] {
            let contextView = try rowView(contextNode)
            let point = contextView.convert(CGPoint(x: contextView.bounds.midX, y: contextView.bounds.midY), to: nil)
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags,
                                                        timestamp: ProcessInfo.processInfo.systemUptime,
                                                        windowNumber: window.windowNumber, context: nil,
                                                        eventNumber: 0, clickCount: 1, pressure: 1))
            var opened = false
            let timer = Timer(timeInterval: 0.1, repeats: false) { _ in
                MainActor.assumeIsolated {
                    opened = table.activeSession != nil
                    XCTAssertEqual(table.activeSession?.nodeID, contextNode.id)
                    XCTAssertEqual(model.selectedNodeIDs, [first.id])
                    do {
                        try self.assertBackground(of: rowView(first), in: hosting, equals: selectedBackground)
                        try self.assertBackground(of: rowView(contextNode), in: hosting, equals: selectedBackground)
                        if contextNode.id == first.id {
                            try self.assertBackground(of: rowView(second), in: hosting, equals: unselectedBackground)
                        }
                    } catch { XCTFail("Cannot render contextual highlight: \(error)") }
                    table.activeSession?.menu.cancelTracking()
                }
            }
            RunLoop.main.add(timer, forMode: .eventTracking)
            // nextEvent establishes NSApp.currentEvent, as in the real event
            // loop; calling sendEvent alone does not establish hit-test context.
            NSApp.postEvent(event, atStart: true)
            let mask: NSEvent.EventTypeMask = type == .rightMouseDown ? .rightMouseDown : .leftMouseDown
            let queued = try XCTUnwrap(NSApp.nextEvent(matching: mask, until: Date(timeIntervalSinceNow: 1),
                                                       inMode: .default, dequeue: true))
            NSApp.sendEvent(queued)
            timer.invalidate()
            XCTAssertTrue(opened, "Context click must reach the native menu")
            XCTAssertNil(table.activeSession)
            try await settleLayout(hosting)
            try assertBackground(of: rowView(first), in: hosting, equals: selectedBackground)
            try assertBackground(of: rowView(second), in: hosting, equals: unselectedBackground)
            XCTAssertEqual(model.selectedNodeIDs, [first.id])
          }

          for actionIndex in ScanItemAction.allCases.indices {
            // Capture injected actions before tracking changes redraw the row;
            // never modify the user's clipboard or open Finder in this test.
            var performed: [(ScanItemAction, URL)] = []
            table.input?.onAction = { performed.append(($0, $1)) }
            let session = try XCTUnwrap(table.makeMenuSession(for: contextNode))
            session.beginTracking()
            try await settleLayout(hosting)
            try assertBackground(of: rowView(first), in: hosting, equals: selectedBackground)
            try assertBackground(of: rowView(contextNode), in: hosting, equals: selectedBackground)
            session.endTracking()
            session.menu.performActionForItem(at: actionIndex)
            try await settleLayout(hosting)
            XCTAssertEqual(performed.map(\.0), [ScanItemAction.allCases[actionIndex]])
            XCTAssertEqual(performed.map(\.1), [session.url])
            try assertBackground(of: rowView(first), in: hosting, equals: selectedBackground)
            try assertBackground(of: rowView(second), in: hosting, equals: unselectedBackground)
            XCTAssertEqual(model.selectedNodeIDs, [first.id])
            XCTAssertEqual(model.columns[1].parent?.id, first.id)
          }
        }
        let progress = ScanProgress(discoveredNodeCount: 3, completedDirectoryCount: 0, currentURL: nil)
        for state in [ScanPresentationState.idle, .scanning(progress), .cancelled,
                      .synchronizationFailed("test"), .incomplete(.permissionRestricted), .completed(.complete)] {
            model.updatePresentationState(state, displayingPreviousResult: true)
            try await settleLayout(hosting)
            let session = try XCTUnwrap(table.makeMenuSession(for: second))
            XCTAssertEqual(session.menu.items.count, model.isScanning ? 2 : 3)
            session.beginTracking()
            await loader.reverseOrder()
            await model.refreshAllColumns()
            XCTAssertEqual(session.nodeID, second.id)
            XCTAssertEqual(session.url, second.url)
            XCTAssertEqual(model.selectedNodeIDs, [first.id])
            XCTAssertEqual(model.columns.count, 2)
            XCTAssertEqual(model.columns[1].parent?.id, first.id)
            XCTAssertEqual(model.columns[1].nodes.map(\.id), [child.id])
            session.endTracking()
            XCTAssertEqual(model.selectedNodeIDs, [first.id])
        }

        var startedRescan = false
        var neededFallback = false
        let startRescan = Timer(timeInterval: 0.1, repeats: false) { _ in
            MainActor.assumeIsolated {
                XCTAssertNotNil(table.activeSession)
                startedRescan = true
                model.updatePresentationState(.scanning(progress), displayingPreviousResult: true)
            }
        }
        let fallback = Timer(timeInterval: 2, repeats: false) { _ in
            MainActor.assumeIsolated {
                neededFallback = true
                table.activeSession?.menu.cancelTracking()
            }
        }
        RunLoop.main.add(startRescan, forMode: .eventTracking)
        RunLoop.main.add(fallback, forMode: .eventTracking)
        defer { startRescan.invalidate(); fallback.invalidate() }
        let view = try rowView(second)
        let point = view.convert(CGPoint(x: 20, y: view.bounds.midY), to: nil)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [],
                                                    timestamp: ProcessInfo.processInfo.systemUptime,
                                                    windowNumber: window.windowNumber, context: nil,
                                                    eventNumber: 0, clickCount: 1, pressure: 1))
        table.rightMouseDown(with: event)
        XCTAssertTrue(startedRescan)
        XCTAssertFalse(neededFallback, "SwiftUI must propagate the rescan state during native menu tracking")
        XCTAssertNil(table.activeSession)
        try await settleLayout(hosting)
        try assertBackground(of: rowView(first), in: hosting, equals: selectedBackground)
        try assertBackground(of: rowView(second), in: hosting, equals: unselectedBackground)
        XCTAssertEqual(model.selectedNodeIDs, [first.id])
    }

    private func settleLayout(_ hosting: NSView) async throws {
        for _ in 0..<10 {
            hosting.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func assertBackground(of input: NSView, in hosting: NSView, equals expected: NSColor,
                                  file: StaticString = #filePath, line: UInt = #line) throws {
        let color = try backgroundColor(of: input, in: hosting)
        XCTAssertEqual(color.redComponent, expected.redComponent, accuracy: 0.02, file: file, line: line)
        XCTAssertEqual(color.greenComponent, expected.greenComponent, accuracy: 0.02, file: file, line: line)
        XCTAssertEqual(color.blueComponent, expected.blueComponent, accuracy: 0.02, file: file, line: line)
    }

    private func backgroundColor(of input: NSView, in hosting: NSView) throws -> NSColor {
        hosting.layoutSubtreeIfNeeded()
        let rect = hosting.convert(input.bounds, from: input)
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: rect))
        hosting.cacheDisplay(in: rect, to: bitmap)
        return try XCTUnwrap(bitmap.colorAt(x: 1, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
    }

    private func findTable(_ id: ScanNodeID, in view: NSView) -> BrowserSelectionTable.SelectionTable? {
        if let input = view as? BrowserSelectionTable.SelectionTable, input.nodes.contains(where: { $0.id == id }) { return input }
        for child in view.subviews {
            if let input = findTable(id, in: child) { return input }
        }
        return nil
    }

    private func node(_ name: String, kind: ScanNodeKind) -> ScanNodeSummary {
        ScanNodeSummary(parentID: nil, url: URL(fileURLWithPath: "/fixture/" + name),
                        kind: kind, allocatedSize: 0)
    }
}

private actor ContextMenuColumnLoader: SnapshotColumnLoading {
    let first: ScanNodeSummary
    let second: ScanNodeSummary
    let child: ScanNodeSummary
    var reversed = false

    init(first: ScanNodeSummary, second: ScanNodeSummary, child: ScanNodeSummary) {
        self.first = first
        self.second = second
        self.child = child
    }

    func reverseOrder() { reversed.toggle() }

    func loadColumn(for source: ScanSource, parent: ScanNodeSummary?, offset: Int, limit: Int) async throws -> SnapshotBrowserColumn {
        SnapshotBrowserColumn(parent: parent, nodes: parent == nil ? (reversed ? [second, first] : [first, second]) : [child])
    }
}
