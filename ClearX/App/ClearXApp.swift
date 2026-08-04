import SwiftUI

@main
struct ClearXApp: App {
    var body: some Scene {
        WindowGroup {
            SourceSelectionContainer()
        }
        .defaultSize(width: 760, height: 520)

        WindowGroup(id: "result", for: ScanSource.self) { source in
            if let selectedSource = source.wrappedValue {
                ResultWindowContainer(source: selectedSource)
            } else {
                ContentUnavailableView("未选择扫描源", systemImage: "internaldrive")
            }
        }
        .defaultSize(width: 1080, height: 620)
    }
}

private struct SourceSelectionContainer: View {
    @StateObject private var model = SourceSelectionModel(catalog: SourceCatalog())
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        SourceSelectionView(
            model: model,
            onSelectSource: openResult,
            onSelectFolder: { url in
                Task {
                    let source = await SourceCatalog().folderSource(for: url)
                    await MainActor.run { openResult(source) }
                }
            }
        )
    }

    private func openResult(_ source: ScanSource) {
        openWindow(id: "result", value: source)
    }
}
