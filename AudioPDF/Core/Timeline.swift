import Foundation

public enum TimelineBuilder {
    public static func build(
        paragraphs: [ParagraphRecord],
        clips: [AudioClipMeasurement],
        gap: TimeInterval = 0.30
    ) throws -> [ParagraphRecord] {
        let byID = Dictionary(uniqueKeysWithValues: clips.map { ($0.paragraphID, $0) })
        var cursor: TimeInterval = 0

        return try paragraphs.map { paragraph in
            guard let clip = byID[paragraph.id], clip.duration.isFinite, clip.duration >= 0 else {
                throw ReaderFailure.synthesisFailed("Audio metadata is missing for a paragraph.")
            }
            var updated = paragraph
            updated.audioStart = cursor
            updated.audioEnd = cursor + clip.duration
            updated.audioFile = clip.fileName
            cursor = updated.audioEnd + gap
            return updated
        }
    }

    public static func paragraphIndex(at sourceTime: TimeInterval, in timeline: [ParagraphRecord]) -> Int? {
        guard !timeline.isEmpty else { return nil }
        let clamped = max(0, sourceTime)
        var low = 0
        var high = timeline.count
        while low < high {
            let mid = (low + high) / 2
            if timeline[mid].audioStart <= clamped {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return min(max(0, low - 1), timeline.count - 1)
    }

    public static func clampSeek(_ time: TimeInterval, duration: TimeInterval) -> TimeInterval {
        guard duration.isFinite, duration > 0, time.isFinite else { return 0 }
        return min(max(0, time), duration)
    }
}

public enum ParagraphLocator {
    public static func paragraphIndex(
        pageIndex: Int,
        x: Double,
        y: Double,
        in paragraphs: [ParagraphRecord],
        hitSlop: Double = 3,
        maximumDistance: Double = 28
    ) -> Int? {
        let candidates = paragraphs.indices.filter { paragraphs[$0].pageIndex == pageIndex }
        if let exact = candidates.first(where: {
            contains(x: x, y: y, bounds: paragraphs[$0].pdfBoundingBox, inset: hitSlop)
        }) {
            return exact
        }

        return candidates
            .map { ($0, distance(x: x, y: y, bounds: paragraphs[$0].pdfBoundingBox)) }
            .filter { $0.1 <= maximumDistance }
            .min(by: { $0.1 < $1.1 })?
            .0
    }

    private static func contains(
        x: Double,
        y: Double,
        bounds: PDFBounds,
        inset: Double
    ) -> Bool {
        x >= bounds.x - inset &&
            x <= bounds.x + bounds.width + inset &&
            y >= bounds.y - inset &&
            y <= bounds.y + bounds.height + inset
    }

    private static func distance(x: Double, y: Double, bounds: PDFBounds) -> Double {
        let dx = max(bounds.x - x, 0, x - (bounds.x + bounds.width))
        let dy = max(bounds.y - y, 0, y - (bounds.y + bounds.height))
        return hypot(dx, dy)
    }
}
