import Darwin
import XCTest
@testable import ClearX

final class FileTreeScannerTests: XCTestCase {
    func testMountMatchingIsExactAndIgnoresDirectoryHints() {
        let mounts = ScanMountPoints(urls: [
            URL(fileURLWithPath: "/", isDirectory: true),
            URL(fileURLWithPath: "/fixture/unused/../Data/", isDirectory: true)
        ])
        XCTAssertTrue(mounts.contains(URL(fileURLWithPath: "/fixture/Data", isDirectory: false)))
        XCTAssertTrue(mounts.contains(URL(fileURLWithPath: "/fixture/Data/", isDirectory: true)))
        XCTAssertFalse(mounts.contains(URL(fileURLWithPath: "/fixture/Data-other")))
        XCTAssertFalse(mounts.contains(URL(fileURLWithPath: "/fixture/Data/Users")))
        XCTAssertFalse(mounts.contains(URL(fileURLWithPath: "/Users")))
    }

    func testScannerExcludesDuplicateMountButAllowsItAsSelectedRoot() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let users = root.appending(path: "Users", directoryHint: .isDirectory)
        let data = root.appending(path: "System/Volumes/Data", directoryHint: .isDirectory)
        let dataUsers = data.appending(path: "Users", directoryHint: .isDirectory)
        let nestedMount = data.appending(path: "nested", directoryHint: .isDirectory)
        let external = root.appending(path: "Volumes/Archive", directoryHint: .isDirectory)
        for directory in [users, dataUsers, nestedMount, external] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if directory != dataUsers {
                try Data(repeating: 1, count: 4_096).write(to: directory.appending(path: "payload"))
            }
        }
        XCTAssertEqual(link(users.appending(path: "payload").path, dataUsers.appending(path: "payload").path), 0)
        let mounts = ScanMountPoints(urls: [root, data, nestedMount, external])
        for selectedRoot in [root, data] {
            let source = ScanSource(kind: .folder, rootURL: selectedRoot)
            let result = try await FileTreeScanner(readMountPoints: { mounts }).scan(
                source: source, request: ScanRequest(rootURL: selectedRoot, sourceID: source.id)
            )
            let nodes = await result.allNodes()
            let rootNode = await result.snapshot.rootNode()
            let files = nodes.filter { $0.kind == .file }
            XCTAssertEqual(result.status, .complete)
            XCTAssertEqual(files.count, 1)
            XCTAssertEqual(files.first?.url.path, selectedRoot.appending(path: "Users/payload").path)
            XCTAssertEqual(rootNode?.allocatedSize, files.first?.allocatedSize)
            let summary = await result.snapshot.sizeSummary()
            XCTAssertEqual(summary.contentAllocatedSize, files.first?.allocatedSize)
            XCTAssertEqual(summary.uniqueAllocatedSize, files.first?.allocatedSize)
            XCTAssertGreaterThan(rootNode?.allocatedSize ?? 0, 0)
            let excludedURL = selectedRoot == root ? data : nestedMount
            let excluded = try XCTUnwrap(nodes.first { $0.url.path == excludedURL.path })
            XCTAssertEqual(excluded.kind, .mountPoint)
            XCTAssertEqual(excluded.allocatedSize, 0)
            XCTAssertFalse(excluded.isHardLink)
            XCTAssertFalse(nodes.contains { $0.parentID == excluded.id })
            if selectedRoot == root {
                XCTAssertEqual(nodes.first { $0.name == "System" }?.allocatedSize, 0)
                let externalNode = try XCTUnwrap(nodes.first { $0.url.path == external.path })
                XCTAssertEqual(externalNode.kind, .mountPoint)
                XCTAssertEqual(externalNode.allocatedSize, 0)
                XCTAssertFalse(nodes.contains { $0.parentID == externalNode.id })
            }
        }
    }

    func testNewScanReadsNewMountTable() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appending(path: "nested", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 4_096).write(to: nested.appending(path: "payload"))
        let source = ScanSource(kind: .folder, rootURL: root)
        for mounted in [false, true] {
            let scanner = FileTreeScanner(readMountPoints: { ScanMountPoints(urls: mounted ? [nested] : []) })
            let result = try await scanner.scan(source: source, request: ScanRequest(rootURL: root, sourceID: source.id))
            let nodes = await result.allNodes()
            XCTAssertEqual(nodes.first { $0.name == "nested" }?.kind, mounted ? .mountPoint : .directory)
            XCTAssertEqual(nodes.contains { $0.name == "payload" }, !mounted)
        }
    }

    func testMountTableFailureStopsBeforeEnumerationAndLeavesCacheUntouched() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(repeating: 1, count: 4_096).write(to: root.appending(path: "payload"))
        let source = ScanSource(kind: .folder, rootURL: root)
        let cache = InMemoryScanCache()
        let previous = try await FileTreeScanner().scan(source: source, request: ScanRequest(rootURL: root, sourceID: source.id))
        _ = await cache.store(previous)
        weak var releasedCandidate: ScanTreeStore?
        do {
            let candidate = ScanTreeStore()
            releasedCandidate = candidate
            let scanner = FileTreeScanner(tree: candidate, readMountPoints: { throw ScanMountTableError.unavailable(EIO) })
            do {
                let result = try await scanner.scan(source: source, request: ScanRequest(rootURL: root, sourceID: source.id))
                _ = await cache.store(result)
                XCTFail("A missing mount table must fail, not silently scan by device ID alone")
            } catch ScanMountTableError.unavailable(let code) {
                XCTAssertEqual(code, EIO)
            }
            let nodes = await candidate.allNodes()
            XCTAssertEqual(nodes.count, 1)
        }
        let cached = await cache.result(for: source)
        XCTAssertTrue(cached?.snapshot === previous.snapshot)
        XCTAssertNil(releasedCandidate)
    }

    func testConcurrentSystemMountReadsIncludeRootAndHiddenDataMount() async throws {
        try await withThrowingTaskGroup(of: ScanMountPoints.self) { group in
            for _ in 0..<16 { group.addTask { try ScanMountPoints.read() } }
            for try await mounts in group {
                XCTAssertTrue(mounts.contains(URL(fileURLWithPath: "/")))
                if FileManager.default.fileExists(atPath: "/System/Volumes/Data") {
                    XCTAssertTrue(mounts.contains(URL(fileURLWithPath: "/System/Volumes/Data/", isDirectory: true)))
                }
            }
        }
    }

    func testSystemDataEntryIsBoundaryWithoutScanningItsContents() async throws {
        let volumes = URL(fileURLWithPath: "/System/Volumes", isDirectory: true)
        guard FileManager.default.fileExists(atPath: volumes.path) else { throw XCTSkip("No system volume layout") }
        var rootInfo = stat()
        XCTAssertEqual(lstat("/", &rootInfo), 0)
        let mounts = try ScanMountPoints.read()
        let store = ScanTreeStore()
        let parentID = await store.begin(rootURL: volumes, kind: .directory)
        let items = try FileTreeScanner.directoryContents(at: volumes).compactMap { url -> DiscoveredItem? in
            var info = stat()
            guard lstat(url.path, &info) == 0 else { return nil }
            return .item(url, FileStatus(info: info))
        }
        let work = await store.apply(items: items, to: parentID, expectedDevice: Int64(rootInfo.st_dev),
                                     childDepth: 1, mountPoints: mounts)
        let page = await store.page(parentID: parentID, offset: 0, limit: 250)
        let data = try XCTUnwrap(page.nodes.first { $0.name == "Data" })
        XCTAssertEqual(data.kind, .mountPoint)
        XCTAssertEqual(data.allocatedSize, 0)
        XCTAssertFalse(work.contains { $0.nodeID == data.id })
        XCTAssertFalse(page.estimatingNodeIDs.contains(data.id))
        XCTAssertFalse(page.pendingNodeIDs.contains(data.id))
    }

    func testRootListingRetainsEveryReadableEntryWithoutTraversingBoundaries() async throws {
        let rootURL = URL(fileURLWithPath: "/", isDirectory: true)
        var rootInfo = stat()
        XCTAssertEqual(lstat(rootURL.path, &rootInfo), 0)
        let rootStatus = FileStatus(info: rootInfo)
        let mounts = try ScanMountPoints.read()
        let store = ScanTreeStore()
        let rootID = await store.begin(rootURL: rootURL, kind: .directory)
        let children = try FileTreeScanner.directoryContents(at: rootURL)
        var items: [DiscoveredItem] = []
        var expectedKinds: [String: ScanNodeKind] = [:]
        for url in children {
            var info = stat()
            guard lstat(url.path, &info) == 0 else { continue }
            let status = FileStatus(info: info)
            items.append(.item(url, status))
            expectedKinds[url.lastPathComponent] = status.isSymbolicLink ? .symbolicLink
                : status.deviceID != rootStatus.deviceID || (status.isDirectory && mounts.contains(url)) ? .mountPoint
                : status.isDirectory ? .directory : .file
        }
        // Only inspect the root level; never execute the returned directory work.
        let work = await store.apply(items: items, to: rootID, expectedDevice: rootStatus.deviceID, childDepth: 1, mountPoints: mounts)
        let page = await store.page(parentID: rootID, offset: 0, limit: max(1, children.count))
        XCTAssertEqual(page.nodes.count, expectedKinds.count)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: page.nodes.map { ($0.name, $0.kind) }), expectedKinds)
        XCTAssertEqual(Set(work.map { $0.url.lastPathComponent }), Set(expectedKinds.filter { $0.value == .directory }.keys))
        for node in page.nodes where node.kind == .symbolicLink || node.kind == .mountPoint {
            XCTAssertEqual(node.allocatedSize, 0)
            XCTAssertFalse(page.pendingNodeIDs.contains(node.id))
            XCTAssertFalse(page.estimatingNodeIDs.contains(node.id))
        }
    }

    func testNoFollowEnumerationDoesNotAliasRootWithDirectoryHint() throws {
        let url = URL(fileURLWithPath: "/.nofollow", isDirectory: true)
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            throw XCTSkip("This macOS installation has no /.nofollow entry")
        }
        // Check only one directory level: a regression must not recursively scan /.
        XCTAssertTrue(url.hasDirectoryPath)
        let children = try FileTreeScanner.directoryContents(at: url)
        XCTAssertTrue(children.isEmpty, "The literal /.nofollow directory must not contain a second root tree")
        let withoutHint = URL(fileURLWithPath: url.path, isDirectory: false)
        XCTAssertEqual(try FileTreeScanner.directoryContents(at: withoutHint), children)
    }

    func testScannerRetainsOrdinaryNoFollowNamedDirectoriesAndParentIDs() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appending(path: ".nofollow", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 4_096).write(to: nested.appending(path: "payload"))
        let source = ScanSource(kind: .folder, rootURL: root)

        let result = try await FileTreeScanner().scan(source: source, request: ScanRequest(rootURL: root, sourceID: source.id))
        let nodes = await result.allNodes()
        let rootValue = await result.snapshot.rootNode()
        let rootNode = try XCTUnwrap(rootValue)
        let nestedNode = try XCTUnwrap(nodes.first { $0.name == ".nofollow" })
        let file = try XCTUnwrap(nodes.first { $0.name == "payload" })
        XCTAssertEqual(result.status, .complete)
        XCTAssertEqual(nodes.count, 3)
        XCTAssertEqual(nestedNode.parentID, rootNode.id)
        XCTAssertEqual(file.parentID, nestedNode.id)
        XCTAssertEqual(file.url.path, nested.appending(path: "payload").path)
        XCTAssertEqual(rootNode.allocatedSize, file.allocatedSize)
        XCTAssertEqual(nestedNode.allocatedSize, file.allocatedSize)
        let rootPage = await result.snapshot.page(parentID: rootNode.id, offset: 0, limit: 250)
        let childPage = await result.snapshot.page(parentID: nestedNode.id, offset: 0, limit: 250)
        XCTAssertEqual(rootPage.nodes.map(\.id), [nestedNode.id])
        XCTAssertEqual(childPage.nodes.map(\.id), [file.id])
    }

    func testScannerIncludesHiddenFilesAndPackageContentsWithoutPrefetch() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appending(path: "Sample.app", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 4_096).write(to: root.appending(path: ".hidden"))
        try Data(repeating: 2, count: 8_192).write(to: package.appending(path: "payload"))
        let source = ScanSource(kind: .folder, rootURL: root)

        let result = try await FileTreeScanner().scan(source: source, request: ScanRequest(rootURL: root, sourceID: source.id))
        let nodes = await result.allNodes()
        let rootNode = await result.snapshot.rootNode()
        XCTAssertEqual(result.status, .complete)
        XCTAssertEqual(nodes.count, 4)
        XCTAssertTrue(nodes.contains { $0.name == ".hidden" })
        XCTAssertTrue(nodes.contains { $0.name == "payload" })
        XCTAssertEqual(rootNode?.allocatedSize, nodes.filter { $0.kind == .file }.reduce(0) { $0 + $1.allocatedSize })
    }

    func testScannerAggregatesDirectoriesAndRetainsSymlinksWithoutFollowing() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appending(path: "nested", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(atPath: nested.appending(path: "large.bin").path, contents: Data(repeating: 7, count: 8_192)))
        XCTAssertEqual(symlink("nested", root.appending(path: "linked-nested").path), 0)
        XCTAssertEqual(symlink("missing", root.appending(path: "broken-link").path), 0)
        XCTAssertEqual(symlink(".", root.appending(path: "cycle-link").path), 0)

        let source = ScanSource(kind: .folder, rootURL: root)
        let result = try await FileTreeScanner().scan(source: source, request: ScanRequest(rootURL: root, sourceID: source.id))
        let nodes = await result.allNodes()
        let rootNodeValue = await result.snapshot.rootNode()

        XCTAssertEqual(result.status, .complete)
        XCTAssertEqual(nodes.count, 6)
        for name in ["linked-nested", "broken-link", "cycle-link"] {
            let node = try XCTUnwrap(nodes.first { $0.name == name })
            XCTAssertEqual(node.kind, .symbolicLink)
            XCTAssertEqual(node.allocatedSize, 0)
            XCTAssertFalse(node.isHardLink)
            XCTAssertFalse(nodes.contains { $0.parentID == node.id })
        }
        let rootNode = try XCTUnwrap(rootNodeValue)
        let nestedNode = try XCTUnwrap(nodes.first { $0.name == "nested" })
        XCTAssertEqual(rootNode.allocatedSize, nestedNode.allocatedSize)
    }

    func testScannerCountsEveryHardLinkPathButDeduplicatesSummary() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appending(path: "first.bin")
        let second = root.appending(path: "second.bin")
        XCTAssertTrue(FileManager.default.createFile(atPath: first.path, contents: Data(repeating: 3, count: 4_096)))
        XCTAssertEqual(link(first.path, second.path), 0)

        let source = ScanSource(kind: .folder, rootURL: root)
        let result = try await FileTreeScanner().scan(source: source, request: ScanRequest(rootURL: root, sourceID: source.id))
        let nodes = await result.allNodes()
        let rootNodeValue = await result.snapshot.rootNode()
        let rootNode = try XCTUnwrap(rootNodeValue)
        let linkedNodes = nodes.filter { $0.name == "first.bin" || $0.name == "second.bin" }

        XCTAssertEqual(linkedNodes.count, 2)
        XCTAssertEqual(linkedNodes.filter(\.isHardLink).count, 2)
        XCTAssertEqual(linkedNodes[0].allocatedSize, linkedNodes[1].allocatedSize)
        XCTAssertGreaterThan(linkedNodes[0].allocatedSize, 0)
        XCTAssertEqual(linkedNodes.map(\.allocatedSize).reduce(0, +), rootNode.allocatedSize)
        let summary = await result.snapshot.sizeSummary()
        XCTAssertEqual(summary.uniqueAllocatedSize, linkedNodes[0].allocatedSize)
        XCTAssertEqual(summary.contentAllocatedSize, summary.uniqueAllocatedSize * 2)
        XCTAssertFalse(summary.isScanning)
        XCTAssertFalse(summary.isIncomplete)
    }

    func testHardLinkedFileSelectedAsRootRetainsSizeAndMarker() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appending(path: "first")
        let second = directory.appending(path: "second")
        try Data(repeating: 1, count: 4_096).write(to: first)
        XCTAssertEqual(link(first.path, second.path), 0)
        let source = ScanSource(kind: .folder, rootURL: second)
        let result = try await FileTreeScanner().scan(source: source, request: ScanRequest(rootURL: second, sourceID: source.id))
        let root = await result.snapshot.rootNode()
        let summary = await result.snapshot.sizeSummary()
        XCTAssertEqual(root?.isHardLink, true)
        XCTAssertGreaterThan(summary.contentAllocatedSize, 0)
        XCTAssertEqual(summary.contentAllocatedSize, summary.uniqueAllocatedSize)
        XCTAssertEqual(result.nodeCount, 1)
        XCTAssertEqual(result.status, .complete)
    }

    func testCrossDirectoryHardLinksMatchStandaloneScan() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appending(path: "CocoaPods/TTVideoEditor")
        let project = root.appending(path: "Project/Pods")
        for directory in [cache, project] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let payload = cache.appending(path: "payload")
        try Data(repeating: 1, count: 4_096).write(to: payload)
        XCTAssertEqual(link(payload.path, project.appending(path: "payload").path), 0)
        var cacheSizes: [Int64] = []
        for selectedRoot in [root, cache] {
            let source = ScanSource(kind: .folder, rootURL: selectedRoot)
            let result = try await FileTreeScanner().scan(source: source, request: ScanRequest(rootURL: selectedRoot, sourceID: source.id))
            let nodes = await result.allNodes()
            let cacheNode = try XCTUnwrap(nodes.first { $0.url.path == cache.path })
            cacheSizes.append(cacheNode.allocatedSize)
            let summary = await result.snapshot.sizeSummary()
            XCTAssertEqual(summary.uniqueAllocatedSize, cacheNode.allocatedSize)
            XCTAssertEqual(summary.contentAllocatedSize, cacheNode.allocatedSize * (selectedRoot == root ? 2 : 1))
            XCTAssertEqual(result.status, .complete)
        }
        XCTAssertGreaterThan(cacheSizes[0], 0)
        XCTAssertEqual(cacheSizes[0], cacheSizes[1])
    }

    func testScannerMarksMissingRootIncomplete() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: UUID().uuidString)
        let source = ScanSource(kind: .folder, rootURL: root)

        let result = try await FileTreeScanner().scan(source: source, request: ScanRequest(rootURL: root, sourceID: source.id))
        let rootNode = await result.snapshot.rootNode()

        XCTAssertEqual(result.status, .incomplete([.sourceUnavailable]))
        XCTAssertTrue(try XCTUnwrap(rootNode).isIncomplete)
    }

    func testScannerKeepsAccessibleSiblingsWhenDirectoryIsUnreadable() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let blocked = root.appending(path: "blocked", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(atPath: root.appending(path: "visible.bin").path, contents: Data(repeating: 1, count: 512)))
        XCTAssertEqual(chmod(blocked.path, 0), 0)
        defer { _ = chmod(blocked.path, S_IRWXU) }

        let source = ScanSource(kind: .folder, rootURL: root)
        let result = try await FileTreeScanner().scan(source: source, request: ScanRequest(rootURL: root, sourceID: source.id))
        let nodes = await result.allNodes()

        XCTAssertTrue(nodes.contains { $0.name == "visible.bin" })
        XCTAssertEqual(result.status, .incomplete([.unreadableItem]))
    }

    func testScannerPublishesIncrementalNodesAndCompletedDirectories() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appending(path: "nested", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(atPath: nested.appending(path: "item.bin").path, contents: Data(repeating: 4, count: 2_048)))

        let source = ScanSource(kind: .folder, rootURL: root)
        let collector = ScanProgressCollector()
        let result = try await FileTreeScanner().scan(
            source: source,
            request: ScanRequest(rootURL: root, sourceID: source.id),
            progress: { progress in await collector.append(progress) }
        )

        let progress = await collector.values()
        let rootNodeValue = await result.snapshot.rootNode()
        let rootNode = try XCTUnwrap(rootNodeValue)
        XCTAssertTrue(progress.contains { !$0.changedParentIDs.isEmpty })
        XCTAssertTrue(progress.contains { $0.completedDirectoryIDs.contains(rootNode.id) })
        XCTAssertTrue(progress.allSatisfy { $0.completedDirectoryCount <= 2 })
    }

    @MainActor
    func testRootRowsReachBrowserBeforeDescendantsAreScanned() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["first", "second"] {
            let directory = root.appending(path: name, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(repeating: 1, count: 4_096).write(to: directory.appending(path: "payload"))
        }
        try Data(repeating: 2, count: 4_096).write(to: root.appending(path: "root-file"))
        let source = ScanSource(kind: .folder, rootURL: root)
        let tree = ScanTreeStore()
        let displayed = DisplayedScanSnapshot()
        await displayed.set(tree)
        let browser = ResultBrowserModel(source: source, columnLoader: InMemorySnapshotColumnLoader(displayedSnapshot: displayed))
        await browser.loadInitialColumn()
        let columns = RootColumnCollector()

        let result = try await FileTreeScanner(tree: tree).scan(
            source: source, request: ScanRequest(rootURL: root, sourceID: source.id),
            progress: { progress in
                await browser.refreshVisibleColumns(for: progress)
                if let column = await browser.columns.first {
                    await columns.append(column)
                }
            }
        )

        let publications = await columns.values()
        let first = try XCTUnwrap(publications.first { !$0.nodes.isEmpty })
        XCTAssertEqual(Set(first.nodes.map(\.name)), ["first", "second", "root-file"])
        let directories = first.nodes.filter { $0.kind == .directory }
        XCTAssertEqual(first.pendingNodeIDs, Set(directories.map(\.id)))
        XCTAssertTrue(directories.allSatisfy { $0.allocatedSize == 0 })
        XCTAssertEqual(first.state, .partial)
        XCTAssertFalse(first.showsEmptyFolder)
        XCTAssertEqual(first.nodes.first?.name, "root-file")
        XCTAssertEqual(first.sizeSummary?.isScanning, true)
        XCTAssertTrue(result.snapshot === tree)
        XCTAssertEqual(result.nodeCount, 6)
        XCTAssertEqual(result.status, .complete)
        await browser.refreshAllColumns()
        XCTAssertTrue(browser.columns[0].pendingNodeIDs.isEmpty)
        XCTAssertTrue(browser.columns[0].nodes.filter { $0.kind == .directory }.allSatisfy { $0.allocatedSize > 0 })
    }

    func testEmptyRootIsPublishedAsConfirmedEmptyWithoutWaitingForSizing() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = ScanSource(kind: .folder, rootURL: root)
        let tree = ScanTreeStore()
        let displayed = DisplayedScanSnapshot()
        await displayed.set(tree)
        let loader = InMemorySnapshotColumnLoader(displayedSnapshot: displayed)
        let columns = RootColumnCollector()
        _ = try await FileTreeScanner(tree: tree).scan(
            source: source, request: ScanRequest(rootURL: root, sourceID: source.id),
            progress: { _ in
                if let column = try? await loader.loadColumn(for: source, parent: nil, offset: 0, limit: 250) {
                    await columns.append(column)
                }
            }
        )
        let publications = await columns.values()
        let first = try XCTUnwrap(publications.first)
        XCTAssertTrue(first.showsEmptyFolder)
        XCTAssertEqual(first.sizeSummary?.isScanning, true)
    }

    func testScannerAggregatesDeepDirectoriesOncePerLevel() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appending(path: "first", directoryHint: .isDirectory)
        let second = first.appending(path: "second", directoryHint: .isDirectory)
        let third = second.appending(path: "third", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: third, withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(atPath: root.appending(path: "root.bin").path, contents: Data(repeating: 1, count: 4_096)))
        XCTAssertTrue(FileManager.default.createFile(atPath: third.appending(path: "leaf.bin").path, contents: Data(repeating: 2, count: 8_192)))

        let source = ScanSource(kind: .folder, rootURL: root)
        let result = try await FileTreeScanner().scan(source: source, request: ScanRequest(rootURL: root, sourceID: source.id))
        let nodes = await result.allNodes()
        let rootNodeValue = await result.snapshot.rootNode()
        let rootNode = try XCTUnwrap(rootNodeValue)
        let firstNode = try XCTUnwrap(nodes.first { $0.name == "first" })
        let secondNode = try XCTUnwrap(nodes.first { $0.name == "second" })
        let thirdNode = try XCTUnwrap(nodes.first { $0.name == "third" })
        let rootFile = try XCTUnwrap(nodes.first { $0.name == "root.bin" })
        let leafFile = try XCTUnwrap(nodes.first { $0.name == "leaf.bin" })

        XCTAssertEqual(thirdNode.allocatedSize, leafFile.allocatedSize)
        XCTAssertEqual(secondNode.allocatedSize, thirdNode.allocatedSize)
        XCTAssertEqual(firstNode.allocatedSize, secondNode.allocatedSize)
        XCTAssertEqual(rootNode.allocatedSize, rootFile.allocatedSize + firstNode.allocatedSize)
    }

    func testImmediatelyCancelledScanReturnsIncompletePartialTree() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appending(path: "nested", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(atPath: nested.appending(path: "item.bin").path, contents: Data(repeating: 3, count: 4_096)))

        let source = ScanSource(kind: .folder, rootURL: root)
        let task = Task {
            try await FileTreeScanner().scan(source: source, request: ScanRequest(rootURL: root, sourceID: source.id))
        }
        task.cancel()
        let result = try await task.value

        guard case let .incomplete(reasons) = result.status else {
            return XCTFail("Expected cancellation to keep an incomplete result")
        }
        XCTAssertTrue(reasons.contains(.cancelled))
        let rootNode = await result.snapshot.rootNode()
        XCTAssertTrue(try XCTUnwrap(rootNode).isIncomplete)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "ClearXTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

final class DirectoryWorkQueueTests: XCTestCase {
    func testQueueNormalizesWorkOnceAndMatchesFocusedPathComponents() async {
        let sourceID = ScanSourceID()
        let coordinator = ScanCoordinator()
        let queue = DirectoryWorkQueue(sourceID: sourceID, coordinator: coordinator)
        let root = URL(fileURLWithPath: "/tmp/clearx-normalization")
        let background = DirectoryWork(nodeID: ScanNodeID(), url: root.appending(path: "focus-other"), depth: 1)
        let focused = DirectoryWork(nodeID: ScanNodeID(), url: root.appending(path: "unused/../focus/child"), depth: 2)
        await coordinator.prioritize(directory: root.appending(path: "another/../focus"), for: sourceID)
        await queue.enqueue([background, focused])

        let first = await queue.next()
        await queue.completeCurrentWork()
        let second = await queue.next()
        await queue.completeCurrentWork()
        let end = await queue.next()
        XCTAssertEqual(first?.nodeID, focused.nodeID)
        XCTAssertEqual(first?.url, root.appending(path: "focus/child"))
        XCTAssertEqual(second?.nodeID, background.nodeID)
        XCTAssertNil(end)
    }

    func testPerformanceMetricsMergeStageTotalsAndSlowestSamples() {
        var first = ScanWorkerPerformanceMetrics(workerID: 0, startedAtNanos: 1)
        first.recordEnumeration(
            DirectoryEnumerationPerformanceSample(childCount: 10, listingNanos: 20, metadataNanos: 30, isUnreadable: false),
            depth: 2,
            permitAndEnumerationNanos: 80
        )
        first.recordAccumulatorApply(nanos: 40, depth: 2, childCount: 10)
        var second = ScanWorkerPerformanceMetrics(workerID: 1, startedAtNanos: 1)
        second.recordEnumeration(
            DirectoryEnumerationPerformanceSample(childCount: 3, listingNanos: 50, metadataNanos: 60, isUnreadable: true),
            depth: 4,
            permitAndEnumerationNanos: 150
        )
        second.recordAccumulatorApply(nanos: 70, depth: 4, childCount: 3)

        first.merge(second)

        XCTAssertEqual(first.directoryCount, 2)
        XCTAssertEqual(first.discoveredItemCount, 13)
        XCTAssertEqual(first.unreadableDirectoryCount, 1)
        XCTAssertEqual(first.listingNanos, 70)
        XCTAssertEqual(first.metadataNanos, 90)
        XCTAssertEqual(first.permitWaitNanos, 70)
        XCTAssertEqual(first.accumulatorApplyNanos, 110)
        XCTAssertEqual(first.slowestEnumeration.depth, 4)
        XCTAssertEqual(first.slowestAccumulatorApply.depth, 4)
    }

    func testRingFIFOUsesFIFOOrderAcrossWrapAndGrowth() {
        var queue = RingFIFO<Int>(minimumCapacity: 2)
        queue.append(1)
        queue.append(2)
        XCTAssertEqual(queue.popFirst(), 1)
        queue.append(3)
        queue.append(4)

        XCTAssertEqual(queue.popFirst(), 2)
        XCTAssertEqual(queue.popFirst(), 3)
        XCTAssertEqual(queue.popFirst(), 4)
        XCTAssertNil(queue.popFirst())
    }

    func testFocusChangeLazilyPromotesExactQueuedDirectory() async {
        let sourceID = ScanSourceID()
        let coordinator = ScanCoordinator()
        let queue = DirectoryWorkQueue(sourceID: sourceID, coordinator: coordinator)
        let root = URL(fileURLWithPath: "/tmp/clearx-queue")
        let first = DirectoryWork(nodeID: ScanNodeID(), url: root.appending(path: "first"), depth: 1)
        let focused = DirectoryWork(nodeID: ScanNodeID(), url: root.appending(path: "focused"), depth: 1)
        await queue.enqueue([first, focused])

        await coordinator.prioritize(directory: focused.url, for: sourceID)

        let promotedWork = await queue.next()
        XCTAssertEqual(promotedWork?.nodeID, focused.nodeID)
        await queue.completeCurrentWork()
        let remainingWork = await queue.next()
        XCTAssertEqual(remainingWork?.nodeID, first.nodeID)
        await queue.completeCurrentWork()
        let performance = await queue.performanceSnapshot()
        XCTAssertEqual(performance.enqueuedCount, 2)
        XCTAssertEqual(performance.dequeuedCount, 2)
        XCTAssertEqual(performance.peakPendingCount, 2)
        XCTAssertEqual(performance.focusPromotionCount, 1)
        XCTAssertEqual(performance.staleEntryCount, 1)
    }

    func testNewFocusRunsBeforeRetiredFocusWithoutDroppingOldWork() async {
        let sourceID = ScanSourceID()
        let coordinator = ScanCoordinator()
        let queue = DirectoryWorkQueue(sourceID: sourceID, coordinator: coordinator)
        let root = URL(fileURLWithPath: "/tmp/clearx-focus-switch")
        let oldFocusRoot = root.appending(path: "old")
        let oldFocusedWork = DirectoryWork(nodeID: ScanNodeID(), url: oldFocusRoot.appending(path: "child"), depth: 2)
        let newFocusedWork = DirectoryWork(nodeID: ScanNodeID(), url: root.appending(path: "new"), depth: 1)
        await coordinator.prioritize(directory: oldFocusRoot, for: sourceID)
        await queue.enqueue([oldFocusedWork, newFocusedWork])

        await coordinator.prioritize(directory: newFocusedWork.url, for: sourceID)

        let promotedWork = await queue.next()
        XCTAssertEqual(promotedWork?.nodeID, newFocusedWork.nodeID)
        await queue.completeCurrentWork()
        let retiredWork = await queue.next()
        XCTAssertEqual(retiredWork?.nodeID, oldFocusedWork.nodeID)
        await queue.completeCurrentWork()
    }

    func testFocusedQueueYieldsToBackgroundAfterEightTasks() async {
        let sourceID = ScanSourceID()
        let coordinator = ScanCoordinator()
        let queue = DirectoryWorkQueue(sourceID: sourceID, coordinator: coordinator)
        let root = URL(fileURLWithPath: "/tmp/clearx-fairness")
        let focusRoot = root.appending(path: "focus")
        await coordinator.prioritize(directory: focusRoot, for: sourceID)
        let focused = (0..<9).map {
            DirectoryWork(nodeID: ScanNodeID(), url: focusRoot.appending(path: "child-\($0)"), depth: 2)
        }
        let background = DirectoryWork(nodeID: ScanNodeID(), url: root.appending(path: "background"), depth: 1)
        await queue.enqueue(focused + [background])

        var dequeued = [ScanNodeID]()
        for _ in 0..<9 {
            if let work = await queue.next() {
                dequeued.append(work.nodeID)
                await queue.completeCurrentWork()
            }
        }

        XCTAssertEqual(Array(dequeued.prefix(8)), focused.prefix(8).map(\.nodeID))
        XCTAssertEqual(dequeued[8], background.nodeID)
    }

    func testConcurrentWorkerCompletionDoesNotDoubleResumeWaitingWorkers() async {
        let sourceID = ScanSourceID()
        let queue = DirectoryWorkQueue(sourceID: sourceID, coordinator: ScanCoordinator())
        let root = URL(fileURLWithPath: "/tmp/clearx-waiter-stress")
        let initial = DirectoryWork(nodeID: ScanNodeID(), url: root, depth: 0)
        await queue.enqueue([initial])
        let initialWork = await queue.next()
        XCTAssertEqual(initialWork?.nodeID, initial.nodeID)

        let workers = (0..<8).map { _ in
            Task {
                var processed = 0
                while await queue.next() != nil {
                    processed += 1
                    await queue.completeCurrentWork()
                }
                return processed
            }
        }
        for _ in 0..<16 {
            await Task.yield()
        }

        let work = (0..<512).map { index in
            DirectoryWork(
                nodeID: ScanNodeID(),
                url: root.appending(path: "child-\(index)"),
                depth: 1
            )
        }
        await queue.enqueue(work)
        await queue.completeCurrentWork()

        var processed = 0
        for worker in workers {
            processed += await worker.value
        }
        XCTAssertEqual(processed, work.count)
        let performance = await queue.performanceSnapshot()
        XCTAssertEqual(performance.dequeuedCount, work.count + 1)
    }

    func testProgressPublisherPullsPeriodicSnapshotsAndPublishesFinalImmediately() async throws {
        let collector = ScanProgressCollector()
        let first = ScanProgress(discoveredNodeCount: 1, completedDirectoryCount: 0, currentURL: nil)
        let second = ScanProgress(discoveredNodeCount: 2, completedDirectoryCount: 1, currentURL: nil)
        let final = ScanProgress(discoveredNodeCount: 3, completedDirectoryCount: 2, currentURL: nil)
        let source = ScanProgressSource(first)
        let publisher = ProgressPublisher(
            publicationInterval: .milliseconds(10),
            snapshot: { await source.value() },
            sink: { progress in await collector.append(progress) }
        )

        await publisher.publish()
        let leadingValues = await collector.values()
        XCTAssertEqual(leadingValues.map(\.discoveredNodeCount), [1])

        await source.set(second)
        let periodicTask = Task { await publisher.publishPeriodically() }
        try await Task.sleep(for: .milliseconds(30))
        periodicTask.cancel()
        await periodicTask.value

        await source.set(final)
        await publisher.publish()
        let values = await collector.values()
        XCTAssertTrue(values.dropFirst().dropLast().contains { $0.discoveredNodeCount == 2 })
        XCTAssertEqual(values.last?.discoveredNodeCount, 3)
    }
}

private actor ScanProgressSource {
    private var progress: ScanProgress

    init(_ progress: ScanProgress) {
        self.progress = progress
    }

    func set(_ progress: ScanProgress) {
        self.progress = progress
    }

    func value() -> ScanProgress {
        progress
    }
}

private actor ScanProgressCollector {
    private var progress = [ScanProgress]()

    func append(_ value: ScanProgress) {
        progress.append(value)
    }

    func values() -> [ScanProgress] {
        progress
    }
}

private actor RootColumnCollector {
    private var columns: [SnapshotBrowserColumn] = []

    func append(_ column: SnapshotBrowserColumn) {
        columns.append(column)
    }

    func values() -> [SnapshotBrowserColumn] { columns }
}
