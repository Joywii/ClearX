import SwiftUI

@main
struct ClearXApp: App {
    // Hosted unit tests must not start a real disk scan or restore scanning views.
    private let isRunningTests = NSClassFromString("XCTestCase") != nil
        || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    var body: some Scene {
        WindowGroup("本机磁盘", id: "machine-disk") {
            if !isRunningTests {
                MachineDiskContainer()
            }
        }
        .defaultSize(width: 1080, height: 620)
        .commands { ScanSourceCommands() }

        WindowGroup(id: "result", for: ScanSource.self) { source in
            if !isRunningTests {
                if let selectedSource = source.wrappedValue {
                    ResultWindowContainer(source: selectedSource)
                } else {
                    ContentUnavailableView("未选择扫描源", systemImage: "internaldrive")
                }
            }
        }
        .defaultSize(width: 1080, height: 620)

        Window("选择扫描源", id: "source-selection") {
            if !isRunningTests {
                SourceSelectionContainer()
            }
        }
        .defaultSize(width: 760, height: 520)
    }
}

private struct ScanSourceCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("分析本机磁盘") {
                openWindow(id: "machine-disk")
            }
            .keyboardShortcut("n", modifiers: .command)

            Button("分析其他磁盘或文件夹…") {
                openWindow(id: "source-selection")
            }
            .keyboardShortcut("o", modifiers: .command)
        }
    }
}

private struct MachineDiskContainer: View {
    @StateObject private var model = MachineDiskModel()

    var body: some View {
        Group {
            switch model.state {
            case .idle, .loading:
                Color.clear
                    .frame(minWidth: 720, minHeight: 440)
            case .ready(let source):
                ResultWindowContainer(source: source)
            case .failed(let message):
                ContentUnavailableView {
                    Label("无法读取本机磁盘", systemImage: "internaldrive")
                } description: {
                    Text(message)
                } actions: {
                    Button("重试") {
                        Task { await model.retry() }
                    }
                }
                .frame(minWidth: 720, minHeight: 440)
            }
        }
        .task { await model.loadIfNeeded() }
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
