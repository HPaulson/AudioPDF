import Foundation

public enum TextCleanup {
    private static let pageNumber = try! NSRegularExpression(
        pattern: #"(?i)^\s*(?:-+\s*)?(?:page\s+)?\d{1,4}(?:\s+of\s+\d{1,4})?(?:\s*-+)?\s*$"#
    )
    private static let bracketedMarker = try! NSRegularExpression(
        pattern: #"\[(?:\d{1,3}|[A-Za-z][^\]\n]{0,60}?\d{4}[^\]\n]{0,20}?)\]"#
    )
    private static let gluedMarker = try! NSRegularExpression(
        pattern: #"(?<=[A-Za-z.,;:!?])\d{1,2}(?=[\s.,;:!?)\]]|$)"#
    )

    public static func normalize(_ raw: String) -> String {
        var text = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{00AD}", with: "")
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: "\u{2018}", with: "'")
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{201C}", with: "\"")
            .replacingOccurrences(of: "\u{201D}", with: "\"")

        text = replacing(#"(\p{L})-\n(\p{L})"#, in: text, with: "$1$2")
        text = replacing(bracketedMarker, in: text, with: "")
        text = replacing(#"(?<=[A-Za-z.,;:!?])\(\d{1,3}\)"#, in: text, with: "")
        text = replacing(#"\^\d{1,3}|[⁰¹²³⁴⁵⁶⁷⁸⁹]+"#, in: text, with: "")
        text = replacing(gluedMarker, in: text, with: "")
        text = replacing(#"(?m)^\s*[•*]\s+"#, in: text, with: "")
        text = replacing(#"(?m)^\s*\d+[.)]\s+"#, in: text, with: "")
        text = replacing(#"[ \t]+"#, in: text, with: " ")
        text = replacing(#"\s*\n\s*"#, in: text, with: " ")
        text = replacing(#"\s{2,}"#, in: text, with: " ")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func isPageNumber(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return pageNumber.firstMatch(in: text, range: range) != nil
    }

    public static func repeatedRunningText(in pages: [[ExtractedLine]]) -> Set<String> {
        var pagesByText: [String: Set<Int>] = [:]
        for (pageIndex, lines) in pages.enumerated() {
            for line in lines {
                let key = normalize(line.text).lowercased()
                guard key.count > 1, key.count < 80 else { continue }
                pagesByText[key, default: []].insert(pageIndex)
            }
        }
        return Set(pagesByText.compactMap { key, pages in
            pages.count >= 3 ? key : nil
        })
    }

    public static func paragraphs(from pages: [[ExtractedLine]]) -> [ParagraphRecord] {
        let repeated = repeatedRunningText(in: pages)
        var result: [ParagraphRecord] = []
        var cursor = 0

        for lines in pages {
            let sorted = readingOrder(lines)
            var group: [ExtractedLine] = []

            func flush() {
                guard !group.isEmpty else { return }
                let text = normalize(group.map(\.text).joined(separator: "\n"))
                defer { group.removeAll(keepingCapacity: true) }
                guard text.count > 1,
                      !isPageNumber(text),
                      !repeated.contains(text.lowercased()) else { return }

                if !result.isEmpty { cursor += 2 }
                let start = cursor
                cursor += text.count
                let bounds = union(group.map(\.bounds))
                result.append(ParagraphRecord(
                    pageIndex: group[0].pageIndex,
                    pdfBoundingBox: bounds,
                    normalizedTextRange: start..<cursor,
                    text: text
                ))
            }

            for line in sorted {
                if let previous = group.last {
                    let gap = previous.bounds.y - (line.bounds.y + line.bounds.height)
                    let lineHeight = max(previous.bounds.height, line.bounds.height)
                    let indentChange = abs(line.bounds.x - previous.bounds.x)
                    if gap > lineHeight * 0.9 || indentChange > 32 {
                        flush()
                    }
                }
                group.append(line)
            }
            flush()
        }
        return result
    }

    /// PDFKit commonly returns text in a geometric, row-major order. That is
    /// wrong for a magazine or newspaper page: the reader should finish the
    /// left column before moving to the next one. Infer columns from the
    /// repeated left edges of lines, but fall back to the usual top-to-bottom
    /// order when the page does not contain a convincing column layout.
    private static func readingOrder(_ lines: [ExtractedLine]) -> [ExtractedLine] {
        guard lines.count > 3 else { return geometricOrder(lines) }

        let xPositions = lines.map { $0.bounds.x }.sorted()
        let heights = lines.map { $0.bounds.height }.sorted()
        let medianHeight = heights[heights.count / 2]
        let columnGap = max(36.0, medianHeight * 3.5)

        var clusters: [[Double]] = []
        for x in xPositions {
            if let last = clusters.last,
               let lastX = last.last,
               x - lastX <= columnGap {
                clusters[clusters.count - 1].append(x)
            } else {
                clusters.append([x])
            }
        }

        // A real column normally contributes several lines. This avoids
        // treating an indented quote or a single heading as a new column.
        let substantialClusters = clusters.filter { cluster in
            lines.filter { cluster.contains($0.bounds.x) }.count >= 2
        }
        guard substantialClusters.count >= 2 else { return geometricOrder(lines) }

        let anchors = substantialClusters.map { cluster in
            cluster.reduce(0, +) / Double(cluster.count)
        }
        return lines.sorted { left, right in
            let leftColumn = nearestAnchor(to: left.bounds.x, anchors: anchors)
            let rightColumn = nearestAnchor(to: right.bounds.x, anchors: anchors)
            if leftColumn != rightColumn { return leftColumn < rightColumn }
            if abs(left.bounds.y - right.bounds.y) > 2 {
                return left.bounds.y > right.bounds.y
            }
            return left.bounds.x < right.bounds.x
        }
    }

    private static func geometricOrder(_ lines: [ExtractedLine]) -> [ExtractedLine] {
        lines.sorted {
            if abs($0.bounds.y - $1.bounds.y) > 2 {
                return $0.bounds.y > $1.bounds.y
            }
            return $0.bounds.x < $1.bounds.x
        }
    }

    private static func nearestAnchor(to x: Double, anchors: [Double]) -> Int {
        anchors.enumerated().min {
            abs($0.element - x) < abs($1.element - x)
        }?.offset ?? 0
    }

    private static func union(_ bounds: [PDFBounds]) -> PDFBounds {
        guard let first = bounds.first else {
            return PDFBounds(x: 0, y: 0, width: 0, height: 0)
        }
        return bounds.dropFirst().reduce(first) { current, next in
            let minX = min(current.x, next.x)
            let minY = min(current.y, next.y)
            let maxX = max(current.x + current.width, next.x + next.width)
            let maxY = max(current.y + current.height, next.y + next.height)
            return PDFBounds(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }
    }

    private static func replacing(_ pattern: String, in value: String, with replacement: String) -> String {
        replacing(try! NSRegularExpression(pattern: pattern), in: value, with: replacement)
    }

    private static func replacing(
        _ expression: NSRegularExpression,
        in value: String,
        with replacement: String
    ) -> String {
        expression.stringByReplacingMatches(
            in: value,
            range: NSRange(value.startIndex..., in: value),
            withTemplate: replacement
        )
    }
}
