import AppKit
import SwiftUI

private enum BrowserCoordinateSpace: Hashable {
    case viewport
}

struct ResultWindowView: View {
    @ObservedObject var model: ResultBrowserModel
    let onRequestFullRescan: () -> Void
    let onCancelScan: () -> Void
    @State private var columnWidths = BrowserColumnWidthState()
    @State private var columnReveal = BrowserColumnRevealState()
    @State private var viewportRetention = BrowserViewportRetention()
    @State private var columnFrames: [Int: BrowserColumnGeometry] = [:]
    @State private var showsSizeSummary = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let notice = model.scanNotice {
                Label(notice, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .padding(10)
                Divider()
            }
            browser
        }
            .navigationTitle(model.source.displayName)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("大小统计", systemImage: "info.circle") { showsSizeSummary = true }
                        .popover(isPresented: $showsSizeSummary) { sizeSummaryView }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("重新完整扫描", systemImage: "arrow.clockwise", action: onRequestFullRescan)
                        .disabled(isScanning)
                }
                if isScanning {
                    ToolbarItem(placement: .primaryAction) {
                        Button("取消扫描", systemImage: "xmark", action: onCancelScan)
                    }
                }
            }
    }

    private var sizeSummaryView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("大小统计").font(.headline)
            Text(model.sizeSummaryStatus).foregroundStyle(.secondary)
            if let summary = model.sizeSummary {
                LabeledContent("目录内容大小", value: summarySize(summary.contentAllocatedSize, summary: summary))
                LabeledContent("全扫描硬链接去重大小", value: summarySize(summary.uniqueAllocatedSize, summary: summary))
            }
            Text("列表按路径累计已分配大小，硬链接在每个路径计入。全扫描汇总对同一文件对象仅计一次。")
            Text("两者均不等于可释放空间；APFS 克隆及共享块不去重。")
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(16)
        .frame(width: 360)
    }

    private func summarySize(_ bytes: Int64, summary: ScanSizeSummary) -> String {
        ByteCountPresentation.string(for: bytes) + (summary.isIncomplete || summary.isScanning ? "+" : "")
    }

    private var browser: some View {
        Group {
            if model.columns.isEmpty {
                Color.clear
            } else {
                GeometryReader { viewport in
                    ScrollViewReader { scrollProxy in
                        ScrollView(.horizontal) {
                            HStack(alignment: .top, spacing: 0) {
                                ForEach(Array(model.columns.enumerated()), id: \.offset) { index, column in
                                    let width = columnWidths.width(for: index)
                                    HStack(spacing: 0) {
                                        BrowserColumnView(
                                            column: column,
                                            nodes: model.visibleNodes(inColumn: index),
                                            remainingNodeCount: model.remainingNodeCount(inColumn: index),
                                            selectedNodeID: selectedID(in: index),
                                            width: width,
                                            onSelect: { node in
                                                select(node, inColumn: index, viewportWidth: viewport.size.width)
                                            },
                                            onLoadMore: {
                                                Task { await model.loadMore(inColumn: index) }
                                            }
                                        )
                                        .id(column.parent?.id)
                                        BrowserColumnResizeHandle(
                                            columnIndex: index,
                                            width: width,
                                            onWidthChange: { updateColumnWidth($0, for: index) },
                                            onReset: { columnWidths.resetWidth(for: index) }
                                        )
                                    }
                                    .id(index)
                                    .background {
                                        GeometryReader { geometry in
                                            Color.clear.preference(key: BrowserColumnFramesKey.self, value: [
                                                index: BrowserColumnGeometry(
                                                    parentID: column.parent?.id,
                                                    frame: geometry.frame(in: .named(BrowserCoordinateSpace.viewport))
                                                )
                                            ])
                                        }
                                    }
                                }
                            }
                            .padding(.trailing, 4)
                            .frame(minWidth: max(viewport.size.width, viewportRetention.minimumContentWidth),
                                   minHeight: 360, alignment: .topLeading)
                            .background {
                                BrowserHorizontalScrollInput {
                                    if columnReveal.pending != nil { columnReveal.cancel() }
                                }
                            }
                        }
                        .coordinateSpace(name: BrowserCoordinateSpace.viewport)
                        .onPreferenceChange(BrowserColumnFramesKey.self) { frames in
                            columnFrames = frames
                            revealColumn(using: scrollProxy, viewportWidth: viewport.size.width)
                        }
                        .onChange(of: columnReveal) { _, _ in
                            revealColumn(using: scrollProxy, viewportWidth: viewport.size.width)
                        }
                    }
                }
            }
        }
        .frame(minWidth: 720, minHeight: 440)
        .onChange(of: model.selectedNodeIDs.isEmpty) { _, isEmpty in
            if isEmpty {
                columnReveal.cancel()
                viewportRetention.reset()
                columnFrames = [:]
            }
        }
        .onDisappear {
            columnReveal.cancel()
            viewportRetention.reset()
        }
    }

    private func select(_ node: ScanNodeSummary, inColumn index: Int, viewportWidth: CGFloat) {
        viewportRetention.capture(frames: columnFrames, viewportWidth: viewportWidth)
        let requestID = columnReveal.begin(
            parentID: node.id, kind: node.kind, inColumn: index, columnCount: model.columns.count
        )
        Task {
            await model.select(node, inColumn: index)
            if let requestID {
                let succeeded = model.columns.indices.contains(index + 1)
                    && model.columns[index + 1].parent?.id == node.id
                    && model.selectedNodeIDs.indices.contains(index)
                    && model.selectedNodeIDs[index] == node.id
                columnReveal.complete(requestID, succeeded: succeeded)
            }
        }
    }

    private func revealColumn(using proxy: ScrollViewProxy, viewportWidth: CGFloat) {
        guard let target = columnReveal.consume(frames: columnFrames, viewportWidth: viewportWidth) else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
            proxy.scrollTo(target.columnIndex, anchor: target.alignment == .leading ? .leading : .trailing)
        }
    }

    private var isScanning: Bool {
        if case .scanning = model.presentationState {
            return true
        }
        return false
    }

    private func selectedID(in columnIndex: Int) -> ScanNodeID? {
        guard model.selectedNodeIDs.indices.contains(columnIndex) else { return nil }
        return model.selectedNodeIDs[columnIndex]
    }

    private func updateColumnWidth(_ width: CGFloat, for index: Int) {
        let clampedWidth = BrowserColumnWidthState.clampedWidth(width)
        // Check before mutating @State, including repeated events at a width limit.
        guard columnWidths.width(for: index) != clampedWidth else { return }
        columnWidths.setWidth(clampedWidth, for: index)
    }
}

private struct BrowserColumnView: View {
    let column: SnapshotBrowserColumn
    let nodes: ArraySlice<ScanNodeSummary>
    let remainingNodeCount: Int
    let selectedNodeID: ScanNodeID?
    let width: CGFloat
    let onSelect: (ScanNodeSummary) -> Void
    let onLoadMore: () -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(nodes) { node in
                    Button {
                        onSelect(node)
                    } label: {
                        ScanNodeRowView(
                            node: node,
                            isSelected: node.id == selectedNodeID,
                            isEstimating: column.estimatingNodeIDs.contains(node.id),
                            isPending: column.pendingNodeIDs.contains(node.id)
                        )
                    }
                    .buttonStyle(.plain)
                }
                if column.showsEmptyFolder {
                    Text("空文件夹")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(10)
                }
                if remainingNodeCount > 0 {
                    Button("加载更多（剩余 \(remainingNodeCount) 项）", action: onLoadMore)
                        .buttonStyle(.plain)
                        .foregroundStyle(.tint)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, 2)
        }
        .frame(width: width)
        .accessibilityLabel(column.parent?.name ?? "根目录")
    }
}

struct BrowserColumnWidthState {
    static let minimumWidth: CGFloat = 220
    static let defaultWidth: CGFloat = minimumWidth
    static let maximumWidth: CGFloat = 1_080
    static let accessibilityStep: CGFloat = 20

    private var widthsByColumnIndex: [Int: CGFloat] = [:]

    func width(for columnIndex: Int) -> CGFloat {
        widthsByColumnIndex[columnIndex] ?? Self.defaultWidth
    }

    mutating func setWidth(_ width: CGFloat, for columnIndex: Int) {
        widthsByColumnIndex[columnIndex] = Self.clampedWidth(width)
    }

    static func clampedWidth(_ width: CGFloat) -> CGFloat {
        min(maximumWidth, max(minimumWidth, width))
    }

    mutating func resetWidth(for columnIndex: Int) {
        widthsByColumnIndex.removeValue(forKey: columnIndex)
    }
}

struct BrowserColumnResizeDrag {
    let startWidth: CGFloat

    func width(forTranslation translation: CGFloat) -> CGFloat {
        BrowserColumnWidthState.clampedWidth(startWidth + translation)
    }
}

private struct BrowserColumnResizeHandle: View {
    let columnIndex: Int
    let width: CGFloat
    let onWidthChange: (CGFloat) -> Void
    let onReset: () -> Void

    @State private var drag: BrowserColumnResizeDrag?
    @State private var isHovering = false
    @GestureState private var isDragging = false
    @State private var isCursorPushed = false

    var body: some View {
        ZStack {
            Color.clear
            Rectangle()
                .fill(isHovering || isDragging ? Color.accentColor.opacity(0.65) : Color(nsColor: .separatorColor))
                .frame(width: 1)
        }
        .frame(width: 8)
        .contentShape(.rect)
        .onHover { hovering in
            isHovering = hovering
            updateCursor(shouldShow: hovering || isDragging)
        }
        .gesture(resizeGesture)
        .simultaneousGesture(TapGesture(count: 2).onEnded(onReset))
        .accessibilityElement()
        .accessibilityLabel("调整第 \(columnIndex + 1) 列宽度")
        .accessibilityValue("\(Int(width.rounded())) 点")
        .accessibilityHint("拖动调整，双击恢复默认宽度")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                onWidthChange(width + BrowserColumnWidthState.accessibilityStep)
            case .decrement:
                onWidthChange(width - BrowserColumnWidthState.accessibilityStep)
            @unknown default:
                break
            }
        }
        .onDisappear {
            drag = nil
            isHovering = false
            updateCursor(shouldShow: false)
        }
        .onChange(of: isDragging) { _, dragging in
            // GestureState also resets when a drag is cancelled without onEnded.
            if !dragging {
                finishDrag()
            }
        }
    }

    private var resizeGesture: some Gesture {
        // The handle moves as its column grows. Measure in the fixed viewport,
        // not in the handle or the horizontally scrolling content.
        DragGesture(minimumDistance: 1, coordinateSpace: .named(BrowserCoordinateSpace.viewport))
            .updating($isDragging) { _, dragging, _ in
                dragging = true
            }
            .onChanged { value in
                if drag == nil {
                    drag = BrowserColumnResizeDrag(startWidth: width)
                    updateCursor(shouldShow: true)
                }
                if let drag {
                    onWidthChange(drag.width(forTranslation: value.translation.width))
                }
            }
            .onEnded { value in
                if let drag {
                    onWidthChange(drag.width(forTranslation: value.translation.width))
                }
                finishDrag()
            }
    }

    private func finishDrag() {
        drag = nil
        updateCursor(shouldShow: isHovering)
    }

    private func updateCursor(shouldShow: Bool) {
        guard shouldShow != isCursorPushed else { return }
        if shouldShow {
            NSCursor.resizeLeftRight.push()
        } else {
            NSCursor.pop()
        }
        isCursorPushed = shouldShow
    }
}
