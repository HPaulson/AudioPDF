import XCTest
#if canImport(ReaderCore)
@testable import ReaderCore
#else
@testable import AudioPDF
#endif

final class PlaybackRateTests: XCTestCase {
    func testNormalizesPlaybackRatesWithoutRecursiveMutation() {
        XCTAssertEqual(PlaybackRate.normalize(1.25), 1.25)
        XCTAssertEqual(PlaybackRate.normalize(0.1), 0.5)
        XCTAssertEqual(PlaybackRate.normalize(4), 2)
        XCTAssertEqual(PlaybackRate.normalize(.nan), 1)
        XCTAssertEqual(PlaybackRate.normalize(.infinity), 1)
    }
}
