import Foundation

@MainActor
final class MachineDiskModel: ObservableObject {
    enum State: Equatable {
        case idle
        case loading
        case ready(ScanSource)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    private let loadSource: @MainActor () async throws -> ScanSource

    init(loadSource: @escaping @MainActor () async throws -> ScanSource = {
        try await SourceCatalog().machineDiskSource()
    }) {
        self.loadSource = loadSource
    }

    func loadIfNeeded() async {
        guard state == .idle else { return }
        state = .loading
        do {
            let source = try await loadSource()
            try Task.checkCancellation()
            state = .ready(source)
        } catch is CancellationError {
            state = .idle
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func retry() async {
        guard case .failed = state else { return }
        state = .idle
        await loadIfNeeded()
    }
}
