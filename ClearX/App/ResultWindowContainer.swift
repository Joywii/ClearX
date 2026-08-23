import SwiftUI

@MainActor
private final class ResultWindowSession: ObservableObject {
    let source: ScanSource
    let browser: ResultBrowserModel

    private let cache: InMemoryScanCache
    private let displayedSnapshot: DisplayedScanSnapshot
    private var scanTask: Task<Void, Never>?
    private var hasStarted = false
    private var retainsCache = false

    init(source: ScanSource) {
        self.source = source
        self.cache = .shared
        let displayedSnapshot = DisplayedScanSnapshot()
        self.displayedSnapshot = displayedSnapshot
        self.browser = ResultBrowserModel(
            source: source,
            columnLoader: InMemorySnapshotColumnLoader(displayedSnapshot: displayedSnapshot),
            workPrioritizer: ScanCoordinator.shared
        )
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
        Task { [cache, displayedSnapshot, source] in
            await displayedSnapshot.clear()
            await cache.release(source: source)
        }
    }

    private func loadOrScan() async {
        if let result = await cache.result(for: source) {
            await displayedSnapshot.set(result.snapshot)
            browser.updatePresentationState(.completed(result.status))
            await browser.loadInitialColumn()
            return
        }
        await scanCompletely()
    }

    private func scanCompletely() async {
        let previousResult = await cache.result(for: source)
        let candidate = ScanTreeStore()
        let scanner = FileTreeScanner(tree: candidate)
        let displaysCandidateDuringScan = previousResult == nil
        if displaysCandidateDuringScan {
            await displayedSnapshot.set(candidate)
            await browser.loadInitialColumn()
        }

        do {
            let result = try await ScanCoordinator.shared.performScan(
                source: source,
                request: ScanRequest(rootURL: source.rootURL, sourceID: source.id),
                scanner: scanner,
                progress: { [weak self] progress in
                    await self?.publish(progress, refreshesVisibleColumns: displaysCandidateDuringScan)
                }
            )
            if await cache.store(result) {
                await displayedSnapshot.set(result.snapshot)
                browser.updatePresentationState(.completed(result.status))
                await browser.loadInitialColumn()
            } else if let previousResult {
                await displayedSnapshot.set(previousResult.snapshot)
                // Preserve the last complete tree, but report the rejected candidate's outcome.
                browser.updatePresentationState(.completed(result.status))
                await browser.loadInitialColumn()
            } else {
                await displayedSnapshot.set(result.snapshot)
                browser.updatePresentationState(.completed(result.status))
                await browser.loadInitialColumn()
            }
        } catch is CancellationError {
            if let previousResult {
                await displayedSnapshot.set(previousResult.snapshot)
                await browser.loadInitialColumn()
            }
            browser.updatePresentationState(.cancelled)
        } catch {
            if let previousResult {
                await displayedSnapshot.set(previousResult.snapshot)
                await browser.loadInitialColumn()
            }
            browser.updatePresentationState(.synchronizationFailed(error.localizedDescription))
        }
    }

    private func publish(_ progress: ScanProgress, refreshesVisibleColumns: Bool) async {
        browser.updatePresentationState(.scanning(progress))
        if refreshesVisibleColumns {
            await browser.refreshVisibleColumns(for: progress)
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
