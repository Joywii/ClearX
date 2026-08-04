import Foundation

@MainActor
final class SourceSelectionModel: ObservableObject {
    @Published private(set) var sources: [ScanSource] = []
    @Published private(set) var isLoading = false
    @Published private(set) var loadError: String?

    private let catalog: any ScanSourceCataloging

    init(catalog: any ScanSourceCataloging) {
        self.catalog = catalog
    }

    func loadSources() async {
        guard !isLoading else { return }

        isLoading = true
        loadError = nil
        defer { isLoading = false }

        sources = await catalog.discoverSources()
    }
}
