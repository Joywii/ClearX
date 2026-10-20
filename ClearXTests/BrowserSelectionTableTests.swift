import AppKit
import SwiftUI
import XCTest
@testable import ClearX

@MainActor
final class BrowserSelectionTableTests: XCTestCase {
    func testCommandClickAddsAndRemovesAndDragReplacesSelection() throws {
        let nodes = (0..<5).map {
            ScanNodeSummary(parentID: nil, url: URL(fileURLWithPath: "/fixture/\($0)"), kind: .file, allocatedSize: 0)
        }
        let table = BrowserSelectionTable.SelectionTable(frame: NSRect(x: 0, y: 0, width: 240, height: 200))
        table.rowHeight = 22
        table.intercellSpacing = .zero
        table.headerView = nil
        table.addTableColumn(NSTableColumn(identifier: .init("entry")))
        table.dataSource = table
        table.delegate = table
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.nodes = nodes
        let window = NSWindow(contentRect: table.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = table
        defer { window.contentView = nil; window.close() }
        var selection: Set<ScanNodeID> = []
        var finishes = 0
        func configure(_ initial: Set<ScanNodeID>) {
            table.input = BrowserSelectionTable(column: SnapshotBrowserColumn(parent: nil, nodes: nodes),
                                                highlightedIDs: initial, root: URL(fileURLWithPath: "/fixture"),
                                                targets: { [$0] }, onBegin: {}, onSelection: { selection = $0 },
                                                onFinish: { finishes += 1 }, onPlainClick: { selection = [$0.id] },
                                                onAction: { _, _ in }, onTrash: { _ in })
            table.refreshRows()
        }
        func event(_ type: NSEvent.EventType, row: Int, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
            let point = table.convert(NSPoint(x: 30, y: CGFloat(row) * 22 + 11), to: nil)
            return try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags,
                                                   timestamp: ProcessInfo.processInfo.systemUptime,
                                                   windowNumber: window.windowNumber, context: nil,
                                                   eventNumber: 0, clickCount: 1, pressure: 1))
        }
        configure([nodes[0].id])
        NSApp.postEvent(try event(.leftMouseUp, row: 2, flags: .command), atStart: true)
        table.mouseDown(with: try event(.leftMouseDown, row: 2, flags: .command))
        XCTAssertEqual(selection, [nodes[0].id, nodes[2].id])
        configure(selection)
        NSApp.postEvent(try event(.leftMouseUp, row: 0, flags: .command), atStart: true)
        table.mouseDown(with: try event(.leftMouseDown, row: 0, flags: .command))
        XCTAssertEqual(selection, [nodes[2].id])
        configure(selection)
        NSApp.postEvent(try event(.leftMouseUp, row: 4), atStart: true)
        NSApp.postEvent(try event(.leftMouseDragged, row: 4), atStart: true)
        table.mouseDown(with: try event(.leftMouseDown, row: 1))
        XCTAssertEqual(selection, Set(nodes[1...4].map(\.id)))
        XCTAssertEqual(finishes, 3)
        configure(selection)
        NSApp.postEvent(try event(.leftMouseUp, row: 50), atStart: true)
        NSApp.postEvent(try event(.leftMouseDragged, row: 50), atStart: true)
        table.mouseDown(with: try event(.leftMouseDown, row: 1))
        XCTAssertEqual(selection, Set(nodes[1...4].map(\.id)), "Dragging beyond loaded rows must clamp to the loaded prefix")
        // A right-click below the final loaded row never opens a menu.
        table.rightMouseDown(with: try event(.rightMouseDown, row: 7))
        XCTAssertNil(table.activeSession)
        XCTAssertEqual(selection, Set(nodes[1...4].map(\.id)))
        table.mouseDown(with: try event(.leftMouseDown, row: 7, flags: .control))
        XCTAssertNil(table.activeSession)
        XCTAssertEqual(selection, Set(nodes[1...4].map(\.id)))
        table.mouseDown(with: try event(.leftMouseDown, row: 7))
        XCTAssertTrue(selection.isEmpty)
        XCTAssertEqual(finishes, 5)
    }

    func testScanningMenusFreezeContentsAndRescanClosesTrackingMenu() throws {
        let nodes = ["a", "b"].map {
            ScanNodeSummary(parentID: nil, url: URL(fileURLWithPath: "/fixture/\($0)"), kind: .file, allocatedSize: 0)
        }
        let table = BrowserSelectionTable.SelectionTable(frame: NSRect(x: 0, y: 0, width: 240, height: 200))
        table.headerView = nil
        table.rowHeight = 22
        table.intercellSpacing = .zero
        table.addTableColumn(NSTableColumn(identifier: .init("entry")))
        table.dataSource = table
        table.delegate = table
        table.allowsEmptySelection = true
        table.allowsMultipleSelection = true
        let window = NSWindow(contentRect: table.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = table
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        func configure(scanning: Bool, multiple: Bool = false) {
            table.updateInput(BrowserSelectionTable(
                column: SnapshotBrowserColumn(parent: nil, nodes: nodes), highlightedIDs: [nodes[0].id],
                root: URL(fileURLWithPath: "/fixture"), isScanning: scanning,
                targets: { multiple ? nodes : [$0] }, onBegin: {}, onSelection: { _ in XCTFail("Selection changed") },
                onFinish: {}, onPlainClick: { _ in XCTFail("Navigation changed") },
                onAction: { _, _ in }, onTrash: { _ in XCTFail("No file operations in menu test") }))
        }
        configure(scanning: true, multiple: true)
        XCTAssertNil(table.makeMenuSession(for: nodes[0]))
        configure(scanning: true)
        let scanningMenu = try XCTUnwrap(table.makeMenuSession(for: nodes[1]))
        XCTAssertEqual(scanningMenu.menu.items.map(\.title), ["拷贝路径", "在 Finder 中显示"])
        scanningMenu.beginTracking()
        configure(scanning: false)
        XCTAssertEqual(scanningMenu.menu.items.count, 2, "Scan completion must not add entries to an open menu")
        scanningMenu.endTracking()
        XCTAssertEqual(table.makeMenuSession(for: nodes[1])?.menu.items.count, 3)
        configure(scanning: false, multiple: true)
        XCTAssertEqual(table.makeMenuSession(for: nodes[0])?.menu.items.count, 1)
        configure(scanning: false)

        var didStartScan = false
        var neededFallback = false
        let startScan = Timer(timeInterval: 0.1, repeats: false) { _ in
            MainActor.assumeIsolated {
                XCTAssertNotNil(table.activeSession)
                didStartScan = true
                configure(scanning: true)
            }
        }
        let fallback = Timer(timeInterval: 1, repeats: false) { _ in
            MainActor.assumeIsolated {
                neededFallback = true
                table.activeSession?.menu.cancelTracking()
            }
        }
        RunLoop.main.add(startScan, forMode: .eventTracking)
        RunLoop.main.add(fallback, forMode: .eventTracking)
        defer { startScan.invalidate(); fallback.invalidate() }
        let point = table.convert(NSPoint(x: 30, y: 33), to: nil)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [],
                                                    timestamp: ProcessInfo.processInfo.systemUptime,
                                                    windowNumber: window.windowNumber, context: nil,
                                                    eventNumber: 0, clickCount: 1, pressure: 1))
        table.rightMouseDown(with: event)
        XCTAssertTrue(didStartScan)
        XCTAssertFalse(neededFallback, "Starting a rescan must close the menu immediately")
        XCTAssertNil(table.activeSession)
        XCTAssertEqual(table.selectedRowIndexes, IndexSet(integer: 0))
    }
}
