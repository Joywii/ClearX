import Foundation

struct ScanRequest: Sendable, Hashable {
    let rootURL: URL
    let sourceID: ScanSourceID

    init(rootURL: URL, sourceID: ScanSourceID) {
        self.rootURL = rootURL.standardizedFileURL
        self.sourceID = sourceID
    }
}

protocol FileTreeScanning: Sendable {
    func scan(source: ScanSource, request: ScanRequest, progress: (@Sendable (ScanProgress) async -> Void)?) async throws -> ScanResult
}

/// Allows the browser to move queued work for the directory it is showing ahead
/// of unrelated deep branches. The scan remains breadth-first otherwise.
protocol ScanWorkPrioritizing: Sendable {
    func prioritize(directory: URL?, for sourceID: ScanSourceID) async
}

protocol ScanSourceCataloging: Sendable {
    func discoverSources() async -> [ScanSource]
}

protocol EventReplaying: Sendable {
    func replay(from checkpoint: EventCheckpoint, for source: ScanSource) async throws -> EventReplay
}
