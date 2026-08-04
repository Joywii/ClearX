import XCTest
@testable import ClearX

@MainActor
final class SourceSelectionModelTests: XCTestCase {
    func testLoadsDiscoveredSources() async {
        let expected = [
            ScanSource(kind: .machineDisk, rootURL: URL(fileURLWithPath: "/"), displayName: "本机磁盘"),
            ScanSource(kind: .localVolume, rootURL: URL(fileURLWithPath: "/Volumes/Archive"), displayName: "Archive")
        ]
        let model = SourceSelectionModel(catalog: SourceCatalogStub(sources: expected))

        await model.loadSources()

        XCTAssertEqual(model.sources, expected)
        XCTAssertFalse(model.isLoading)
        XCTAssertNil(model.loadError)
    }
}

private actor SourceCatalogStub: ScanSourceCataloging {
    private let sources: [ScanSource]

    init(sources: [ScanSource]) {
        self.sources = sources
    }

    func discoverSources() async -> [ScanSource] {
        sources
    }
}
