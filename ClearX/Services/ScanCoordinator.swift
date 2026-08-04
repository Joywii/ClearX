import Foundation

/// Shared directory-enumeration permit queue. It keeps metadata I/O bounded
/// without artificially limiting how many sources may have a live scan session.
actor ScanCoordinator {
    static let shared = ScanCoordinator()

    private let maximumConcurrentDirectoryEnumerations: Int
    private let maximumConcurrentDirectoriesPerSource: Int
    private var activeDirectoryEnumerations = 0
    private var activeDirectoriesBySource = [ScanSourceID: Int]()
    private var focusedSourceIDs = Set<ScanSourceID>()
    private var prioritizedDirectories = [ScanSourceID: URL]()
    private var waitingFocused = [DirectoryPermitRequest]()
    private var waitingBackground = [DirectoryPermitRequest]()

    init(maximumConcurrentDirectoryEnumerations: Int = 8, maximumConcurrentDirectoriesPerSource: Int = 8) {
        self.maximumConcurrentDirectoryEnumerations = max(1, maximumConcurrentDirectoryEnumerations)
        self.maximumConcurrentDirectoriesPerSource = max(1, maximumConcurrentDirectoriesPerSource)
    }

    func setFocused(_ isFocused: Bool, sourceID: ScanSourceID) {
        if isFocused {
            focusedSourceIDs.insert(sourceID)
        } else {
            focusedSourceIDs.remove(sourceID)
        }
    }

    func performScan(source: ScanSource, request: ScanRequest, scanner: any FileTreeScanning, progress: (@Sendable (ScanProgress) async -> Void)? = nil) async throws -> ScanResult {
        try await scanner.scan(source: source, request: request, progress: progress)
    }

    func prioritize(directory: URL?, for sourceID: ScanSourceID) {
        if let directory {
            prioritizedDirectories[sourceID] = directory.standardizedFileURL
        } else {
            prioritizedDirectories.removeValue(forKey: sourceID)
        }
    }

    func directoryPriority(for directory: URL, sourceID: ScanSourceID) -> Int {
        guard let prioritizedDirectory = prioritizedDirectories[sourceID] else { return 1 }
        let candidate = directory.standardizedFileURL.path
        let focused = prioritizedDirectory.path
        return candidate == focused || candidate.hasPrefix(focused + "/") ? 0 : 1
    }

    func prioritizedDirectory(for sourceID: ScanSourceID) -> URL? {
        prioritizedDirectories[sourceID]
    }

    func withDirectoryPermit<T: Sendable>(for sourceID: ScanSourceID, operation: @Sendable () async throws -> T) async throws -> T {
        try await acquireDirectoryPermit(for: sourceID)
        defer { releaseDirectoryPermit(for: sourceID) }
        return try await operation()
    }

    private func acquireDirectoryPermit(for sourceID: ScanSourceID) async throws {
        try Task.checkCancellation()
        if canAcquireDirectoryPermit(for: sourceID) {
            reserveDirectoryPermit(for: sourceID)
            return
        }
        let requestID = UUID()
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    let request = DirectoryPermitRequest(id: requestID, sourceID: sourceID, continuation: continuation)
                    if focusedSourceIDs.contains(sourceID) {
                        waitingFocused.append(request)
                    } else {
                        waitingBackground.append(request)
                    }
                }
            } onCancel: {
                Task { await self.cancelDirectoryPermitRequest(id: requestID) }
            }
        } catch {
            throw error
        }
        do {
            try Task.checkCancellation()
        } catch {
            releaseDirectoryPermit(for: sourceID)
            throw error
        }
    }

    private func releaseDirectoryPermit(for sourceID: ScanSourceID) {
        activeDirectoryEnumerations -= 1
        activeDirectoriesBySource[sourceID, default: 1] -= 1
        if activeDirectoriesBySource[sourceID] == 0 {
            activeDirectoriesBySource.removeValue(forKey: sourceID)
        }
        guard activeDirectoryEnumerations >= 0 else {
            activeDirectoryEnumerations = 0
            return
        }
        if let request = dequeueEligibleRequest(from: &waitingFocused) ?? dequeueEligibleRequest(from: &waitingBackground) {
            reserveDirectoryPermit(for: request.sourceID)
            request.continuation.resume()
        }
    }

    private func canAcquireDirectoryPermit(for sourceID: ScanSourceID) -> Bool {
        activeDirectoryEnumerations < maximumConcurrentDirectoryEnumerations
            && activeDirectoriesBySource[sourceID, default: 0] < maximumConcurrentDirectoriesPerSource
    }

    private func reserveDirectoryPermit(for sourceID: ScanSourceID) {
        activeDirectoryEnumerations += 1
        activeDirectoriesBySource[sourceID, default: 0] += 1
    }

    private func dequeueEligibleRequest(from requests: inout [DirectoryPermitRequest]) -> DirectoryPermitRequest? {
        guard activeDirectoryEnumerations < maximumConcurrentDirectoryEnumerations,
              let index = requests.firstIndex(where: { canAcquireDirectoryPermit(for: $0.sourceID) }) else {
            return nil
        }
        return requests.remove(at: index)
    }

    private func cancelDirectoryPermitRequest(id: UUID) {
        if let index = waitingFocused.firstIndex(where: { $0.id == id }) {
            waitingFocused.remove(at: index).continuation.resume(throwing: CancellationError())
        } else if let index = waitingBackground.firstIndex(where: { $0.id == id }) {
            waitingBackground.remove(at: index).continuation.resume(throwing: CancellationError())
        }
    }
}

extension ScanCoordinator: ScanWorkPrioritizing {}

private struct DirectoryPermitRequest: @unchecked Sendable {
    let id: UUID
    let sourceID: ScanSourceID
    let continuation: CheckedContinuation<Void, Error>
}
