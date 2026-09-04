import XCTest
#if canImport(ReaderCore)
@testable import ReaderCore
#else
@testable import AudioPDF
#endif

final class TextCleanupTests: XCTestCase {
    func testCleanupRepairsHyphenationAndMarkers() {
        let input = "An exam-\nple claim12 with a citation[4] and “quotes.”"
        XCTAssertEqual(
            TextCleanup.normalize(input),
            #"An example claim with a citation and "quotes.""#
        )
    }

    func testPageNumberRecognition() {
        XCTAssertTrue(TextCleanup.isPageNumber("Page 12 of 300"))
        XCTAssertTrue(TextCleanup.isPageNumber("- 42 -"))
        XCTAssertFalse(TextCleanup.isPageNumber("Section 42 is important"))
    }

    func testRepeatedHeaderIsRemovedAndRangesRemainNormalized() {
        let header = ExtractedLine(
            pageIndex: 0,
            bounds: PDFBounds(x: 10, y: 750, width: 100, height: 10),
            text: "RUNNING HEADER"
        )
        let pages = (0..<3).map { page -> [ExtractedLine] in
            [
                ExtractedLine(
                    pageIndex: page,
                    bounds: header.bounds,
                    text: header.text
                ),
                ExtractedLine(
                    pageIndex: page,
                    bounds: PDFBounds(x: 20, y: 600, width: 300, height: 12),
                    text: "Body paragraph \(page)."
                )
            ]
        }
        let paragraphs = TextCleanup.paragraphs(from: pages)
        XCTAssertEqual(paragraphs.count, 3)
        XCTAssertEqual(paragraphs[0].normalizedTextRange, 0..<17)
        XCTAssertEqual(paragraphs[1].normalizedTextRange.lowerBound, 19)
        XCTAssertEqual(paragraphs[2].pageIndex, 2)
    }

    func testGeometryUnionsParagraphLines() {
        let pages = [[
            ExtractedLine(
                pageIndex: 0,
                bounds: PDFBounds(x: 10, y: 100, width: 80, height: 10),
                text: "A first line"
            ),
            ExtractedLine(
                pageIndex: 0,
                bounds: PDFBounds(x: 10, y: 88, width: 120, height: 10),
                text: "continues here."
            )
        ]]
        let paragraph = TextCleanup.paragraphs(from: pages)[0]
        XCTAssertEqual(paragraph.pdfBoundingBox, PDFBounds(x: 10, y: 88, width: 120, height: 22))
    }

    func testMultiColumnPagesReadDownFirstThenAcross() {
        let pages = [[
            ExtractedLine(pageIndex: 0, bounds: PDFBounds(x: 20, y: 700, width: 120, height: 10), text: "Left one."),
            ExtractedLine(pageIndex: 0, bounds: PDFBounds(x: 260, y: 700, width: 120, height: 10), text: "Middle one."),
            ExtractedLine(pageIndex: 0, bounds: PDFBounds(x: 500, y: 700, width: 120, height: 10), text: "Right one."),
            ExtractedLine(pageIndex: 0, bounds: PDFBounds(x: 20, y: 687, width: 120, height: 10), text: "Left two."),
            ExtractedLine(pageIndex: 0, bounds: PDFBounds(x: 260, y: 687, width: 120, height: 10), text: "Middle two."),
            ExtractedLine(pageIndex: 0, bounds: PDFBounds(x: 500, y: 687, width: 120, height: 10), text: "Right two.")
        ]]

        XCTAssertEqual(
            TextCleanup.paragraphs(from: pages).map(\.text),
            ["Left one. Left two.", "Middle one. Middle two.", "Right one. Right two."]
        )
    }

    func testSearchMapsCaseInsensitiveMatchesToParagraphs() {
        let paragraphs = [
            ParagraphRecord(
                pageIndex: 2,
                pdfBoundingBox: PDFBounds(x: 0, y: 0, width: 1, height: 1),
                normalizedTextRange: 0..<11,
                text: "First match"
            ),
            ParagraphRecord(
                pageIndex: 7,
                pdfBoundingBox: PDFBounds(x: 0, y: 0, width: 1, height: 1),
                normalizedTextRange: 13..<27,
                text: "Nothing here"
            ),
            ParagraphRecord(
                pageIndex: 8,
                pdfBoundingBox: PDFBounds(x: 0, y: 0, width: 1, height: 1),
                normalizedTextRange: 29..<42,
                text: "MATCH again"
            )
        ]
        XCTAssertEqual(
            TranscriptSearch.matchingParagraphIndices(query: "match", paragraphs: paragraphs),
            [0, 2]
        )
        XCTAssertEqual(paragraphs[2].pageIndex, 8)
    }
}
