import SwiftUI

@MainActor
private final class ResultWindowSession: ObservableObject {
    let source: ScanSource
    let browser: ResultBrowserModel

    private let cache: InMemoryScanCache
    private let liveTree = LiveScanTree()
    private let scanner = FileTreeScanner()
    private var scanTask: Task<Void, Never>?
    private var hasStarted = false
    private var retainsCache = false

    init(source: ScanSource) {
        self.source = source
        self.cache = .shared
        self.browser = ResultBrowserModel(source: source, columnLoader: InMemorySnapshotColumnLoader(cache: cache, liveTree: liveTree), workPrioritizer: ScanCoordinator.shared)
    }

    deinit {
        scanTask?.cancel()
    }

    func beginIfNeeded() {
        guard !hasStarted else { return }
        hasStarted = true
        scanTask = Task { [weak self] in
            guard let self else { return }
            await cache.retain(source: source)
            retainsCache = true
            await loadOrScan()
        }
    }

    func rescanCompletely() {
        scanTask?.cancel()
        scanTask = Task { [weak self] in
            await self?.scanCompletely()
        }
    }

    func cancel() {
        scanTask?.cancel()
    }

    func end() {
        cancel()
        guard retainsCache else { return }
        retainsCache = false
        Task { [cache, source] in
            await cache.release(source: source)
        }
    }

    private func loadOrScan() async {
        if let result = await cache.result(for: source) {
            browser.updatePresentationState(.completed(result.status))
            await browser.loadInitialColumn()
            return
        }
        await scanCompletely()
    }

    private func scanCompletely() async {
        do {
            await liveTree.reset()
            let result = try await ScanCoordinator.shared.performScan(
                source: source,
                request: ScanRequest(rootURL: source.rootURL, sourceID: source.id),
                scanner: scanner,
                progress: { [weak self] progress in
                    await self?.publish(progress)
                }
            )
            await cache.store(result)
            browser.updatePresentationState(.completed(result.status))
            await browser.loadInitialColumn()
        } catch is CancellationError {
            browser.updatePresentationState(.cancelled)
        } catch {
            browser.updatePresentationState(.synchronizationFailed(error.localizedDescription))
        }
    }

    private func publish(_ progress: ScanProgress) async {
        await liveTree.apply(progress)
        browser.updatePresentationState(.scanning(progress))
        for parent in browser.liveColumnParents() {
            browser.applyLiveColumn(await liveTree.column(for: parent))
        }
    }
}

struct ResultWindowContainer: View {
    @StateObject private var session: ResultWindowSession

    init(source: ScanSource) {
        _session = StateObject(wrappedValue: ResultWindowSession(source: source))
    }

    var body: some View {
        ResultWindowView(model: session.browser, onRequestFullRescan: session.rescanCompletely, onCancelScan: session.cancel)
        .task { session.beginIfNeeded() }
        .onDisappear { session.end() }
    }
}
