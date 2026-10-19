import Darwin
import XCTest
@testable import ClearX

@MainActor
final class MachineDiskModelTests: XCTestCase {
    func testCatalogUsesStartupRootWithItsActualVolumeIdentity() async throws {
        let source = try await SourceCatalog().machineDiskSource()
        var info = stat()
        XCTAssertEqual(lstat("/", &info), 0)

        XCTAssertEqual(source.kind, .machineDisk)
        XCTAssertEqual(source.rootURL, URL(fileURLWithPath: "/", isDirectory: true))
        XCTAssertEqual(source.displayName, "本机磁盘")
        XCTAssertEqual(source.volume?.deviceID, Int64(info.st_dev))
        XCTAssertNotEqual(source.rootURL.path, "/System/Volumes/Data")
    }

    func testFirstLoadResolvesSourceOnceAndPreservesItsIdentity() async {
        let source = machineDiskSource()
        var calls = 0
        let model = MachineDiskModel {
            calls += 1
            return source
        }

        XCTAssertEqual(model.state, .idle)
        await model.loadIfNeeded()
        await model.loadIfNeeded()
        await model.retry()

        XCTAssertEqual(model.state, .ready(source))
        XCTAssertEqual(calls, 1)
    }

    func testRepeatedLoadWhileResolvingDoesNotStartAnotherRequest() async {
        let source = machineDiskSource()
        var continuation: CheckedContinuation<ScanSource, Never>?
        let model = MachineDiskModel {
            await withCheckedContinuation { continuation = $0 }
        }
        let task = Task { await model.loadIfNeeded() }
        while continuation == nil { await Task.yield() }

        XCTAssertEqual(model.state, .loading)
        await model.loadIfNeeded()
        continuation?.resume(returning: source)
        await task.value

        XCTAssertEqual(model.state, .ready(source))
    }

    func testFailureDoesNotFallBackOrAutomaticallyRetry() async {
        var calls = 0
        let error = CocoaError(.fileReadNoPermission)
        let model = MachineDiskModel {
            calls += 1
            throw error
        }

        await model.loadIfNeeded()
        await model.loadIfNeeded()

        XCTAssertEqual(model.state, .failed(error.localizedDescription))
        XCTAssertEqual(calls, 1)
    }

    func testExplicitRetryCanRecoverFromSourceResolutionFailure() async {
        let source = machineDiskSource()
        var calls = 0
        let model = MachineDiskModel {
            calls += 1
            if calls == 1 { throw CocoaError(.fileReadNoPermission) }
            return source
        }

        await model.loadIfNeeded()
        await model.retry()

        XCTAssertEqual(model.state, .ready(source))
        XCTAssertEqual(calls, 2)
    }

    func testCancelledResolutionDoesNotCreateAResultSessionAndCanLoadAgain() async {
        let source = machineDiskSource()
        var continuation: CheckedContinuation<ScanSource, Never>?
        var calls = 0
        let model = MachineDiskModel {
            calls += 1
            if calls == 1 {
                return await withCheckedContinuation { continuation = $0 }
            }
            return source
        }
        let task = Task { await model.loadIfNeeded() }
        while continuation == nil { await Task.yield() }
        task.cancel()
        continuation?.resume(returning: source)
        await task.value

        XCTAssertEqual(model.state, .idle)
        await model.loadIfNeeded()
        XCTAssertEqual(model.state, .ready(source))
        XCTAssertEqual(calls, 2)
    }

    private func machineDiskSource() -> ScanSource {
        ScanSource(kind: .machineDisk, rootURL: URL(fileURLWithPath: "/", isDirectory: true))
    }
}
