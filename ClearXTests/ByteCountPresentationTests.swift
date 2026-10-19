import XCTest
@testable import ClearX

final class ByteCountPresentationTests: XCTestCase {
    func testUsesAtMostOneFractionDigitAcrossUnits() {
        let locale = Locale(identifier: "en_US")
        for (bytes, expected): (Int64, String) in [
            (0, "0 bytes"), (12, "12 bytes"),
            (1_234, "1.2 kB"), (1_234_567, "1.2 MB"),
            (1_234_567_890, "1.2 GB"), (1_234_567_890_123, "1.2 TB"),
            (1_000_000_000, "1 GB"), (Int64.max, "9,223.4 PB")
        ] {
            XCTAssertEqual(ByteCountPresentation.string(for: bytes, locale: locale), expected)
        }
    }

    func testRoundsOriginalBytesOnlyOnce() {
        let locale = Locale(identifier: "en_US")
        XCTAssertEqual(ByteCountPresentation.string(for: 1_249_000_000, locale: locale), "1.2 GB")
        XCTAssertEqual(ByteCountPresentation.string(for: 1_251_000_000, locale: locale), "1.3 GB")
        XCTAssertEqual(ByteCountPresentation.string(for: 1_999_000_000, locale: locale), "2 GB")
    }

    func testExactHalfRoundsUpInsteadOfToEven() {
        let locale = Locale(identifier: "en_US")
        for (bytes, expected): (Int64, String) in [
            (1_250, "1.3 kB"), (1_250_000, "1.3 MB"),
            (1_250_000_000, "1.3 GB"), (1_250_000_000_000, "1.3 TB"),
            (1_240_000_000, "1.2 GB"), (1_249_999_999, "1.2 GB"),
            (1_350_000_000, "1.4 GB"), (1_950_000_000, "2 GB")
        ] {
            XCTAssertEqual(ByteCountPresentation.string(for: bytes, locale: locale), expected)
        }
    }

    func testPreservesLocalizedDecimalSeparatorAndUnit() {
        XCTAssertEqual(ByteCountPresentation.string(for: 1_234_567_890, locale: Locale(identifier: "de_DE")), "1,2\u{00a0}GB")
    }
}
