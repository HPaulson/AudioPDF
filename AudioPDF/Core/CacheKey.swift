import CryptoKit
import Foundation

public enum CacheKey {
    public static func sourceFingerprint(pdfData: Data) -> String {
        digest(pdfData)
    }

    public static func make(
        pdfData: Data,
        normalizedText: String,
        voiceFingerprint: String,
        synthesisSettings: String
    ) -> String {
        var data = Data()
        data.append(pdfData)
        data.append(Data(normalizedText.utf8))
        data.append(Data(voiceFingerprint.utf8))
        data.append(Data(synthesisSettings.utf8))
        return digest(data)
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
