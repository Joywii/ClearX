import XCTest
@testable import ClearX

final class ScanTreeStoreTests: XCTestCase {
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

    func testIncompleteSnapshotKeepsDiscoveryOrder() async {
        let root = makeNode(name: "root", kind: .directory, size: 30)
        let first = makeNode(name: "first", parentID: root.id, size: 10)
        let second = makeNode(name: "second", parentID: root.id, size: 20)
        let store = ScanTreeStore(snapshotNodes: [root, first, second], status: .incomplete([.cancelled]))

        let page = await store.page(parentID: root.id, offset: 0, limit: 250)

        XCTAssertEqual(page.nodes.map(\.id), [first.id, second.id])
        XCTAssertEqual(page.state, .partial)
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
