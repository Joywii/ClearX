import XCTest
@testable import ClearX

final class EventValidatorTests: XCTestCase {
    func testEventWithinRootRefreshesNearestExistingParent() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appending(path: "folder", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let source = ScanSource(kind: .folder, rootURL: root)
        let checkpoint = EventCheckpoint(eventID: 40, volume: VolumeIdentity(deviceID: 1))
        let replay = EventReplay(
            events: [FileSystemEvent(id: 41, url: folder.appending(path: "deleted-file"))],
            highWaterMark: 41,
            completed: true
        )

        let validation = EventValidator().validate(replay: replay, from: checkpoint, for: source)

        XCTAssertEqual(validation, .refreshBranches(urls: [folder.standardizedFileURL], checkpoint: EventCheckpoint(eventID: 41, volume: checkpoint.volume)))
    }

    func testAmbiguousEventRequiresFullRescan() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = ScanSource(kind: .folder, rootURL: root)
        let checkpoint = EventCheckpoint(eventID: 1, volume: VolumeIdentity(deviceID: 1))
        let replay = EventReplay(
            events: [FileSystemEvent(id: 2, url: root, flags: [.mustScanSubDirectories])],
            highWaterMark: 2,
            completed: true
        )

        XCTAssertEqual(EventValidator().validate(replay: replay, from: checkpoint, for: source), .fullRescan(reason: .ambiguousFlags))
    }

    func testGlobalEventIDGapDoesNotInvalidateCache() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appending(path: "folder", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let source = ScanSource(kind: .folder, rootURL: root)
        let checkpoint = EventCheckpoint(eventID: 40, volume: VolumeIdentity(deviceID: 1))
        let replay = EventReplay(
            events: [FileSystemEvent(id: 93, url: folder.appending(path: "changed-file"))],
            highWaterMark: 93,
            completed: true
        )

        XCTAssertEqual(EventValidator().validate(replay: replay, from: checkpoint, for: source), .refreshBranches(urls: [folder.standardizedFileURL], checkpoint: EventCheckpoint(eventID: 93, volume: checkpoint.volume)))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "ClearXEventTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
