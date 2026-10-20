import SwiftUI

@MainActor
final class ResultWindowSession: ObservableObject {
    let source: ScanSource
    let browser: ResultBrowserModel

    private let cache: InMemoryScanCache
    private let displayedSnapshot: DisplayedScanSnapshot
    private(set) var scanTask: Task<Void, Never>?
    private let coordinator: ScanCoordinator
    private let makeScanner: @Sendable (ScanTreeStore) -> any FileTreeScanning
    private var hasStarted = false
    private var retainsCache = false
    private var hasEnded = false

    init(source: ScanSource, cache: InMemoryScanCache = .shared, coordinator: ScanCoordinator = .shared,
         makeScanner: @escaping @Sendable (ScanTreeStore) -> any FileTreeScanning = { FileTreeScanner(tree: $0) }) {
        self.source = source
        self.cache = cache
        self.coordinator = coordinator
        self.makeScanner = makeScanner
        let displayedSnapshot = DisplayedScanSnapshot()
        self.displayedSnapshot = displayedSnapshot
        self.browser = ResultBrowserModel(
            source: source,
            columnLoader: InMemorySnapshotColumnLoader(displayedSnapshot: displayedSnapshot),
            workPrioritizer: coordinator
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
            guard !hasEnded else {
                await cache.release(source: source)
                return
            }
            retainsCache = true
            await loadOrScan()
        }
    }

    func rescanCompletely() {
        guard retainsCache, !hasEnded else { return }
        let previousTask = scanTask
        previousTask?.cancel()
        scanTask = Task { [weak self] in
            await previousTask?.value
            guard !Task.isCancelled else { return }
            await self?.scanCompletely()
        }
    }

    func filesWereTrashed(_ urls: [URL]) async {
        let rootURL = source.rootURL
        let overlaps = await Task.detached {
            let root = FileLocation.resolved(rootURL)
            return urls.contains { FileLocation.overlaps(root, FileLocation.entry($0)) }
        }.value
        guard overlaps, retainsCache else { return }
        browser.isStale = true
        rescanCompletely()
    }

    func cancel() {
        scanTask?.cancel()
    }

    func end() {
        hasEnded = true
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
        let previousSnapshot: ScanTreeStore?
        if let previousResult { previousSnapshot = previousResult.snapshot }
        else if browser.isStale { previousSnapshot = await displayedSnapshot.current() }
        else { previousSnapshot = nil }
        browser.updatePresentationState(
            .scanning(ScanProgress(discoveredNodeCount: 0, completedDirectoryCount: 0, currentURL: nil)),
            displayingPreviousResult: previousSnapshot != nil
        )
        let candidate = ScanTreeStore()
        let scanner = makeScanner(candidate)
        let displaysCandidateDuringScan = previousSnapshot == nil
        if displaysCandidateDuringScan {
            await displayedSnapshot.set(candidate)
            await browser.loadInitialColumn(resetNavigation: true)
        }

        do {
            _ = try await coordinator.performScan(
                source: source,
                request: ScanRequest(rootURL: source.rootURL, sourceID: source.id),
                scanner: scanner,
                progress: { [weak self] progress in
                    await self?.publish(progress, refreshesVisibleColumns: displaysCandidateDuringScan)
                },
                publishResult: { [weak self] result in
                    await self?.publishResult(result, previousSnapshot: previousSnapshot)
                }
            )
        } catch is CancellationError {
            if let previousSnapshot {
                await displayedSnapshot.set(previousSnapshot)
            }
            browser.updatePresentationState(.cancelled)
        } catch {
            if let previousSnapshot {
                await displayedSnapshot.set(previousSnapshot)
            }
            browser.updatePresentationState(.synchronizationFailed(error.localizedDescription))
        }
    }

    private func publishResult(_ result: ScanResult, previousSnapshot: ScanTreeStore?) async {
        guard retainsCache else { return }
        // Cancellation can arrive after the scanner sealed a complete tree.
        // An explicitly cancelled rescan must not replace the old snapshot.
        if Task.isCancelled, previousSnapshot != nil {
            browser.updatePresentationState(.cancelled)
            return
        }
        if await cache.store(result) {
            await displayedSnapshot.set(result.snapshot)
            browser.isStale = false
            browser.updatePresentationState(.completed(result.status), displayingPreviousResult: false)
            if previousSnapshot != nil {
                await browser.loadInitialColumn(resetNavigation: true)
            } else {
                await browser.refreshAllColumns()
            }
        } else if let previousSnapshot {
            await displayedSnapshot.set(previousSnapshot)
            // Preserve the last complete tree, but report the rejected candidate's outcome.
            browser.updatePresentationState(.completed(result.status))
        } else {
            await displayedSnapshot.set(result.snapshot)
            browser.updatePresentationState(.completed(result.status))
            await browser.refreshAllColumns()
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
        .onReceive(NotificationCenter.default.publisher(for: .clearXFilesTrashed)) { notification in
            if let urls = notification.object as? [URL] {
                Task { await session.filesWereTrashed(urls) }
            }
        }
    }
}
