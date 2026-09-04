import Foundation

enum VoiceQuality: String, CaseIterable, Identifiable, Sendable {
    case low
    case medium
    case high
    case veryHigh = "very-high"

    static let userDefaultsKey = "voiceQuality"
    static let defaultValue: Self = .medium

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .low: "Low quality"
        case .medium: "Medium quality"
        case .high: "High quality"
        case .veryHigh: "Very high quality"
        }
    }

    var detail: String {
        switch self {
        case .low: "Fastest generation"
        case .medium: "Good balance of quality and speed"
        case .high: "More natural, slower generation"
        case .veryHigh: "Best available quality, slowest generation"
        }
    }

    static var current: Self {
        guard let value = UserDefaults.standard.string(forKey: userDefaultsKey),
              let quality = Self(rawValue: value) else { return defaultValue }
        return quality
    }
}

struct VoiceModel: Identifiable, Hashable, Sendable {
    let id: String
    let displayName: String
    let directory: URL
    let model: URL
    let tokens: URL
    let dataDirectory: URL

    var quality: VoiceQuality? {
        let normalized = id.lowercased().replacingOccurrences(of: "_", with: "-")
        if normalized.contains("very-high") || normalized.contains("x-high") { return .veryHigh }
        if normalized.hasSuffix("-high") { return .high }
        if normalized.hasSuffix("-medium") { return .medium }
        if normalized.hasSuffix("-low") || normalized.contains("-x-low") { return .low }
        return nil
    }

    var performanceLabel: String {
        quality?.detail ?? "Installed voice"
    }

    var fingerprint: String {
        let attributes = try? FileManager.default.attributesOfItem(atPath: model.path)
        let size = attributes?[.size] as? NSNumber
        let modified = attributes?[.modificationDate] as? Date
        return "\(id)|\(size?.int64Value ?? 0)|\(modified?.timeIntervalSince1970 ?? 0)"
    }
}

enum VoiceModelStore {
    static var applicationSupport: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("AudioPDF/Voices", isDirectory: true)
    }

    static func ensureDirectory() throws {
        try FileManager.default.createDirectory(
            at: applicationSupport,
            withIntermediateDirectories: true
        )
    }

    static func discover() -> [VoiceModel] {
        try? ensureDirectory()
        var roots = [applicationSupport]
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("VoiceAssets", isDirectory: true) {
            roots.append(bundled)
        }

        return roots.flatMap { root -> [VoiceModel] in
            let children = (try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []
            return children.compactMap(descriptor)
        }
        .reduce(into: [String: VoiceModel]()) { $0[$1.id] = $1 }
        .values
        .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    static func voice(for quality: VoiceQuality, in voices: [VoiceModel]) -> VoiceModel? {
        if let exact = voices.first(where: { $0.quality == quality }) { return exact }
        let desired = VoiceQuality.allCases.firstIndex(of: quality) ?? 0
        return voices.compactMap { voice -> (VoiceModel, Int)? in
            guard let available = voice.quality,
                  let index = VoiceQuality.allCases.firstIndex(of: available) else { return nil }
            return (voice, abs(index - desired))
        }.min(by: { $0.1 < $1.1 })?.0 ?? voices.first
    }

    private static func descriptor(_ directory: URL) -> VoiceModel? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }

        let children = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []
        guard let model = children.first(where: { $0.pathExtension == "onnx" }),
              let tokens = children.first(where: { $0.lastPathComponent == "tokens.txt" }) else {
            return nil
        }
        let data = directory.appendingPathComponent("espeak-ng-data", isDirectory: true)
        guard FileManager.default.fileExists(atPath: data.path) else { return nil }
        return VoiceModel(
            id: directory.lastPathComponent,
            displayName: displayName(for: directory.lastPathComponent),
            directory: directory,
            model: model,
            tokens: tokens,
            dataDirectory: data
        )
    }

    private static func displayName(for id: String) -> String {
        let name = id
            .replacingOccurrences(of: "vits-piper-en_US-", with: "")
            .replacingOccurrences(of: "en_US-", with: "")
        let parts = name.split(separator: "-")
        guard let first = parts.first else { return id }
        if first.lowercased() == "ljspeech" {
            return "LJ Speech"
        }
        return first.replacingOccurrences(of: "_", with: " ").capitalized
    }
}
