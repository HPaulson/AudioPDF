import Foundation

public struct PDFBounds: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct ParagraphRecord: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var pageIndex: Int
    public var pdfBoundingBox: PDFBounds
    public var normalizedTextRange: Range<Int>
    public var text: String
    public var audioStart: TimeInterval
    public var audioEnd: TimeInterval
    public var audioFile: String?

    public init(
        id: UUID = UUID(),
        pageIndex: Int,
        pdfBoundingBox: PDFBounds,
        normalizedTextRange: Range<Int>,
        text: String,
        audioStart: TimeInterval = 0,
        audioEnd: TimeInterval = 0,
        audioFile: String? = nil
    ) {
        self.id = id
        self.pageIndex = pageIndex
        self.pdfBoundingBox = pdfBoundingBox
        self.normalizedTextRange = normalizedTextRange
        self.text = text
        self.audioStart = audioStart
        self.audioEnd = audioEnd
        self.audioFile = audioFile
    }
}

public struct ExtractedLine: Codable, Hashable, Sendable {
    public var pageIndex: Int
    public var bounds: PDFBounds
    public var text: String

    public init(pageIndex: Int, bounds: PDFBounds, text: String) {
        self.pageIndex = pageIndex
        self.bounds = bounds
        self.text = text
    }
}

public struct AudioClipMeasurement: Hashable, Sendable {
    public var paragraphID: UUID
    public var fileName: String
    public var duration: TimeInterval

    public init(paragraphID: UUID, fileName: String, duration: TimeInterval) {
        self.paragraphID = paragraphID
        self.fileName = fileName
        self.duration = duration
    }
}

public enum AudioGenerationPhase: Equatable, Sendable {
    case generatingParagraphs
    case assembling
}

public struct AudioGenerationProgress: Equatable, Sendable {
    public let completedParagraphs: Int
    public let totalParagraphs: Int
    public let phase: AudioGenerationPhase

    public init(completedParagraphs: Int, totalParagraphs: Int, phase: AudioGenerationPhase) {
        self.completedParagraphs = completedParagraphs
        self.totalParagraphs = totalParagraphs
        self.phase = phase
    }

    public var fractionCompleted: Double {
        guard totalParagraphs > 0 else { return phase == .assembling ? 1 : 0 }
        return min(max(Double(completedParagraphs) / Double(totalParagraphs), 0), 1)
    }
}

public enum ReaderFailure: LocalizedError, Equatable {
    case invalidPDF
    case scannedPDF
    case missingVoiceModel(String)
    case invalidVoiceModel(String)
    case synthesisFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidPDF:
            return "The selected file is not a readable PDF."
        case .scannedPDF:
            return "No selectable text was found. This PDF appears to contain scanned images and needs OCR before it can be read."
        case .missingVoiceModel(let detail):
            return "No complete local voice model is installed. \(detail)"
        case .invalidVoiceModel(let detail):
            return "The selected voice model is incomplete or incompatible. \(detail)"
        case .synthesisFailed(let detail):
            return "Local speech synthesis failed. \(detail)"
        }
    }
}
