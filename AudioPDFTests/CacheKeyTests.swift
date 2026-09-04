import XCTest
#if canImport(ReaderCore)
@testable import ReaderCore
#else
@testable import AudioPDF
#endif

final class CacheKeyTests: XCTestCase {
    func testKeyIsStableAndInvalidatesEveryInput() {
        let baseline = CacheKey.make(
            pdfData: Data("pdf".utf8),
            normalizedText: "text",
            voiceFingerprint: "voice",
            synthesisSettings: "settings"
        )
        XCTAssertEqual(
            baseline,
            CacheKey.make(
                pdfData: Data("pdf".utf8),
                normalizedText: "text",
                voiceFingerprint: "voice",
                synthesisSettings: "settings"
            )
        )
        XCTAssertNotEqual(
            baseline,
            CacheKey.make(
                pdfData: Data("changed".utf8),
                normalizedText: "text",
                voiceFingerprint: "voice",
                synthesisSettings: "settings"
            )
        )
        XCTAssertNotEqual(
            baseline,
            CacheKey.make(
                pdfData: Data("pdf".utf8),
                normalizedText: "changed",
                voiceFingerprint: "voice",
                synthesisSettings: "settings"
            )
        )
        XCTAssertNotEqual(
            baseline,
            CacheKey.make(
                pdfData: Data("pdf".utf8),
                normalizedText: "text",
                voiceFingerprint: "other voice",
                synthesisSettings: "settings"
            )
        )
        XCTAssertNotEqual(
            baseline,
            CacheKey.make(
                pdfData: Data("pdf".utf8),
                normalizedText: "text",
                voiceFingerprint: "voice",
                synthesisSettings: "changed-settings"
            )
        )
    }
}
