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
    @State private var horizontalPosition = BrowserHorizontalScrollPosition()
    @State private var columnFrames: [Int: BrowserColumnGeometry] = [:]
    @State private var showsSizeSummary = false
    @State private var actionFailure: ScanItemActionFailure?
    @StateObject private var trashOperation = TrashOperationModel()

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
            .sheet(isPresented: Binding(get: { trashOperation.isPresented }, set: { if !$0 { trashOperation.dismiss() } })) {
                TrashConfirmationView(operation: trashOperation, root: model.source.rootURL)
            }
            .alert("无法完成操作", isPresented: Binding(
                get: { actionFailure != nil },
                set: { if !$0 { actionFailure = nil } }
            ), presenting: actionFailure) { _ in
                Button("好", role: .cancel) { actionFailure = nil }
            } message: { failure in
                Text(failure.message + "\n" + failure.url.path)
            }
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
                    Group {
                        ScrollView(.horizontal) {
                            HStack(alignment: .top, spacing: 0) {
                                ForEach(Array(model.columns.enumerated()), id: \.offset) { index, column in
                                    let width = columnWidths.width(for: index)
                                    HStack(spacing: 0) {
                                        BrowserColumnView(
                                            column: column,
                                            remainingNodeCount: model.remainingNodeCount(inColumn: index),
                                            highlightedIDs: model.highlightedIDs(inColumn: index),
                                            root: model.source.rootURL,
                                            isScanning: model.isScanning,
                                            width: width,
                                            targets: { model.contextTargets(for: $0, inColumn: index) },
                                            onBegin: {
                                                viewportRetention.capture(frames: columnFrames, viewportWidth: viewport.size.width)
                                                columnReveal.cancel()
                                                model.beginSelectionGesture(inColumn: index)
                                            },
                                            onSelection: { ids in
                                                model.updateSelection(ids, inColumn: index)
                                            },
                                            onFinish: {
                                                Task { await model.finishSelectionGesture(inColumn: index) }
                                            },
                                            onPlainClick: { select($0, inColumn: index, viewportWidth: viewport.size.width) },
                                            onLoadMore: {
                                                Task { await model.loadMore(inColumn: index) }
                                            },
                                            onItemAction: performItemAction,
                                            onTrash: { trashOperation.prepare($0, root: model.source.rootURL) }
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
                                BrowserHorizontalScrollInput(onManualScroll: {
                                    if columnReveal.pending != nil { columnReveal.cancel() }
                                }, position: horizontalPosition)
                            }
                        }
                        .coordinateSpace(name: BrowserCoordinateSpace.viewport)
                        .onPreferenceChange(BrowserColumnFramesKey.self) { frames in
                            columnFrames = frames
                            revealColumn(viewportWidth: viewport.size.width)
                        }
                        .onChange(of: columnReveal) { _, _ in
                            revealColumn(viewportWidth: viewport.size.width)
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

    private func performItemAction(_ action: ScanItemAction, at url: URL) {
        Task {
            if let failure = await ScanItemActions().perform(action, at: url) {
                actionFailure = failure
            }
        }
    }

    private func revealColumn(viewportWidth: CGFloat) {
        guard let target = columnReveal.consume(frames: columnFrames, viewportWidth: viewportWidth),
              let geometry = columnFrames[target.columnIndex] else { return }
        horizontalPosition.reveal(frame: geometry.frame, alignment: target.alignment, viewportWidth: viewportWidth)
    }

    private var isScanning: Bool {
        model.isScanning
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
    let remainingNodeCount: Int
    let highlightedIDs: Set<ScanNodeID>
    let root: URL
    let isScanning: Bool
    let width: CGFloat
    let targets: (ScanNodeSummary) -> [ScanNodeSummary]
    let onBegin: () -> Void
    let onSelection: (Set<ScanNodeID>) -> Void
    let onFinish: () -> Void
    let onPlainClick: (ScanNodeSummary) -> Void
    let onLoadMore: () -> Void
    let onItemAction: (ScanItemAction, URL) -> Void
    let onTrash: ([ScanNodeSummary]) -> Void

    var body: some View {
        VStack(spacing: 0) {
                BrowserSelectionTable(column: column, highlightedIDs: highlightedIDs, root: root,
                                      isScanning: isScanning,
                                      targets: targets, onBegin: onBegin, onSelection: onSelection,
                                      onFinish: onFinish, onPlainClick: onPlainClick,
                                      onAction: onItemAction, onTrash: onTrash)
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
