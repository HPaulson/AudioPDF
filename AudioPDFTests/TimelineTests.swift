import XCTest
#if canImport(ReaderCore)
@testable import ReaderCore
#else
@testable import AudioPDF
#endif

final class TimelineTests: XCTestCase {
    private func paragraphs() -> [ParagraphRecord] {
        (0..<3).map {
            ParagraphRecord(
                id: UUID(),
                pageIndex: $0,
                pdfBoundingBox: PDFBounds(x: 0, y: 0, width: 1, height: 1),
                normalizedTextRange: ($0 * 10)..<($0 * 10 + 5),
                text: "Part \($0)"
            )
        }
    }

    func testMeasuredClipsCreateMonotonicTimeline() throws {
        let source = paragraphs()
        let clips = zip(source, [1.25, 2.0, 0.5]).map {
            AudioClipMeasurement(
                paragraphID: $0.0.id,
                fileName: "\($0.0.id).wav",
                duration: $0.1
            )
        }
        let timeline = try TimelineBuilder.build(paragraphs: source, clips: clips, gap: 0.3)
        XCTAssertEqual(timeline[0].audioStart, 0, accuracy: 0.0001)
        XCTAssertEqual(timeline[0].audioEnd, 1.25, accuracy: 0.0001)
        XCTAssertEqual(timeline[1].audioStart, 1.55, accuracy: 0.0001)
        XCTAssertEqual(timeline[2].audioStart, 3.85, accuracy: 0.0001)
    }

    func testHighlightLookupUsesSourceTimeAtEveryPlaybackRate() throws {
        let source = paragraphs()
        let clips = source.map {
            AudioClipMeasurement(paragraphID: $0.id, fileName: "x.wav", duration: 2)
        }
        let timeline = try TimelineBuilder.build(paragraphs: source, clips: clips, gap: 0)
        for rate in [0.5, 1.0, 1.5, 2.0] {
            let wallClock = 2.25 / rate
            let sourceTime = wallClock * rate
            XCTAssertEqual(TimelineBuilder.paragraphIndex(at: sourceTime, in: timeline), 1)
        }
    }

    func testSeekClampsToBoundaries() {
        XCTAssertEqual(TimelineBuilder.clampSeek(-2, duration: 10), 0)
        XCTAssertEqual(TimelineBuilder.clampSeek(4.25, duration: 10), 4.25)
        XCTAssertEqual(TimelineBuilder.clampSeek(12, duration: 10), 10)
    }

    func testParagraphClickMapsDirectlyToMeasuredStart() throws {
        let source = paragraphs()
        let clips = source.map {
            AudioClipMeasurement(paragraphID: $0.id, fileName: "x.wav", duration: 3)
        }
        let timeline = try TimelineBuilder.build(paragraphs: source, clips: clips, gap: 0.25)
        XCTAssertEqual(timeline[2].audioStart, 6.5, accuracy: 0.0001)
    }

    func testHighlightStaysOnPreviousParagraphDuringAudioGap() throws {
        let source = paragraphs()
        let clips = source.map {
            AudioClipMeasurement(paragraphID: $0.id, fileName: "x.wav", duration: 2)
        }
        let timeline = try TimelineBuilder.build(paragraphs: source, clips: clips, gap: 0.3)

        XCTAssertEqual(TimelineBuilder.paragraphIndex(at: 2.15, in: timeline), 0)
        XCTAssertEqual(TimelineBuilder.paragraphIndex(at: 2.30, in: timeline), 1)
        XCTAssertEqual(TimelineBuilder.paragraphIndex(at: 100, in: timeline), 2)
    }

    func testParagraphLocatorPrefersContainingParagraph() {
        let source = [
            ParagraphRecord(
                pageIndex: 0,
                pdfBoundingBox: PDFBounds(x: 10, y: 100, width: 200, height: 30),
                normalizedTextRange: 0..<5,
                text: "First"
            ),
            ParagraphRecord(
                pageIndex: 0,
                pdfBoundingBox: PDFBounds(x: 10, y: 40, width: 200, height: 30),
                normalizedTextRange: 6..<12,
                text: "Second"
            )
        ]

        XCTAssertEqual(
            ParagraphLocator.paragraphIndex(pageIndex: 0, x: 50, y: 110, in: source),
            0
        )
        XCTAssertEqual(
            ParagraphLocator.paragraphIndex(pageIndex: 0, x: 50, y: 75, in: source),
            1
        )
    }

    func testParagraphLocatorRejectsDistantAndWrongPageClicks() {
        let source = paragraphs()
        XCTAssertNil(
            ParagraphLocator.paragraphIndex(pageIndex: 0, x: 500, y: 500, in: source)
        )
        XCTAssertNil(
            ParagraphLocator.paragraphIndex(pageIndex: 99, x: 0, y: 0, in: source)
        )
    }
}
