import AppKit
import XCTest
import SwiftUI
@testable import ClearX

@MainActor
final class ScanPresentationTests: XCTestCase {
    func testEmptyFolderMessageRequiresConfirmedReadableEmptyColumn() {
        for state in [SnapshotBrowserColumnState.loading, .partial, .complete] {
            for incomplete in [false, true] {
                let column = SnapshotBrowserColumn(parent: nil, nodes: [], state: state, isIncomplete: incomplete)
                XCTAssertEqual(column.showsEmptyFolder, state == .complete && !incomplete)
            }
        }
        let unloadedPage = SnapshotBrowserColumn(parent: nil, nodes: [], totalNodeCount: 251)
        XCTAssertFalse(unloadedPage.showsEmptyFolder)
    }

    func testCompactRowKeepsNameOriginAt74Points() {
        XCTAssertEqual(ScanNodeRowView.sizeColumnWidth, 64)
        XCTAssertEqual(ScanNodeRowView.horizontalInset + ScanNodeRowView.sizeColumnWidth
                       + ScanNodeRowView.contentSpacing, 74)
    }

    func testCompactSizeFieldFitsLocalizedSizesAndIncompleteSuffix() {
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let sizes: [Int64] = [0, 999, 999_900, 999_900_000, 999_900_000_000,
                              999_900_000_000_000, 999_900_000_000_000_000, .max]
        for locale in ["en_US", "zh_CN", "fr_FR", "de_DE"] {
            for size in sizes {
                let text = ByteCountPresentation.string(for: size, locale: Locale(identifier: locale)) + "+"
                let width = (text as NSString).size(withAttributes: [.font: font]).width
                XCTAssertLessThanOrEqual(width * ScanNodeRowView.minimumSizeScale,
                                         ScanNodeRowView.sizeColumnWidth, "\(locale): \(text)")
            }
        }
    }

    func testCompactRowsRenderOnOneLineAtMinimumBrowserWidth() throws {
        for size: Int64 in [0, 999_900_000_000, .max] {
            for pending in [false, true] {
                for incomplete in [false, true] {
                    let node = ScanNodeSummary(parentID: nil,
                                              url: URL(fileURLWithPath: "/tmp/A long directory name for compact rows"),
                                              kind: .directory, allocatedSize: size, isIncomplete: incomplete)
                    let view = ScanNodeRowView(node: node, isSelected: false,
                                               isEstimating: pending, isPending: pending)
                        .frame(width: BrowserColumnWidthState.minimumWidth)
                    let image = try XCTUnwrap(ImageRenderer(content: view).nsImage)
                    XCTAssertEqual(image.size.width, BrowserColumnWidthState.minimumWidth)
                    XCTAssertGreaterThan(image.size.height, 12)
                    XCTAssertLessThanOrEqual(image.size.height, 24)
                }
            }
        }
    }

    func testFinishedRowColorsDependOnKindNotSize() {
        for size: Int64 in [0, 4_096, 4_000_000, 4_000_000_000] {
            let directory = ScanNodeSummary(parentID: nil, url: URL(fileURLWithPath: "/tmp/folder"), kind: .directory, allocatedSize: size)
            let file = ScanNodeSummary(parentID: nil, url: URL(fileURLWithPath: "/tmp/file"), kind: .file, allocatedSize: size)
            XCTAssertEqual(row(directory).textColor(for: .light), Color(red: 0.16, green: 0.36, blue: 0.29))
            XCTAssertEqual(row(directory).textColor(for: .dark), Color(red: 0.45, green: 0.78, blue: 0.65))
            XCTAssertEqual(row(file).textColor(for: .light), .primary)
            XCTAssertEqual(row(file).textColor(for: .dark), .primary)
        }
    }

    func testScanningColorOverridesKindAndSize() {
        for kind in [ScanNodeKind.directory, .file] {
            let node = ScanNodeSummary(parentID: nil, url: URL(fileURLWithPath: "/tmp/item"), kind: kind, allocatedSize: 4_000_000_000)
            for scheme in [ColorScheme.light, .dark] {
                XCTAssertEqual(row(node, estimating: true).textColor(for: scheme), .red)
                XCTAssertEqual(row(node, pending: true).textColor(for: scheme), .red)
            }
        }
    }

    func testPendingEmptyEstimatingAndUnreadableSizesAreDistinct() {
        var directory = ScanNodeSummary(parentID: nil, url: URL(fileURLWithPath: "/tmp/folder"), kind: .directory, allocatedSize: 0)
        XCTAssertEqual(row(directory, estimating: true, pending: true).sizeText, "")
        XCTAssertEqual(row(directory).sizeText, ByteCountPresentation.string(for: 0))
        XCTAssertTrue(row(directory, estimating: true).sizeDescription.contains("仍在计算"))
        directory.isIncomplete = true
        XCTAssertEqual(row(directory).sizeText, ByteCountPresentation.string(for: 0) + "+")
        XCTAssertEqual(row(directory).sizeDescription, "大小未知，结果不完整")
        directory.allocatedSize = 4_096
        XCTAssertEqual(row(directory).sizeText, ByteCountPresentation.string(for: 4_096) + "+")
        XCTAssertTrue(row(directory).sizeDescription.contains("不完整"))
    }

    func testIncompleteSizeSuffixPersistsDuringAndAfterScanning() {
        let node = ScanNodeSummary(parentID: nil, url: URL(fileURLWithPath: "/tmp/partial"), kind: .directory,
                                   allocatedSize: 1_250_000_000, isIncomplete: true)
        let expected = ByteCountPresentation.string(for: node.allocatedSize) + "+"
        XCTAssertEqual(row(node, estimating: true).sizeText, expected)
        XCTAssertEqual(row(node).sizeText, expected)
        XCTAssertTrue(row(node).sizeDescription.contains("至少"))
        XCTAssertTrue(row(node).sizeDescription.contains("不完整"))
    }

    func testHardLinkShowsContentSizeAndExplainsSharing() {
        let node = ScanNodeSummary(parentID: nil, url: URL(fileURLWithPath: "/tmp/link"), kind: .file, allocatedSize: 4_096, isHardLink: true)
        XCTAssertEqual(row(node).sizeText, ByteCountPresentation.string(for: 4_096))
        XCTAssertTrue(row(node).sizeDescription.contains("共享同一文件数据"))
        XCTAssertTrue(row(node).sizeDescription.contains("按路径计入"))
        XCTAssertFalse(row(node).sizeDescription.contains("不额外占用"))
    }

    func testOrdinaryProgressAndLocalReadErrorsHaveNoGlobalNotice() {
        let model = makeModel()
        XCTAssertNil(model.scanNotice)
        model.updatePresentationState(.scanning(ScanProgress(discoveredNodeCount: 50, completedDirectoryCount: 2, currentURL: nil)))
        XCTAssertNil(model.scanNotice)
        model.updatePresentationState(.completed(.incomplete([.unreadableItem])))
        XCTAssertNil(model.scanNotice)
        model.updatePresentationState(.completed(.complete))
        XCTAssertNil(model.scanNotice)
    }

    func testTraversalBoundariesExplainZeroWithoutClaimingHardLinkOrFailure() {
        for kind in [ScanNodeKind.symbolicLink, .mountPoint] {
            let node = ScanNodeSummary(parentID: nil, url: URL(fileURLWithPath: "/tmp/boundary"), kind: kind,
                                       allocatedSize: 0)
            let presentation = row(node)
            XCTAssertEqual(presentation.sizeText, ByteCountPresentation.string(for: 0))
            XCTAssertTrue(presentation.sizeDescription.contains(kind == .symbolicLink ? "符号链接" : "挂载点"))
            XCTAssertFalse(presentation.sizeDescription.contains("硬链接"))
            XCTAssertFalse(presentation.sizeDescription.contains("不完整"))
            if kind == .mountPoint {
                XCTAssertEqual(presentation.sizeDescription, "挂载点：本次未扫描其内容，不计入扫描大小")
            }
            XCTAssertEqual(presentation.textColor(for: .light), kind == .mountPoint
                ? Color(red: 0.16, green: 0.36, blue: 0.29) : .primary)
        }
    }

    func testRootFailureAndCancellationHaveGlobalNotice() {
        let model = makeModel()
        model.updatePresentationState(.completed(.incomplete([.sourceUnavailable])))
        XCTAssertTrue(model.scanNotice?.contains("扫描源不可用") == true)
        model.updatePresentationState(.completed(.incomplete([.permissionRestricted, .unreadableItem])))
        XCTAssertTrue(model.scanNotice?.contains("无法读取扫描源") == true)
        model.updatePresentationState(.completed(.incomplete([.cancelled])))
        XCTAssertTrue(model.scanNotice?.contains("扫描已取消") == true)
        model.updatePresentationState(.synchronizationFailed("test error"))
        XCTAssertTrue(model.scanNotice?.contains("test error") == true)
    }

    func testRejectedRescanClearlyIdentifiesPreviousResult() {
        let model = makeModel()
        model.updatePresentationState(.completed(.incomplete([.unreadableItem])), displayingPreviousResult: true)
        XCTAssertTrue(model.scanNotice?.contains("仍显示上次完整结果") == true)
        model.updatePresentationState(.cancelled)
        XCTAssertTrue(model.scanNotice?.contains("仍显示上次完整结果") == true)
        model.updatePresentationState(.synchronizationFailed(ScanMountTableError.unavailable(EIO).localizedDescription))
        XCTAssertTrue(model.scanNotice?.contains("无法读取系统挂载表") == true)
        XCTAssertTrue(model.scanNotice?.contains("仍显示上次完整结果") == true)
        model.updatePresentationState(.completed(.complete), displayingPreviousResult: false)
        XCTAssertNil(model.scanNotice)
        XCTAssertFalse(model.isDisplayingPreviousResult)
    }

    private func row(_ node: ScanNodeSummary, estimating: Bool = false, pending: Bool = false) -> ScanNodeRowPresentation {
        ScanNodeRowPresentation(node: node, isEstimating: estimating, isPending: pending)
    }

    private func makeModel() -> ResultBrowserModel {
        ResultBrowserModel(source: ScanSource(kind: .folder, rootURL: URL(fileURLWithPath: "/tmp/test")),
                           columnLoader: InMemorySnapshotColumnLoader(displayedSnapshot: DisplayedScanSnapshot()))
    }
}
