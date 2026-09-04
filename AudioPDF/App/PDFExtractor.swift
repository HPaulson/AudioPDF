import Foundation
import PDFKit
import Vision
#if canImport(ReaderCore)
import ReaderCore
#endif

struct OCRCheckpoint: Codable, Sendable {
    /// A non-nil entry means that OCR/text-layer handling for that page is
    /// complete. An empty array is a valid completed page with no recognized
    /// lines, so optionality is important here.
    let pages: [[ExtractedLine]?]
}

struct PDFLoadingProgress: Sendable, Equatable {
    let fractionCompleted: Double
    let message: String
}

enum PDFExtractor {
    static func extract(
        from url: URL,
        progress: @escaping @Sendable (PDFLoadingProgress) -> Void = { _ in },
        ocrCheckpoint: OCRCheckpoint? = nil,
        checkpoint: @escaping @Sendable (OCRCheckpoint) -> Void = { _ in }
    ) throws -> [ParagraphRecord] {
        progress(PDFLoadingProgress(fractionCompleted: 0.05, message: "Opening PDF…"))
        guard let document = PDFDocument(url: url), document.pageCount > 0 else {
            throw ReaderFailure.invalidPDF
        }

        var pages: [[ExtractedLine]] = []
        var selectableCharacterCount = 0
        progress(PDFLoadingProgress(fractionCompleted: 0.12, message: "Checking for selectable text…"))

        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else {
                pages.append([])
                continue
            }
            let pageSelection = page.selection(for: page.bounds(for: .mediaBox))
            let lines = pageSelection?.selectionsByLine() ?? []
            let extracted: [ExtractedLine] = lines.compactMap { selection in
                guard let raw = selection.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !raw.isEmpty else { return nil }
                selectableCharacterCount += raw.count
                let rect = selection.bounds(for: page)
                return ExtractedLine(
                    pageIndex: pageIndex,
                    bounds: PDFBounds(
                        x: rect.origin.x,
                        y: rect.origin.y,
                        width: rect.size.width,
                        height: rect.size.height
                    ),
                    text: raw
                )
            }
            pages.append(extracted)
            let fraction = 0.12 + (Double(pageIndex + 1) / Double(document.pageCount)) * 0.28
            progress(PDFLoadingProgress(
                fractionCompleted: fraction,
                message: "Reading text layer · page \(pageIndex + 1) of \(document.pageCount)"
            ))
        }

        // A scanned PDF has no text layer for PDFKit to extract. Recognize those
        // pages locally before giving up, while keeping the original PDF for
        // display. This also handles PDFs where only some pages have a text layer.
        if selectableCharacterCount <= 20 {
            progress(PDFLoadingProgress(
                fractionCompleted: 0.42,
                message: "Scanned PDF detected · preparing OCR…"
            ))
            let ocrPages = try OCRRecognizer.recognize(
                document: document,
                existingPages: pages,
                checkpoint: ocrCheckpoint,
                progress: progress,
                checkpointHandler: { checkpointValue in
                checkpoint(checkpointValue)
                }
            )
            if ocrPages.reduce(0, { $0 + $1.reduce(0) { $0 + $1.text.count } }) > selectableCharacterCount {
                pages = ocrPages
            }
        }

        guard pages.reduce(0, { $0 + $1.reduce(0) { $0 + $1.text.count } }) > 20 else {
            throw ReaderFailure.scannedPDF
        }
        let paragraphs = TextCleanup.paragraphs(from: pages)
        guard !paragraphs.isEmpty else {
            throw ReaderFailure.scannedPDF
        }
        return paragraphs
    }
}

private enum OCRRecognizer {
    static func recognize(
        document: PDFDocument,
        existingPages: [[ExtractedLine]],
        checkpoint: OCRCheckpoint?,
        progress: @escaping @Sendable (PDFLoadingProgress) -> Void,
        checkpointHandler: @escaping @Sendable (OCRCheckpoint) -> Void
    ) throws -> [[ExtractedLine]] {
        var recognizedPages = checkpoint?.pages ?? Array(repeating: nil, count: existingPages.count)
        if recognizedPages.count != existingPages.count {
            recognizedPages = Array(repeating: nil, count: existingPages.count)
        }

        return try existingPages.enumerated().map { pageIndex, existingLines in
            if let cached = recognizedPages[pageIndex] {
                progress(PDFLoadingProgress(
                    fractionCompleted: 0.42 + (Double(pageIndex + 1) / Double(document.pageCount)) * 0.48,
                    message: "Restored OCR · page \(pageIndex + 1) of \(document.pageCount)"
                ))
                return cached
            }

            guard existingLines.isEmpty,
                  let page = document.page(at: pageIndex) else {
                recognizedPages[pageIndex] = existingLines
                checkpointHandler(OCRCheckpoint(pages: recognizedPages))
                progress(PDFLoadingProgress(
                    fractionCompleted: 0.42 + (Double(pageIndex + 1) / Double(document.pageCount)) * 0.48,
                    message: "OCR complete · page \(pageIndex + 1) of \(document.pageCount)"
                ))
                return existingLines
            }

            let bounds = page.bounds(for: .mediaBox)
            let scale: CGFloat = 2
            let pixelWidth = max(Int(bounds.width * scale), 1)
            let pixelHeight = max(Int(bounds.height * scale), 1)
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            guard let context = CGContext(
                data: nil,
                width: pixelWidth,
                height: pixelHeight,
                bitsPerComponent: 8,
                bytesPerRow: pixelWidth * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                return []
            }

            context.setFillColor(CGColor.white)
            context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
            context.saveGState()
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -bounds.minX, y: -bounds.minY)
            page.draw(with: .mediaBox, to: context)
            context.restoreGState()
            guard let image = context.makeImage() else {
                recognizedPages[pageIndex] = []
                checkpointHandler(OCRCheckpoint(pages: recognizedPages))
                return []
            }

            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            try handler.perform([request])

            progress(PDFLoadingProgress(
                fractionCompleted: 0.42 + (Double(pageIndex + 1) / Double(document.pageCount)) * 0.48,
                message: "Recognizing scanned text · page \(pageIndex + 1) of \(document.pageCount)"
            ))

            let lines: [ExtractedLine] = (request.results ?? []).compactMap { observation in
                guard let candidate = observation.topCandidates(1).first,
                      !candidate.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      candidate.confidence >= 0.2 else { return nil }
                let box = observation.boundingBox
                return ExtractedLine(
                    pageIndex: pageIndex,
                    bounds: PDFBounds(
                        x: bounds.minX + box.minX * bounds.width,
                        y: bounds.minY + box.minY * bounds.height,
                        width: box.width * bounds.width,
                        height: box.height * bounds.height
                    ),
                    text: candidate.string
                )
            }
            recognizedPages[pageIndex] = lines
            checkpointHandler(OCRCheckpoint(pages: recognizedPages))
            return lines
        }
    }
}
