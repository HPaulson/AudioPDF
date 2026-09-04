import Foundation
import SherpaOnnxRuntime
import os.log
#if canImport(ReaderCore)
import ReaderCore
#endif

private final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var deadline: ContinuousClock.Instant?
    private var timedOut = false

    init(timeout: Duration? = nil) {
        if let timeout {
            deadline = .now.advanced(by: timeout)
        }
    }

    func beginChunk(timeout: Duration) {
        lock.withLock {
            deadline = .now.advanced(by: timeout)
            timedOut = false
        }
    }

    func cancel() {
        lock.withLock { cancelled = true }
    }

    func shouldContinue() -> Int32 {
        lock.withLock {
            if let deadline, ContinuousClock.now >= deadline {
                timedOut = true
                return 0
            }
            return cancelled ? 0 : 1
        }
    }

    var didTimeOut: Bool {
        lock.withLock { timedOut }
    }
}

private let synthesisProgressCallback:
    @convention(c) (UnsafePointer<Float>?, Int32, Float, UnsafeMutableRawPointer?) -> Int32 = {
        _, _, _, context in
        guard let context else { return 1 }
        return Unmanaged<CancellationFlag>.fromOpaque(context).takeUnretainedValue().shouldContinue()
    }

enum SynthesisPerformance {
    static let userDefaultsKey = "synthesisPerformance"

    enum Level: String, CaseIterable, Identifiable {
        case slow
        case medium
        case fast
        case veryFast = "very-fast"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .slow: "Slow"
            case .medium: "Medium"
            case .fast: "Fast"
            case .veryFast: "Very Fast"
            }
        }
    }

    static var level: Level {
        guard let value = UserDefaults.standard.string(forKey: userDefaultsKey),
              let level = Level(rawValue: value) else { return .medium }
        return level
    }

    static var threadCount: Int {
        let available = max(1, ProcessInfo.processInfo.activeProcessorCount)
        switch level {
        case .slow:
            return 1
        case .medium:
            return min(2, available)
        case .fast:
            // Keep one logical core free so the Mac remains responsive.
            return max(1, available - 1)
        case .veryFast:
            return available
        }
    }
}

private final class SherpaEngine: @unchecked Sendable {
    private let pointer: OpaquePointer

    init(model: VoiceModel) throws {
        var created: OpaquePointer?
        model.model.path.withCString { modelPath in
            model.tokens.path.withCString { tokensPath in
                model.dataDirectory.path.withCString { dataPath in
                    "cpu".withCString { provider in
                        "".withCString { empty in
                            var config = SherpaOnnxOfflineTtsConfig()
                            config.model.vits.model = modelPath
                            config.model.vits.lexicon = empty
                            config.model.vits.tokens = tokensPath
                            config.model.vits.data_dir = dataPath
                            config.model.vits.noise_scale = 0.667
                            config.model.vits.noise_scale_w = 0.8
                            config.model.vits.length_scale = 1
                            config.model.vits.dict_dir = empty
                            config.model.num_threads = Int32(SynthesisPerformance.threadCount)
                            config.model.debug = 0
                            config.model.provider = provider
                            config.rule_fsts = empty
                            config.rule_fars = empty
                            config.max_num_sentences = 1
                            config.silence_scale = 0.2
                            created = SherpaOnnxCreateOfflineTts(&config)
                        }
                    }
                }
            }
        }
        guard let created else {
            throw ReaderFailure.invalidVoiceModel(
                "Use a sherpa-onnx converted Piper model with tokens.txt and espeak-ng-data."
            )
        }
        pointer = created
    }

    deinit {
        SherpaOnnxDestroyOfflineTts(pointer)
    }

    func generate(text: String, flag: CancellationFlag) throws -> (samples: [Float], sampleRate: Int) {
        let started = ContinuousClock.now
        var output: UnsafePointer<SherpaOnnxGeneratedAudio>?
        var config = SherpaOnnxGenerationConfig()
        config.silence_scale = 0.2
        config.speed = 1
        config.sid = 0
        config.num_steps = 1

        let retained = Unmanaged.passRetained(flag)
        defer { retained.release() }
        text.withCString { value in
            output = SherpaOnnxOfflineTtsGenerateWithConfig(
                pointer,
                value,
                &config,
                synthesisProgressCallback,
                retained.toOpaque()
            )
        }
        guard let output else {
            if flag.didTimeOut {
                throw ReaderFailure.synthesisFailed(
                    "The voice engine timed out while processing a text chunk."
                )
            }
            throw CancellationError()
        }
        defer { SherpaOnnxDestroyOfflineTtsGeneratedAudio(output) }
        let count = Int(output.pointee.n)
        guard count > 0, let raw = output.pointee.samples else {
            throw ReaderFailure.synthesisFailed("The voice runtime returned no samples.")
        }
        let result = (
            Array(UnsafeBufferPointer(start: raw, count: count)),
            Int(output.pointee.sample_rate)
        )
        Logger.synthesis.info("TTS inference \(text.count) chars in \(elapsed(started), privacy: .public) seconds")
        return result
    }
}

actor LocalSynthesizer {
    private var engine: SherpaEngine?
    private var engineVoiceID: String?
    private var engineThreadCount: Int?

    func synthesize(
        paragraphs: [ParagraphRecord],
        voice: VoiceModel,
        cacheDirectory: URL,
        gap: TimeInterval = 0.30,
        progress: @escaping @Sendable (AudioGenerationProgress) -> Void = { _ in }
    ) async throws -> (timeline: [ParagraphRecord], audiobook: URL) {
        let modelStarted = ContinuousClock.now
        let threadCount = SynthesisPerformance.threadCount
        if engineVoiceID != voice.id || engineThreadCount != threadCount {
            engine = try SherpaEngine(model: voice)
            engineVoiceID = voice.id
            engineThreadCount = threadCount
            Logger.synthesis.info("Loaded voice \(voice.id, privacy: .public) in \(elapsed(modelStarted), privacy: .public) seconds")
        }
        guard let engine else {
            throw ReaderFailure.synthesisFailed("The local engine could not be initialized.")
        }

        try FileManager.default.createDirectory(
            at: cacheDirectory,
            withIntermediateDirectories: true
        )
        let flag = CancellationFlag()
        progress(AudioGenerationProgress(
            completedParagraphs: 0,
            totalParagraphs: paragraphs.count,
            phase: .generatingParagraphs
        ))

        return try await withTaskCancellationHandler {
            var clips: [AudioClipMeasurement] = []
            var clipURLs: [URL] = []
            for (index, paragraph) in paragraphs.enumerated() {
                try Task.checkCancellation()
                let clipURL = cacheDirectory.appendingPathComponent(
                    String(format: "%05d-%@.wav", index, paragraph.id.uuidString)
                )
                if FileManager.default.fileExists(atPath: clipURL.path),
                   ((try? AudioFiles.duration(of: clipURL)) ?? 0) <= 0 {
                    try FileManager.default.removeItem(at: clipURL)
                }
                if !FileManager.default.fileExists(atPath: clipURL.path) {
                    // Larger requests reduce per-call setup and usually make
                    // long documents substantially faster, while keeping the
                    // paragraph clip intact for timeline and resume support.
                    let chunks = SynthesisTextChunker.chunks(
                        from: paragraph.text,
                        maximumCharacters: 800,
                        combineSentences: true
                    )
                    guard !chunks.isEmpty else {
                        progress(AudioGenerationProgress(
                            completedParagraphs: index + 1,
                            totalParagraphs: paragraphs.count,
                            phase: .generatingParagraphs
                        ))
                        continue
                    }
                    var samples: [Float] = []
                    var sampleRate: Int?
                    for (chunkIndex, chunk) in chunks.enumerated() {
                        try Task.checkCancellation()
                        flag.beginChunk(timeout: .seconds(120))
                        let generated = try engine.generate(text: chunk, flag: flag)
                        if let sampleRate, sampleRate != generated.sampleRate {
                            throw ReaderFailure.synthesisFailed(
                                "The voice engine changed sample rates during generation."
                            )
                        }
                        sampleRate = generated.sampleRate
                        samples.append(contentsOf: generated.samples)
                        if chunkIndex < chunks.count - 1 {
                            samples.append(contentsOf: repeatElement(
                                0,
                                count: Int(Double(generated.sampleRate) * 0.08)
                            ))
                        }
                    }
                    guard let sampleRate else {
                        throw ReaderFailure.synthesisFailed("No readable text was available.")
                    }
                    try AudioFiles.writeWAV(
                        samples: samples,
                        sampleRate: sampleRate,
                        to: clipURL
                    )
                }
                let duration = try AudioFiles.duration(of: clipURL)
                clips.append(AudioClipMeasurement(
                    paragraphID: paragraph.id,
                    fileName: clipURL.lastPathComponent,
                    duration: duration
                ))
                clipURLs.append(clipURL)
                progress(AudioGenerationProgress(
                    completedParagraphs: index + 1,
                    totalParagraphs: paragraphs.count,
                    phase: .generatingParagraphs
                ))
            }
            let concatenateStarted = ContinuousClock.now
            progress(AudioGenerationProgress(
                completedParagraphs: paragraphs.count,
                totalParagraphs: paragraphs.count,
                phase: .assembling
            ))
            let timeline = try TimelineBuilder.build(paragraphs: paragraphs, clips: clips, gap: gap)
            let audiobook = cacheDirectory.appendingPathComponent("audiobook.caf")
            try AudioFiles.concatenate(clipURLs, gap: gap, to: audiobook)
            Logger.synthesis.info("Concatenated \(clipURLs.count) clips in \(elapsed(concatenateStarted), privacy: .public) seconds")
            return (timeline, audiobook)
        } onCancel: {
            flag.cancel()
        }
    }
}

private extension Logger {
    // Keep logger creation in an accessor so this non-Sendable SDK value is
    // not stored as shared static state under Swift 6 strict concurrency.
    static var synthesis: Logger {
        Logger(subsystem: "AudioPDF", category: "synthesis")
    }
}

private func elapsed(_ start: ContinuousClock.Instant) -> Double {
    let components = start.duration(to: .now).components
    return Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
}
