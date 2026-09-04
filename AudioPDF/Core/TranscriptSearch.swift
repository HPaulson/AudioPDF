import Foundation

public enum TranscriptSearch {
    public static func matchingParagraphIndices(
        query: String,
        paragraphs: [ParagraphRecord]
    ) -> [Int] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return paragraphs.indices.filter {
            paragraphs[$0].text.localizedCaseInsensitiveContains(trimmed)
        }
    }
}
