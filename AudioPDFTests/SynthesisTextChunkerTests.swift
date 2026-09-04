import XCTest
@testable import ReaderCore

final class SynthesisTextChunkerTests: XCTestCase {
    func testKeepsShortSentencesTogether() {
        XCTAssertEqual(
            SynthesisTextChunker.chunks(from: "First sentence. Second sentence!"),
            ["First sentence.", "Second sentence!"]
        )
    }

    func testCanCombineSentencesForFewerEngineCalls() {
        XCTAssertEqual(
            SynthesisTextChunker.chunks(
                from: "First sentence. Second sentence!",
                maximumCharacters: 40,
                combineSentences: true
            ),
            ["First sentence. Second sentence!"]
        )
    }

    func testSplitsLongTextWithoutExceedingLimit() {
        let chunks = SynthesisTextChunker.chunks(
            from: "one two three four five six seven eight nine ten",
            maximumCharacters: 12
        )
        XCTAssertFalse(chunks.isEmpty)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 12 })
        XCTAssertEqual(chunks.joined(separator: " "), "one two three four five six seven eight nine ten")
    }

    func testSplitsSingleOversizedToken() {
        let chunks = SynthesisTextChunker.chunks(
            from: "abcdefghijkl",
            maximumCharacters: 5
        )
        XCTAssertEqual(chunks, ["abcde", "fghij", "kl"])
    }

    func testNormalizesWhitespaceAndIgnoresEmptyInput() {
        XCTAssertEqual(
            SynthesisTextChunker.chunks(from: "  A   sentence.\n\nNext.  "),
            ["A sentence.", "Next."]
        )
        XCTAssertEqual(SynthesisTextChunker.chunks(from: " \n "), [])
    }
}
