import Darwin
import XCTest
@testable import ClearX

final class ScanTreeStoreTests: XCTestCase {
    func testSameDeviceMountIsExcludedWithoutChangingCompletionOrAggregation() async throws {
        let store = ScanTreeStore()
        let rootURL = URL(fileURLWithPath: "/fixture")
        let rootID = await store.begin(rootURL: rootURL, kind: .directory)
        let mounts = ScanMountPoints(urls: [rootURL, rootURL.appending(path: "Data/"), rootURL.appending(path: "link")])
        let work = await store.apply(items: [
            .item(rootURL.appending(path: "Data"), status(inode: 1, blocks: 32, directory: true)),
            .item(rootURL.appending(path: "Data-other"), status(inode: 2, directory: true)),
            .item(rootURL.appending(path: "link"), status(inode: 3, symbolicLink: true)),
            .item(rootURL.appending(path: "visible"), status(inode: 4, blocks: 8))
        ], to: rootID, expectedDevice: 1, childDepth: 1, mountPoints: mounts)
        XCTAssertEqual(work.map { $0.url.lastPathComponent }, ["Data-other"])
        await store.finishEnumeratingDirectory(rootID)
        let child = try XCTUnwrap(work.first)
        _ = await store.apply(items: [
            .item(child.url.appending(path: "payload"), status(inode: 5, blocks: 16))
        ], to: child.nodeID, expectedDevice: 1, childDepth: 2, mountPoints: mounts)
        await store.finishEnumeratingDirectory(child.nodeID)

        let page = await store.page(parentID: rootID, offset: 0, limit: 250)
        let mount = try XCTUnwrap(page.nodes.first { $0.name == "Data" })
        let root = await store.rootNode()
        let mountPage = await store.page(parentID: mount.id, offset: 0, limit: 250)
        let completion = await store.finishScan()
        XCTAssertEqual(mount.kind, .mountPoint)
        XCTAssertEqual(mount.allocatedSize, 0)
        XCTAssertFalse(mount.isHardLink)
        XCTAssertFalse(mount.isIncomplete)
        XCTAssertTrue(mountPage.nodes.isEmpty)
        XCTAssertEqual(page.nodes.first { $0.name == "link" }?.kind, .symbolicLink)
        XCTAssertEqual(page.nodes.map(\.name), ["Data-other", "visible", "Data", "link"])
        XCTAssertEqual(root?.allocatedSize, 12_288)
        XCTAssertEqual(page.state, .complete)
        XCTAssertTrue(page.pendingNodeIDs.isEmpty)
        XCTAssertTrue(page.estimatingNodeIDs.isEmpty)
        XCTAssertEqual(completion.status, .complete)
    }

    func testTraversalBoundariesRemainVisibleWithoutWorkOrSize() async throws {
        let store = ScanTreeStore()
        let rootURL = URL(fileURLWithPath: "/tmp/clearx-boundaries")
        let rootID = await store.begin(rootURL: rootURL, kind: .directory)
        let work = await store.apply(items: [
            .item(rootURL.appending(path: "mount"), status(inode: 1, device: 2, blocks: 16, directory: true)),
            .item(rootURL.appending(path: "link"), status(inode: 2, blocks: 8, symbolicLink: true))
        ], to: rootID, expectedDevice: 1, childDepth: 1)
        await store.finishEnumeratingDirectory(rootID)
        let page = await store.page(parentID: rootID, offset: 0, limit: 250)
        let root = await store.rootNode()
        let completion = await store.finishScan()

        XCTAssertTrue(work.isEmpty)
        XCTAssertEqual(page.nodes.map(\.name), ["link", "mount"])
        XCTAssertEqual(page.nodes.map(\.kind), [.symbolicLink, .mountPoint])
        XCTAssertTrue(page.nodes.allSatisfy { $0.parentID == rootID && $0.allocatedSize == 0 && !$0.isHardLink && !$0.isIncomplete })
        XCTAssertTrue(page.estimatingNodeIDs.isEmpty)
        XCTAssertTrue(page.pendingNodeIDs.isEmpty)
        XCTAssertEqual(page.state, .complete)
        XCTAssertEqual(root?.allocatedSize, 0)
        XCTAssertEqual(completion.status, .complete)
        XCTAssertEqual(completion.nodeCount, 3)
    }

    func testBatchTotalsPreservePendingDirectoryCompletion() async throws {
        let store = ScanTreeStore()
        let rootURL = URL(fileURLWithPath: "/tmp/clearx-batch")
        let rootID = await store.begin(rootURL: rootURL, kind: .directory)
        let work = await store.apply(items: [
            .item(rootURL.appending(path: "nested"), status(inode: 1, directory: true)),
            .item(rootURL.appending(path: "file"), status(inode: 2, blocks: 8)),
            .item(rootURL.appending(path: "empty"), status(inode: 3))
        ], to: rootID, expectedDevice: 1, childDepth: 1)
        await store.finishEnumeratingDirectory(rootID)
        let partialPage = await store.page(parentID: rootID, offset: 0, limit: 250)
        let partialRoot = await store.rootNode()
        XCTAssertEqual(partialRoot?.allocatedSize, 4_096)
        XCTAssertEqual(partialPage.state, .partial)
        XCTAssertEqual(partialPage.nodes.map(\.name), ["file", "empty", "nested"])

        let child = try XCTUnwrap(work.first)
        _ = await store.apply(items: [
            .item(child.url.appending(path: "leaf"), status(inode: 4, blocks: 16))
        ], to: child.nodeID, expectedDevice: 1, childDepth: 2)
        await store.finishEnumeratingDirectory(child.nodeID)
        let completedRoot = await store.rootNode()
        let completePage = await store.page(parentID: rootID, offset: 0, limit: 250)
        let completion = await store.finishScan()
        XCTAssertEqual(completedRoot?.allocatedSize, 12_288)
        XCTAssertEqual(completePage.state, .complete)
        XCTAssertEqual(completePage.nodes.map(\.name), ["nested", "file", "empty"])
        XCTAssertEqual(completion.status, .complete)
        XCTAssertEqual(completion.nodeCount, 5)
    }

    func testBatchTotalsKeepHardLinkDeduplicationAndIncompleteState() async throws {
        let store = ScanTreeStore()
        let rootURL = URL(fileURLWithPath: "/tmp/clearx-batch-links")
        let rootID = await store.begin(rootURL: rootURL, kind: .directory)
        _ = await store.apply(items: [
            .item(rootURL.appending(path: "first"), status(inode: 1, blocks: 8, links: 2))
        ], to: rootID, expectedDevice: 1, childDepth: 1)
        _ = await store.apply(items: [
            .unreadableItem,
            .item(rootURL.appending(path: "second"), status(inode: 1, blocks: 8, links: 2)),
            .item(rootURL.appending(path: "other"), status(inode: 2, blocks: 16)),
            .item(rootURL.appending(path: "mount"), status(inode: 3, device: 2, directory: true)),
            .item(rootURL.appending(path: "symlink"), status(inode: 4, symbolicLink: true))
        ], to: rootID, expectedDevice: 1, childDepth: 1)
        await store.finishEnumeratingDirectory(rootID)
        let root = await store.rootNode()
        let nodes = await store.allNodes()
        let completion = await store.finishScan()
        XCTAssertEqual(root?.allocatedSize, 16_384)
        XCTAssertEqual(root?.isIncomplete, true)
        XCTAssertEqual(nodes.count, 6)
        XCTAssertEqual(nodes.first { $0.name == "mount" }?.kind, .mountPoint)
        XCTAssertEqual(nodes.first { $0.name == "symlink" }?.kind, .symbolicLink)
        XCTAssertEqual(nodes.first { $0.name == "first" }?.isHardLink, true)
        XCTAssertEqual(nodes.first { $0.name == "second" }?.isHardLink, true)
        XCTAssertEqual(nodes.first { $0.name == "second" }?.allocatedSize, 4_096)
        let summary = await store.sizeSummary()
        XCTAssertEqual(summary.uniqueAllocatedSize, 12_288)
        XCTAssertEqual(summary.contentAllocatedSize, 16_384)
        XCTAssertTrue(summary.isIncomplete)
        XCTAssertFalse(summary.isScanning)
        XCTAssertEqual(completion.status, .incomplete([.unreadableItem]))
    }

    func testHardLinkOrderDoesNotChangeDirectoryTotalsOrSortedPrefixes() async throws {
        for reversed in [false, true] {
            let store = ScanTreeStore()
            let rootURL = URL(fileURLWithPath: "/fixture")
            let rootID = await store.begin(rootURL: rootURL, kind: .directory)
            let work = await store.apply(items: [
                .item(rootURL.appending(path: "CocoaPods"), status(inode: 1, directory: true)),
                .item(rootURL.appending(path: "Project"), status(inode: 2, directory: true))
            ], to: rootID, expectedDevice: 1, childDepth: 1)
            let ordered = reversed ? Array(work.reversed()) : work
            await store.finishEnumeratingDirectory(rootID)
            _ = await store.takeProgress()
            for (index, directory) in ordered.enumerated() {
                _ = await store.apply(items: [
                    .item(directory.url.appending(path: "library"), status(inode: 100, blocks: 8, links: 2))
                ], to: directory.nodeID, expectedDevice: 1, childDepth: 2)
                let page = await store.page(parentID: rootID, offset: 0, limit: index + 1)
                XCTAssertEqual(page.sizeSummary?.contentAllocatedSize, Int64(index + 1) * 4_096)
                XCTAssertEqual(page.sizeSummary?.uniqueAllocatedSize, 4_096)
                XCTAssertEqual(page.sizeSummary?.isScanning, true)
                let progress = await store.takeProgress()
                XCTAssertTrue(progress.changedParentIDs.contains(rootID))
                await store.finishEnumeratingDirectory(directory.nodeID)
            }
            _ = await store.finishScan()
            let prefix = await store.page(parentID: rootID, offset: 0, limit: 2)
            XCTAssertEqual(prefix.nodes.map(\.name), ["CocoaPods", "Project"])
            XCTAssertEqual(prefix.nodes.map(\.allocatedSize), [4_096, 4_096])
            XCTAssertEqual(Set(prefix.nodes.map(\.id)).count, 2)
            XCTAssertEqual(prefix.sizeSummary?.contentAllocatedSize, 8_192)
            XCTAssertEqual(prefix.sizeSummary?.uniqueAllocatedSize, 4_096)
            XCTAssertEqual(prefix.sizeSummary?.isScanning, false)
            XCTAssertEqual(prefix.sizeSummary?.isIncomplete, false)
            let childPage = await store.page(parentID: work[0].nodeID, offset: 0, limit: 250)
            XCTAssertNil(childPage.sizeSummary)
        }
    }

    func testDifferentObjectsAreNotDeduplicatedAndCancellationPreservesSummary() async {
        let store = ScanTreeStore()
        let url = URL(fileURLWithPath: "/fixture")
        let root = await store.begin(rootURL: url, kind: .directory)
        _ = await store.apply(items: [
            .item(url.appending(path: "original"), status(inode: 1, blocks: 8)),
            .item(url.appending(path: "clone"), status(inode: 2, blocks: 8)),
            .item(url.appending(path: "link-a"), status(inode: 3, blocks: 8, links: 2)),
            .item(url.appending(path: "link-b"), status(inode: 3, blocks: 8, links: 2))
        ], to: root, expectedDevice: 1, childDepth: 1)
        await store.markCancelled()
        await store.finalizeCancelledDirectories()
        _ = await store.finishScan()
        let before = await store.sizeSummary()
        XCTAssertEqual(before.contentAllocatedSize, 16_384)
        XCTAssertEqual(before.uniqueAllocatedSize, 12_288)
        XCTAssertTrue(before.isIncomplete)
        XCTAssertFalse(before.isScanning)
        _ = await store.apply(items: [.item(url.appending(path: "late"), status(inode: 4, blocks: 8))],
                              to: root, expectedDevice: 1, childDepth: 1)
        _ = await store.finishScan()
        let after = await store.sizeSummary()
        XCTAssertEqual(before, after)
    }

    func testCancelledBatchCommitsPartialDirectoryOnlyOnce() async throws {
        let store = ScanTreeStore()
        let rootURL = URL(fileURLWithPath: "/tmp/clearx-batch-cancel")
        let rootID = await store.begin(rootURL: rootURL, kind: .directory)
        let work = await store.apply(items: [
            .item(rootURL.appending(path: "nested"), status(inode: 1, directory: true)),
            .item(rootURL.appending(path: "file"), status(inode: 2, blocks: 8))
        ], to: rootID, expectedDevice: 1, childDepth: 1)
        let child = try XCTUnwrap(work.first)
        _ = await store.apply(items: [
            .item(child.url.appending(path: "leaf"), status(inode: 3, blocks: 16))
        ], to: child.nodeID, expectedDevice: 1, childDepth: 2)
        await store.finishEnumeratingDirectory(rootID)
        await store.markCancelled()
        await store.finalizeCancelledDirectories()
        await store.finalizeCancelledDirectories()
        let root = await store.rootNode()
        let completion = await store.finishScan()
        XCTAssertEqual(root?.allocatedSize, 12_288)
        XCTAssertEqual(root?.isIncomplete, true)
        XCTAssertEqual(completion.status, .incomplete([.cancelled]))
    }

    func testCompleteSnapshotPagesChildrenInDeterministicOrder() async throws {
        let root = makeNode(name: "root", kind: .directory, size: 60)
        let small = makeNode(name: "small", parentID: root.id, size: 10)
        let sameSizeB = makeNode(name: "B", parentID: root.id, size: 20)
        let sameSizeA = makeNode(name: "A", parentID: root.id, size: 20)
        let large = makeNode(name: "large", parentID: root.id, size: 30)
        let store = ScanTreeStore(snapshotNodes: [root, small, sameSizeB, sameSizeA, large], status: .complete)

        let firstPage = await store.page(parentID: root.id, offset: 0, limit: 2)
        let secondPage = await store.page(parentID: root.id, offset: 2, limit: 2)
        let indexedNode = await store.node(withID: sameSizeA.id)

        XCTAssertEqual(firstPage.totalCount, 4)
        XCTAssertEqual(firstPage.nodes.map(\.name), ["large", "A"])
        XCTAssertEqual(secondPage.nodes.map(\.name), ["B", "small"])
        XCTAssertEqual(Set(firstPage.nodes.map(\.id) + secondPage.nodes.map(\.id)).count, 4)
        XCTAssertEqual(firstPage.state, .complete)
        XCTAssertEqual(indexedNode, sameSizeA)
    }

    func testIncompleteSnapshotSortsByCurrentSizeWithoutEstimateMarkers() async {
        let root = makeNode(name: "root", kind: .directory, size: 30)
        let first = makeNode(name: "first", parentID: root.id, size: 10)
        let second = makeNode(name: "second", parentID: root.id, size: 20)
        let store = ScanTreeStore(snapshotNodes: [root, first, second], status: .incomplete([.cancelled]))

        let page = await store.page(parentID: root.id, offset: 0, limit: 250)

        XCTAssertEqual(page.nodes.map(\.id), [second.id, first.id])
        XCTAssertEqual(page.state, .partial)
        XCTAssertTrue(page.estimatingNodeIDs.isEmpty)
    }

    func testLiveTotalsAndIncompleteFlagsPropagateBeforeDirectoryCompletion() async throws {
        let store = ScanTreeStore()
        let url = URL(fileURLWithPath: "/tmp/clearx-live")
        let root = await store.begin(rootURL: url, kind: .directory)
        let children = await store.apply(items: [
            .item(url.appending(path: "nested"), status(inode: 1, directory: true)),
            .item(url.appending(path: "file"), status(inode: 2, blocks: 8))
        ], to: root, expectedDevice: 1, childDepth: 1)
        let nested = try XCTUnwrap(children.first)
        let pending = await store.page(parentID: root, offset: 0, limit: 250)
        XCTAssertEqual(pending.pendingNodeIDs, [nested.nodeID])
        XCTAssertEqual(pending.nodes.map(\.name), ["file", "nested"])

        let grandchildren = await store.apply(items: [
            .item(nested.url.appending(path: "deep"), status(inode: 3, directory: true))
        ], to: nested.nodeID, expectedDevice: 1, childDepth: 2)
        let deep = try XCTUnwrap(grandchildren.first)
        _ = await store.takeProgress()
        _ = await store.apply(items: [
            .item(deep.url.appending(path: "leaf"), status(inode: 4, blocks: 16)), .unreadableItem
        ], to: deep.nodeID, expectedDevice: 1, childDepth: 3)

        let rootNode = await store.rootNode()
        let live = await store.page(parentID: root, offset: 0, limit: 250)
        let progress = await store.takeProgress()
        XCTAssertEqual(rootNode?.allocatedSize, 12_288)
        XCTAssertEqual(rootNode?.isIncomplete, true)
        XCTAssertEqual(live.nodes.map(\.name), ["nested", "file"])
        XCTAssertEqual(live.nodes.first?.allocatedSize, 8_192)
        XCTAssertEqual(live.nodes.first?.isIncomplete, true)
        XCTAssertTrue(live.pendingNodeIDs.isEmpty)
        XCTAssertEqual(live.estimatingNodeIDs, [nested.nodeID])
        XCTAssertTrue(progress.changedParentIDs.contains(root))
        XCTAssertTrue(progress.completedDirectoryIDs.isEmpty)

        await store.finishEnumeratingDirectory(root)
        await store.finishEnumeratingDirectory(nested.nodeID)
        await store.finishEnumeratingDirectory(deep.nodeID)
        await store.finishEnumeratingDirectory(deep.nodeID)
        let finalRoot = await store.rootNode()
        XCTAssertEqual(finalRoot?.allocatedSize, 12_288)
    }

    func testCancellationStopsAllEstimateMarkersWithoutAddingSizesAgain() async throws {
        let store = ScanTreeStore()
        let url = URL(fileURLWithPath: "/tmp/clearx-cancel-markers")
        let root = await store.begin(rootURL: url, kind: .directory)
        _ = await store.apply(items: [.item(url.appending(path: "pending"), status(inode: 1, directory: true))],
                              to: root, expectedDevice: 1, childDepth: 1)
        await store.markCancelled()
        await store.finalizeCancelledDirectories()
        _ = await store.finishScan()
        let page = await store.page(parentID: root, offset: 0, limit: 250)
        XCTAssertTrue(page.estimatingNodeIDs.isEmpty)
        XCTAssertTrue(page.pendingNodeIDs.isEmpty)
        XCTAssertEqual(page.nodes.first?.isIncomplete, true)
    }

    func testDisplayedSnapshotCanReleaseItsReference() async {
        let displayedSnapshot = DisplayedScanSnapshot()
        let store = ScanTreeStore()

        await displayedSnapshot.set(store)
        let displayed = await displayedSnapshot.current()
        XCTAssertTrue(displayed === store)

        await displayedSnapshot.clear()
        let current = await displayedSnapshot.current()
        XCTAssertNil(current)
    }

    private func status(
        inode: UInt64,
        device: Int32 = 1,
        blocks: Int64 = 0,
        links: UInt16 = 1,
        directory: Bool = false,
        symbolicLink: Bool = false
    ) -> FileStatus {
        var info = stat()
        info.st_dev = device
        info.st_ino = inode
        info.st_blocks = blocks
        info.st_nlink = links
        info.st_mode = mode_t(symbolicLink ? S_IFLNK : (directory ? S_IFDIR : S_IFREG))
        return FileStatus(info: info)
    }

    private func makeNode(
        name: String,
        parentID: ScanNodeID? = nil,
        kind: ScanNodeKind = .file,
        size: Int64
    ) -> ScanNodeSummary {
        ScanNodeSummary(
            parentID: parentID,
            url: URL(fileURLWithPath: "/tmp/clearx-store-tests/\(name)"),
            kind: kind,
            allocatedSize: size
        )
    }
}
