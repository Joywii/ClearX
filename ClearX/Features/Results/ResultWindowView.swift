import AppKit
import SwiftUI

struct ResultWindowView: View {
    @ObservedObject var model: ResultBrowserModel
    let onRequestFullRescan: () -> Void
    let onCancelScan: () -> Void
    @State private var columnWidths = BrowserColumnWidthState()

    var body: some View {
        browser
            .navigationTitle(model.source.displayName)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    ScanStatusLabel(state: model.presentationState)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("重新完整扫描", systemImage: "arrow.clockwise", action: onRequestFullRescan)
                }
                if isScanning {
                    ToolbarItem(placement: .primaryAction) {
                        Button("取消扫描", systemImage: "xmark", action: onCancelScan)
                    }
                }
            }
            .task { await model.loadInitialColumn() }
    }

    private var browser: some View {
        Group {
            if model.columns.isEmpty {
                if isScanning {
                    BrowserColumnSkeleton()
                        .frame(width: BrowserColumnWidthState.defaultWidth)
                } else {
                    ContentUnavailableView("正在准备结果", systemImage: "internaldrive", description: Text("扫描完成后会持续显示可用结果。"))
                }
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    if isScanning {
                        ScanProgressSummary(source: model.source, state: model.presentationState)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                        Divider()
                    }
                    ScrollView(.horizontal) {
                        HStack(alignment: .top, spacing: 0) {
                            ForEach(Array(model.columns.enumerated()), id: \.offset) { index, column in
                                let width = columnWidths.width(for: index)
                                BrowserColumnView(
                                    column: column,
                                    nodes: model.visibleNodes(inColumn: index),
                                    remainingNodeCount: model.remainingNodeCount(inColumn: index),
                                    selectedNodeID: selectedID(in: index),
                                    width: width,
                                    onSelect: { node in
                                        Task { await model.select(node, inColumn: index) }
                                    },
                                    onLoadMore: {
                                        model.loadMore(inColumn: index)
                                    }
                                )
                                BrowserColumnResizeHandle(
                                    columnIndex: index,
                                    width: width,
                                    onWidthChange: { columnWidths.setWidth($0, for: index) },
                                    onReset: { columnWidths.resetWidth(for: index) }
                                )
                            }
                        }
                        .padding(.trailing, 4)
                        .frame(minHeight: 360, alignment: .topLeading)
                    }
                }
            }
        }
        .frame(minWidth: 720, minHeight: 440)
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
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(nodes) { node in
                    Button {
                        onSelect(node)
                    } label: {
                        ScanNodeRowView(node: node, parentSize: column.parent?.allocatedSize, isSelected: node.id == selectedNodeID, isEstimating: column.estimatingNodeIDs.contains(node.id))
                    }
                    .buttonStyle(.plain)
                }
                if column.state == .loading && nodes.isEmpty {
                    BrowserColumnSkeleton(rowCount: 6)
                }
                if remainingNodeCount > 0 {
                    Button("加载更多（剩余 \(remainingNodeCount) 项）", action: onLoadMore)
                        .buttonStyle(.plain)
                        .foregroundStyle(.tint)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(8)
        }
        .frame(width: width)
        .accessibilityLabel(column.parent?.name ?? "根目录")
    }
}

struct BrowserColumnWidthState {
    static let defaultWidth: CGFloat = 290
    static let minimumWidth: CGFloat = 220
    static let maximumWidth: CGFloat = 1_080
    static let accessibilityStep: CGFloat = 20

    private var widthsByColumnIndex: [Int: CGFloat] = [:]

    func width(for columnIndex: Int) -> CGFloat {
        widthsByColumnIndex[columnIndex] ?? Self.defaultWidth
    }

    mutating func setWidth(_ width: CGFloat, for columnIndex: Int) {
        widthsByColumnIndex[columnIndex] = min(Self.maximumWidth, max(Self.minimumWidth, width))
    }

    mutating func resetWidth(for columnIndex: Int) {
        widthsByColumnIndex.removeValue(forKey: columnIndex)
    }
}

private struct BrowserColumnResizeHandle: View {
    let columnIndex: Int
    let width: CGFloat
    let onWidthChange: (CGFloat) -> Void
    let onReset: () -> Void

    @State private var dragStartWidth: CGFloat?
    @State private var isHovering = false
    @State private var isDragging = false
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
            updateCursor(shouldShow: false)
        }
    }

    private var resizeGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if dragStartWidth == nil {
                    dragStartWidth = width
                    isDragging = true
                    updateCursor(shouldShow: true)
                }
                onWidthChange((dragStartWidth ?? width) + value.translation.width)
            }
            .onEnded { _ in
                dragStartWidth = nil
                isDragging = false
                updateCursor(shouldShow: isHovering)
            }
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

private struct ScanProgressSummary: View {
    let source: ScanSource
    let state: ScanPresentationState

    var body: some View {
        if case let .scanning(progress) = state {
            VStack(alignment: .leading, spacing: 3) {
                Text("正在扫描 \(source.rootURL.path)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(currentPath(progress))
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Text("已发现 \(progress.discoveredNodeCount) 项，已完成 \(progress.completedDirectoryCount) 个目录")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func currentPath(_ progress: ScanProgress) -> String {
        guard let currentURL = progress.currentURL else { return "正在准备扫描范围" }
        let rootPath = source.rootURL.standardizedFileURL.path
        let currentPath = currentURL.standardizedFileURL.path
        guard currentPath == rootPath || currentPath.hasPrefix(rootPath + "/") else {
            return currentPath
        }
        let relative = String(currentPath.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return relative.isEmpty ? "当前：扫描源根目录" : "当前：\(relative)"
    }
}

private struct BrowserColumnSkeleton: View {
    var rowCount = 8

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(0..<rowCount, id: \.self) { index in
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(.quaternary)
                            .frame(width: 16, height: 16)
                        VStack(alignment: .leading, spacing: 5) {
                            Capsule()
                                .fill(.quaternary)
                                .frame(width: index.isMultiple(of: 3) ? 130 : 180, height: 11)
                            Capsule()
                                .fill(.quaternary)
                                .frame(width: 72, height: 8)
                        }
                    }
                    .redacted(reason: .placeholder)
                }
            }
            .padding(16)
        }
        .accessibilityLabel("正在加载目录结果")
    }
}

private struct ScanStatusLabel: View {
    let state: ScanPresentationState

    var body: some View {
        Label(statusText, systemImage: symbolName)
            .font(.callout)
            .foregroundStyle(statusColor)
            .lineLimit(1)
    }

    private var statusText: String {
        switch state {
        case .idle:
            "等待扫描"
        case let .scanning(progress):
            "扫描中，已发现 \(progress.discoveredNodeCount) 项"
        case .completed(.complete):
            "已同步"
        case .completed(.incomplete), .incomplete, .cancelled:
            "结果不完整"
        case .permissionRestricted:
            "部分项目无法访问"
        case .unavailable:
            "扫描源不可用"
        case .synchronizationFailed:
            "同步失败"
        }
    }

    private var symbolName: String {
        switch state {
        case .completed(.complete):
            "checkmark.circle"
        case .scanning:
            "arrow.triangle.2.circlepath"
        case .idle:
            "clock"
        default:
            "exclamationmark.triangle"
        }
    }

    private var statusColor: Color {
        switch state {
        case .completed(.complete):
            .secondary
        case .scanning, .idle:
            .accentColor
        default:
            .orange
        }
    }
}
