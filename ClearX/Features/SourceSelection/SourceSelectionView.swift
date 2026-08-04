import AppKit
import SwiftUI

struct SourceSelectionView: View {
    @ObservedObject var model: SourceSelectionModel
    let onSelectSource: (ScanSource) -> Void
    let onSelectFolder: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Text("选择要分析的位置")
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                Text("ClearX 仅分析空间使用情况，不会修改您的文件。")
                    .foregroundStyle(.secondary)
            }

            sourceList

            Divider()

            Button(action: chooseFolder) {
                Label("选择文件夹…", systemImage: "folder.badge.plus")
            }
            .keyboardShortcut("o", modifiers: .command)

            if let loadError = model.loadError {
                ContentUnavailableView("无法加载扫描源", systemImage: "exclamationmark.triangle", description: Text(loadError))
            }
        }
        .padding(32)
        .frame(minWidth: 520, minHeight: 340, alignment: .topLeading)
        .task { await model.loadSources() }
    }

    @ViewBuilder
    private var sourceList: some View {
        if model.isLoading && model.sources.isEmpty {
            ProgressView("正在查找本地磁盘…")
                .frame(maxWidth: .infinity, minHeight: 120)
        } else if model.sources.isEmpty {
            ContentUnavailableView("未找到可用的本地卷", systemImage: "internaldrive", description: Text("您仍可选择一个文件夹进行分析。"))
        } else {
            VStack(spacing: 8) {
                ForEach(model.sources) { source in
                    Button {
                        onSelectSource(source)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: source.kind == .machineDisk ? "internaldrive" : "externaldrive")
                                .font(.title2)
                                .frame(width: 34)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(source.displayName)
                                    .font(.headline)
                                Text(source.rootURL.path(percentEncoded: false))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(.tertiary)
                        }
                        .padding(14)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "分析此文件夹"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        onSelectFolder(url)
    }
}
