import AppKit
import SwiftUI

/// Native scrolling and row virtualization, with selection independent of navigation.
struct BrowserSelectionTable: NSViewRepresentable {
    let column: SnapshotBrowserColumn
    let highlightedIDs: Set<ScanNodeID>
    let root: URL
    var isScanning = false
    let targets: (ScanNodeSummary) -> [ScanNodeSummary]
    let onBegin: () -> Void
    let onSelection: (Set<ScanNodeID>) -> Void
    let onFinish: () -> Void
    let onPlainClick: (ScanNodeSummary) -> Void
    var onAction: (ScanItemAction, URL) -> Void
    let onTrash: ([ScanNodeSummary]) -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let table = SelectionTable()
        table.headerView = nil
        table.rowHeight = 22
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .none
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("entry"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = table
        table.delegate = table
        scroll.documentView = table
        updateNSView(scroll, context: context)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let table = scroll.documentView as? SelectionTable else { return }
        table.updateInput(self)
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: ()) {
        (scroll.documentView as? SelectionTable)?.activeSession?.menu.cancelTracking()
    }

    final class SelectionTable: NSTableView, NSTableViewDataSource, NSTableViewDelegate {
        var input: BrowserSelectionTable?
        var nodes: [ScanNodeSummary] = []
        private var contextID: ScanNodeID?
        private(set) var activeSession: ScanNodeMenuSession?
        private var updating = false
        private(set) var isTrackingSelection = false
        private var trackingIDs: Set<ScanNodeID>?

        func updateInput(_ newInput: BrowserSelectionTable) {
            let scanStarted = input?.isScanning == false && newInput.isScanning
            input = newInput
            if scanStarted { activeSession?.menu.cancelTracking() }
            // SwiftUI may deliver scan progress during AppKit's tracking loop.
            if !isTrackingSelection { nodes = newInput.column.nodes }
            refreshRows()
        }

        func numberOfRows(in tableView: NSTableView) -> Int { nodes.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard nodes.indices.contains(row), let input else { return nil }
            let node = nodes[row]
            let rowView = ScanNodeRowView(node: node,
                                       isSelected: (trackingIDs ?? input.highlightedIDs).contains(node.id),
                                       isEstimating: input.column.estimatingNodeIDs.contains(node.id),
                                       isPending: input.column.pendingNodeIDs.contains(node.id),
                                       isContextHighlighted: contextID == node.id)
            let identifier = NSUserInterfaceItemIdentifier("row")
            let cell = (makeView(withIdentifier: identifier, owner: nil) as? SelectionCell) ?? SelectionCell(row: rowView)
            cell.identifier = identifier
            cell.host.rootView = rowView
            cell.onPress = { input.onPlainClick(node) }
            cell.setAccessibilityLabel(node.name)
            cell.setAccessibilitySelected(rowView.isSelected)
            cell.setAccessibilityValue(ScanNodeRowPresentation(node: node, isEstimating: rowView.isEstimating,
                                                              isPending: rowView.isPending).sizeDescription)
            var actions: [NSAccessibilityCustomAction] = []
            if input.targets(node).count == 1 {
                actions.append(NSAccessibilityCustomAction(name: "拷贝路径") { input.onAction(.copyPath, node.url); return true })
                actions.append(NSAccessibilityCustomAction(name: "在 Finder 中显示") { input.onAction(.revealInFinder, node.url); return true })
            }
            if !input.isScanning {
                actions.append(NSAccessibilityCustomAction(name: "移到废纸篓") { input.onTrash(input.targets(node)); return true })
            }
            cell.setAccessibilityCustomActions(actions)
            return cell
        }

        func refreshRows() {
            updating = true
            reloadData()
            let ids = trackingIDs ?? input?.highlightedIDs ?? []
            selectRowIndexes(IndexSet(nodes.indices.filter { ids.contains(nodes[$0].id) }), byExtendingSelection: false)
            updating = false
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updating, !isTrackingSelection, let input else { return }
            input.onBegin()
            input.onSelection(Set(selectedRowIndexes.compactMap { nodes.indices.contains($0) ? nodes[$0].id : nil }))
            input.onFinish()
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func hitTest(_ point: NSPoint) -> NSView? {
            let hit = super.hitTest(point)
            if let event = NSApp.currentEvent,
               event.type == .leftMouseDown || event.type == .rightMouseDown {
                return hit == nil ? nil : self
            }
            return hit
        }

        override func mouseDown(with event: NSEvent) {
            if event.modifierFlags.contains(.control) { rightMouseDown(with: event); return }
            let startPoint = convert(event.locationInWindow, from: nil)
            let start = row(at: startPoint)
            guard let input, let window else { return }
            window.makeFirstResponder(self)
            guard nodes.indices.contains(start) else {
                input.onBegin()
                input.onSelection([])
                input.onFinish()
                return
            }
            isTrackingSelection = true
            input.onBegin()
            let initial = input.highlightedIDs
            var dragged = false
            var plainClick = false
            var location = event.locationInWindow
            NSEvent.startPeriodicEvents(afterDelay: 0.15, withPeriod: 0.05)
            defer {
                NSEvent.stopPeriodicEvents()
                isTrackingSelection = false
                trackingIDs = nil
                if !plainClick { input.onFinish() }
            }
            while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp, .periodic]) {
                if next.type != .periodic { location = next.locationInWindow }
                let point = convert(location, from: nil)
                if next.type == .leftMouseDragged && hypot(location.x - event.locationInWindow.x,
                                                          location.y - event.locationInWindow.y) >= 3 { dragged = true }
                if dragged {
                    // Only loaded rows exist in this document; autoscroll cannot fetch pages.
                    if next.type != .periodic { _ = autoscroll(with: next) }
                    else if let scroll = enclosingScrollView {
                        let visible = visibleRect
                        let delta: CGFloat = point.y < visible.minY + 16 ? -14 : (point.y > visible.maxY - 16 ? 14 : 0)
                        if delta != 0 {
                            let y = min(max(0, visible.minY + delta), max(0, bounds.height - visible.height))
                            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
                            scroll.reflectScrolledClipView(scroll.contentView)
                        }
                    }
                    let current = convert(location, from: nil)
                    let end = min(nodes.count - 1, max(0, Int(floor(current.y / rowHeight))))
                    trackingIDs = Set(nodes[min(start, end)...max(start, end)].map(\.id))
                    input.onSelection(trackingIDs!)
                    refreshRows()
                }
                if next.type == .leftMouseUp {
                    if !dragged {
                        if !event.modifierFlags.contains(.command) {
                            plainClick = true
                            input.onPlainClick(nodes[start])
                            break
                        }
                        var ids: Set<ScanNodeID> = [nodes[start].id]
                        if event.modifierFlags.contains(.command) {
                            ids = initial
                            if ids.contains(nodes[start].id) { ids.remove(nodes[start].id) }
                            else { ids.insert(nodes[start].id) }
                        }
                        trackingIDs = ids
                        input.onSelection(ids)
                        refreshRows()
                    }
                    break
                }
            }
        }

        override func rightMouseDown(with event: NSEvent) {
            let row = row(at: convert(event.locationInWindow, from: nil))
            guard nodes.indices.contains(row) else { return }
            let node = nodes[row]
            guard let session = makeMenuSession(for: node) else { return }
            activeSession = session
            session.beginTracking()
            NSMenu.popUpContextMenu(session.menu, with: event, for: self)
            session.endTracking()
            activeSession = nil
        }

        func makeMenuSession(for node: ScanNodeSummary) -> ScanNodeMenuSession? {
            guard let input else { return nil }
            let session = ScanNodeMenuSession(node: node, onTrackingChange: { [weak self] id in
                self?.contextID = id
                self?.refreshRows()
            }, onAction: input.onAction, trashNodes: input.targets(node), root: input.root,
               onTrash: input.onTrash, showsTrash: !input.isScanning)
            return session.menu.items.isEmpty ? nil : session
        }
    }
}

private final class SelectionCell: NSTableCellView {
    let host: NSHostingView<ScanNodeRowView>
    var onPress: (() -> Void)?

    init(row: ScanNodeRowView) {
        host = NSHostingView(rootView: row)
        super.init(frame: .zero)
        host.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: leadingAnchor), host.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.topAnchor.constraint(equalTo: topAnchor), host.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityChildren([])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func accessibilityPerformPress() -> Bool { onPress?(); return onPress != nil }
}
