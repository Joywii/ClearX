import Darwin
import Foundation

/// Converts an event replay into the only three safe cache actions: use, refresh branches, or rescan.
struct EventValidator: Sendable {
    func validate(replay: EventReplay, from checkpoint: EventCheckpoint, for source: ScanSource) -> EventValidation {
        guard replay.completed else {
            return .fullRescan(reason: .replayIncomplete)
        }
        guard replay.highWaterMark >= checkpoint.eventID else {
            return .fullRescan(reason: .eventHistoryLost)
        }
        guard checkpoint.volume == source.volume || source.volume == nil else {
            return .fullRescan(reason: .pathOutsideVolume)
        }

        let orderedEvents = replay.events
            .filter { $0.id > checkpoint.eventID && $0.id <= replay.highWaterMark }
            .sorted { $0.id < $1.id }
        var affectedDirectories = [URL]()
        for event in orderedEvents {
            // FSEvents IDs are global to a volume. IDs unrelated to this source
            // may be absent from this replay, so numeric gaps are not data loss.
            guard !event.flags.requiresFullRescan else {
                return .fullRescan(reason: .ambiguousFlags)
            }
            guard isInside(event.url, root: source.rootURL) else {
                return .fullRescan(reason: .pathOutsideRoot)
            }
            guard let directory = normalizedDirectory(for: event.url, source: source) else {
                return .fullRescan(reason: .pathCannotBeNormalized)
            }
            affectedDirectories.append(directory)
        }

        let nextCheckpoint = EventCheckpoint(eventID: replay.highWaterMark, volume: checkpoint.volume)
        guard !affectedDirectories.isEmpty else {
            return .cacheValid(nextCheckpoint)
        }
        return .refreshBranches(urls: shallowUniqueDirectories(affectedDirectories), checkpoint: nextCheckpoint)
    }

    private func normalizedDirectory(for eventURL: URL, source: ScanSource) -> URL? {
        let rootURL = source.rootURL.standardizedFileURL
        let expectedDevice = source.volume?.deviceID
        var candidate = eventURL.standardizedFileURL
        while isInside(candidate, root: rootURL) {
            if let status = fileStatus(at: candidate), status.isDirectory {
                guard expectedDevice == nil || status.deviceID == expectedDevice else { return nil }
                return candidate
            }
            let parent = candidate.deletingLastPathComponent().standardizedFileURL
            guard parent.path != candidate.path else { break }
            candidate = parent
        }
        return nil
    }

    private func shallowUniqueDirectories(_ urls: [URL]) -> [URL] {
        let sorted = urls.sorted {
            let leftDepth = $0.pathComponents.count
            let rightDepth = $1.pathComponents.count
            if leftDepth != rightDepth { return leftDepth < rightDepth }
            return $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
        var result = [URL]()
        for url in sorted where !result.contains(where: { isInside(url, root: $0) }) {
            result.append(url)
        }
        return result
    }

    private func isInside(_ candidate: URL, root: URL) -> Bool {
        let candidatePath = candidate.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath == "/" ? "/" : rootPath + "/")
    }

    private func fileStatus(at url: URL) -> EventFileStatus? {
        var info = stat()
        let result = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return -1 }
            return Int(lstat(path, &info))
        }
        guard result == 0 else { return nil }
        return EventFileStatus(info: info)
    }
}

private struct EventFileStatus {
    let deviceID: Int64
    let isDirectory: Bool

    init(info: stat) {
        deviceID = Int64(info.st_dev)
        isDirectory = (info.st_mode & S_IFMT) == S_IFDIR
    }
}
