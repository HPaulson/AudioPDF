import Combine
import Foundation
import PDFKit
#if canImport(ReaderCore)
import ReaderCore
#endif

private struct CacheManifest: Codable {
    let paragraphs: [ParagraphRecord]
    let audiobookFile: String
}

private struct RestoredCachedAudio: Sendable {
    let paragraphs: [ParagraphRecord]
    let audio: URL
    let duration: TimeInterval
}

private func restoreCachedAudio(
    cacheKey: String,
    cacheRoot: URL,
    pdfURL: URL,
    voiceFingerprint: String,
    synthesisSettings: String
) -> RestoredCachedAudio? {
    let directory = cacheRoot.appendingPathComponent(cacheKey, isDirectory: true)
    guard let data = try? Data(contentsOf: directory.appendingPathComponent("manifest.json")),
          let manifest = try? JSONDecoder().decode(CacheManifest.self, from: data),
          !manifest.paragraphs.isEmpty else { return nil }

    // The database key is only a hint. Recompute it from the current PDF and
    // manifest so a moved/modified PDF cannot resurrect stale audio.
    guard let pdfData = try? Data(contentsOf: pdfURL),
          CacheKey.make(
              pdfData: pdfData,
              normalizedText: manifest.paragraphs.map(\.text).joined(separator: "\n\n"),
              voiceFingerprint: voiceFingerprint,
              synthesisSettings: synthesisSettings
          ) == cacheKey else { return nil }

    let audio = directory.appendingPathComponent(manifest.audiobookFile)
    guard FileManager.default.fileExists(atPath: audio.path),
          let duration = try? AudioFiles.duration(of: audio),
          duration > 0 else { return nil }
    return RestoredCachedAudio(paragraphs: manifest.paragraphs, audio: audio, duration: duration)
}

private struct ProcessingJob {
    let token: UUID
    let id: UUID
    let record: LibraryDocument
    let url: URL
    let voice: VoiceModel
}

enum DocumentAudioState: Equatable {
    case unavailable
    case loading
    case generating
    case ready
    case failed(String)
}

@MainActor
final class ReaderController: ObservableObject {
    @Published private(set) var pdfDocument: PDFDocument?
    @Published private(set) var paragraphs: [ParagraphRecord] = []
    @Published var selectedParagraphID: UUID?
    @Published private(set) var currentParagraphID: UUID?
    @Published private(set) var voices: [VoiceModel] = []
    @Published private(set) var selectedVoiceID = ""
    @Published private(set) var voiceQuality = VoiceQuality.current
    @Published private(set) var audioState: DocumentAudioState = .unavailable
    @Published private(set) var audioGenerationProgress: AudioGenerationProgress?
    @Published private(set) var generationQueuePosition: (position: Int, total: Int)?
    @Published private(set) var processingQueueIDs: [UUID] = []
    @Published private(set) var isPlaybackActive = false
    @Published private(set) var isScrubbing = false
    @Published private(set) var readerScrollRequestID = UUID()
    @Published var status = "Import a local PDF to begin."
    @Published var presentedError: Error?

    let playback = PlaybackController()
    private let synthesizer = LocalSynthesizer()
    private var selectedRecord: LibraryDocument?
    private var scopedURL: URL?
    private var processingQueue: [ProcessingJob] = []
    private var processingWorker: Task<Void, Never>?
    private var runningJobID: UUID?
    private var runningJobToken: UUID?
    private var queuedJobIDs = Set<UUID>()
    private var cancelledJobTokens = Set<UUID>()
    private var activeJobTokens: [UUID: UUID] = [:]
    private var audioProgressByDocument: [UUID: AudioGenerationProgress] = [:]
    private var libraryStore: LibraryStore?
    private var lastPersistedResumePosition: TimeInterval = 0
    private var playbackObservers: Set<AnyCancellable> = []
    private var settingsObservers: Set<AnyCancellable> = []

    init() {
        voices = VoiceModelStore.discover()
        selectedVoiceID = VoiceModelStore.voice(for: voiceQuality, in: voices)?.id ?? ""
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshVoiceForCurrentSetting() }
            .store(in: &settingsObservers)
        playback.onTimeChanged = { [weak self] time in
            self?.playbackAdvanced(to: time)
        }
        playback.$isPlaying
            .removeDuplicates()
            .sink { [weak self] isPlaying in
                guard let self else { return }
                self.isPlaybackActive = isPlaying
                if isPlaying {
                    self.selectedParagraphID = nil
                    self.requestScrollToCurrentParagraph()
                }
            }
            .store(in: &playbackObservers)
    }

    deinit {
        scopedURL?.stopAccessingSecurityScopedResource()
    }

    /// Cancels work that uses native PDF/TTS resources before AppKit exits.
    /// AppKit's termination handshake waits for this method so an intentional
    /// Quit is not mistaken for a crashed process.
    func shutdown() async {
        processingWorker?.cancel()
        playback.clear()
        await processingWorker?.value
        processingWorker = nil
        processingQueue.removeAll()
        queuedJobIDs.removeAll()
        runningJobID = nil
        runningJobToken = nil
        activeJobTokens.removeAll()
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = nil
    }

    var selectedParagraph: ParagraphRecord? {
        guard let id = selectedParagraphID else { return nil }
        return paragraphs.first { $0.id == id }
    }

    var currentParagraph: ParagraphRecord? {
        guard let id = currentParagraphID else { return nil }
        return paragraphs.first { $0.id == id }
    }

    var isAudioReady: Bool {
        audioState == .ready
    }

    func setLibraryStore(_ store: LibraryStore) {
        libraryStore = store
    }

    func setGenerationQueuePosition(_ position: (position: Int, total: Int)?) {
        generationQueuePosition = position
    }

    func cancelProcessing(for documentIDs: Set<UUID>) {
        guard !documentIDs.isEmpty else { return }
        let removed = processingQueue.filter { documentIDs.contains($0.id) }
        processingQueue.removeAll { documentIDs.contains($0.id) }
        queuedJobIDs.subtract(documentIDs)
        cancelledJobTokens.formUnion(removed.map(\.token))
        if let runningJobID, documentIDs.contains(runningJobID), let runningJobToken {
            cancelledJobTokens.insert(runningJobToken)
            if activeJobTokens[runningJobID] == runningJobToken {
                activeJobTokens.removeValue(forKey: runningJobID)
            }
            processingWorker?.cancel()
        }
        refreshSelectedJobState(for: selectedRecord?.id)
        publishProcessingQueueState()
        if processingWorker != nil {
            let worker = processingWorker
            Task { @MainActor [weak self] in
                await worker?.value
                guard let self, self.processingWorker == nil else { return }
                self.startProcessingWorker()
            }
        } else {
            startProcessingWorker()
        }
    }

    func refreshVoices() {
        voices = VoiceModelStore.discover()
        refreshVoiceForCurrentSetting()
    }

    private func refreshVoiceForCurrentSetting() {
        let newQuality = VoiceQuality.current
        let newVoiceID = VoiceModelStore.voice(for: newQuality, in: voices)?.id ?? ""
        guard newQuality != voiceQuality || newVoiceID != selectedVoiceID else { return }
        voiceQuality = newQuality
        selectedVoiceID = newVoiceID
        guard let record = selectedRecord, pdfDocument != nil else { return }
        playback.clear()
        currentParagraphID = nil
        record.cacheKey = nil
        try? libraryStore?.save(record)
        audioState = .unavailable
        audioGenerationProgress = nil
        status = "Voice changed. Press Generate Audio to regenerate."
    }

    func load(_ record: LibraryDocument) {
        generationQueuePosition = processingQueuePosition(for: record.id)
        playback.clear()
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = nil
        selectedRecord = record
        pdfDocument = nil
        paragraphs = []
        selectedParagraphID = nil
        currentParagraphID = nil
        audioState = .loading
        audioGenerationProgress = nil
        status = "Preparing PDF…"

        do {
            var stale = false
            let url = try URL(
                resolvingBookmarkData: record.bookmark,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
            guard url.startAccessingSecurityScopedResource() else {
                throw CocoaError(.fileReadNoPermission)
            }
            scopedURL = url
            if stale {
                record.bookmark = try url.bookmarkData(
                    options: [.withSecurityScope],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
            }

            voiceQuality = VoiceQuality.current
            selectedVoiceID = VoiceModelStore.voice(for: voiceQuality, in: voices)?.id ?? ""
            if voices.isEmpty {
                throw ReaderFailure.missingVoiceModel(
                    "Install a converted voice folder from Settings → Voice Models."
                )
            }
            playback.setRate(Float(record.playbackSpeed))
            lastPersistedResumePosition = record.resumePosition
            try? libraryStore?.save(record)
            guard let document = PDFDocument(url: url) else {
                throw ReaderFailure.invalidPDF
            }
            pdfDocument = document
            audioState = record.cacheKey == nil ? .unavailable : .loading
            status = record.cacheKey == nil
                ? "PDF loaded. Press Generate Audio to begin OCR and audio generation."
                : "Checking for cached audio…"
            refreshSelectedJobState(for: record.id)

            if let cacheKey = record.cacheKey {
                let voiceFingerprint = VoiceModelStore.voice(for: voiceQuality, in: voices)?.fingerprint ?? ""
                let cacheRoot = Self.cacheRoot
                let synthesisSettings = Self.synthesisSettings
                Task { @MainActor [weak self] in
                    let cached = await Task.detached(priority: .utility) {
                        restoreCachedAudio(
                            cacheKey: cacheKey,
                            cacheRoot: cacheRoot,
                            pdfURL: url,
                            voiceFingerprint: voiceFingerprint,
                            synthesisSettings: synthesisSettings
                        )
                    }.value

                    guard let self,
                          self.selectedRecord?.id == record.id,
                          self.scopedURL == url else { return }

                    if let cached {
                        record.cacheKey = cacheKey
                        record.audioDuration = cached.duration
                        try? self.libraryStore?.save(record)
                        do {
                            self.paragraphs = cached.paragraphs
                            try self.playback.load(
                                url: cached.audio,
                                resumeAt: record.resumePosition,
                                rate: Float(record.playbackSpeed)
                            )
                            self.requestScrollToCurrentParagraph()
                            self.audioState = .ready
                            self.status = "Audio is ready and cached for offline playback."
                        } catch {
                            self.audioState = .failed(error.localizedDescription)
                            self.status = error.localizedDescription
                        }
                    } else {
                        record.cacheKey = nil
                        try? self.libraryStore?.save(record)
                        self.audioState = .unavailable
                        self.status = "PDF loaded. Press Generate Audio to begin OCR and audio generation."
                    }
                }
            }
        } catch {
            scopedURL?.stopAccessingSecurityScopedResource()
            scopedURL = nil
            pdfDocument = nil
            paragraphs = []
            selectedRecord = nil
            playback.clear()
            audioState = .failed(error.localizedDescription)
            presentedError = error
            status = error.localizedDescription
        }
    }

    func unload() {
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = nil
        selectedRecord = nil
        pdfDocument = nil
        paragraphs = []
        selectedParagraphID = nil
        currentParagraphID = nil
        playback.clear()
        audioState = .unavailable
        audioGenerationProgress = nil
        status = "Select or import a local PDF."
    }

    func synthesize() {
        guard let voice = voices.first(where: { $0.id == selectedVoiceID }) else {
            let error = ReaderFailure.missingVoiceModel(
                "Install a converted voice folder from Settings → Voice Models."
            )
            audioState = .failed(error.localizedDescription)
            presentedError = error
            status = error.localizedDescription
            return
        }
        guard let record = selectedRecord, let url = scopedURL else { return }
        enqueue(record: record, url: url, voice: voice)
    }

    /// Queues audio generation for the supplied library documents in their
    /// library order. The selected document, if any, continues to drive the
    /// reader UI while the queue processes the rest in the background.
    func synthesize(documentIDs: Set<UUID>) {
        guard !documentIDs.isEmpty else { return }
        guard let voice = voices.first(where: { $0.id == selectedVoiceID }) else {
            let error = ReaderFailure.missingVoiceModel(
                "Install a converted voice folder from Settings → Voice Models."
            )
            presentedError = error
            status = error.localizedDescription
            return
        }

        let records = libraryStore?.documents.filter { documentIDs.contains($0.id) } ?? []
        for record in records {
            do {
                var stale = false
                let url = try URL(
                    resolvingBookmarkData: record.bookmark,
                    options: [.withSecurityScope],
                    relativeTo: nil,
                    bookmarkDataIsStale: &stale
                )
                if stale {
                    record.bookmark = try url.bookmarkData(
                        options: [.withSecurityScope],
                        includingResourceValuesForKeys: nil,
                        relativeTo: nil
                    )
                    try? libraryStore?.save(record)
                }
                enqueue(record: record, url: url, voice: voice)
            } catch {
                if selectedRecord?.id == record.id {
                    audioState = .failed(error.localizedDescription)
                    status = error.localizedDescription
                }
                presentedError = error
            }
        }
    }

    /// Stops the current synthesis task. Any completed paragraph clips remain in
    /// the cache, so starting again resumes from the last completed paragraph.
    func stopSynthesis() {
        guard let id = selectedRecord?.id else { return }
        stopSynthesis(for: [id])
    }

    /// Stops queued or active synthesis for all supplied documents. Completed
    /// paragraph clips remain cached and can be resumed later.
    func stopSynthesis(for documentIDs: Set<UUID>) {
        guard !documentIDs.isEmpty else { return }

        cancelProcessing(for: documentIDs)
        for id in documentIDs {
            audioProgressByDocument[id] = nil
        }
        guard let id = selectedRecord?.id, documentIDs.contains(id) else { return }
        audioGenerationProgress = nil
        generationQueuePosition = processingQueuePosition(for: id)
        audioState = .unavailable
        status = "Audio generation stopped. Press Generate Audio to resume."
    }

    func isProcessing(documentIDs: Set<UUID>) -> Bool {
        documentIDs.contains { id in
            runningJobID == id || processingQueue.contains { $0.id == id }
        }
    }

    func processingQueuePosition(for documentID: UUID) -> (position: Int, total: Int)? {
        let ids = (runningJobID.map { [$0] } ?? []) + processingQueue.map(\.id)
        guard let index = ids.firstIndex(of: documentID) else { return nil }
        return (index + 1, ids.count)
    }

    private func enqueue(record: LibraryDocument, url: URL, voice: VoiceModel) {
        let id = record.id
        let runningJobWasCancelled = runningJobID == id
            && runningJobToken.map { cancelledJobTokens.contains($0) } == true
        if (runningJobID == id && !runningJobWasCancelled)
            || processingQueue.contains(where: { $0.id == id }) {
            let existing = processingQueue.first(where: { $0.id == id })
            if existing?.voice.id == voice.id || (runningJobID == id && !runningJobWasCancelled) {
                refreshSelectedJobState(for: id)
                return
            }
            cancelProcessing(for: [id])
        }

        let job = ProcessingJob(token: UUID(), id: id, record: record, url: url, voice: voice)
        processingQueue.append(job)
        activeJobTokens[id] = job.token
        queuedJobIDs.insert(id)
        publishProcessingQueueState()
        refreshSelectedJobState(for: id)
        startProcessingWorker()
    }

    private func drainProcessingQueue() async {
        while !Task.isCancelled, !processingQueue.isEmpty {
            let job = processingQueue.removeFirst()
            queuedJobIDs.remove(job.id)
            runningJobID = job.id
            runningJobToken = job.token
            publishProcessingQueueState()
            await process(job)
            cancelledJobTokens.remove(job.token)
            if activeJobTokens[job.id] == job.token { activeJobTokens.removeValue(forKey: job.id) }
            if runningJobToken == job.token {
                runningJobID = nil
                runningJobToken = nil
            }
            publishProcessingQueueState()
            refreshSelectedJobState(for: selectedRecord?.id)
        }
        processingWorker = nil
        if !Task.isCancelled, !processingQueue.isEmpty { startProcessingWorker() }
    }

    private func startProcessingWorker() {
        guard processingWorker == nil, !processingQueue.isEmpty else { return }
        processingWorker = Task { [weak self] in
            await self?.drainProcessingQueue()
        }
    }

    private func isCurrent(_ job: ProcessingJob) -> Bool {
        !Task.isCancelled && !cancelledJobTokens.contains(job.token)
    }

    private func process(_ job: ProcessingJob) async {
        do {
            try Task.checkCancellation()
            guard isCurrent(job) else { throw CancellationError() }
            let accessed = job.url.startAccessingSecurityScopedResource()
            defer { if accessed { job.url.stopAccessingSecurityScopedResource() } }
            let pdfData = try Data(contentsOf: job.url, options: .mappedIfSafe)
            let sourceKey = CacheKey.sourceFingerprint(pdfData: pdfData)
            let extractionURL = Self.extractionRoot.appendingPathComponent("\(sourceKey).json")
            let ocrCheckpointURL = Self.extractionRoot.appendingPathComponent("\(sourceKey).ocr.json")
            try FileManager.default.createDirectory(at: Self.extractionRoot, withIntermediateDirectories: true)

            let paragraphs: [ParagraphRecord]
            if let data = try? Data(contentsOf: extractionURL),
               let cached = try? JSONDecoder().decode([ParagraphRecord].self, from: data),
               !cached.isEmpty {
                paragraphs = cached
            } else {
                let jobURL = job.url
                let checkpointURL = ocrCheckpointURL
                let extracted = try await Task.detached(priority: .userInitiated) {
                    try PDFExtractor.extract(
                        from: jobURL,
                        ocrCheckpoint: (try? Data(contentsOf: checkpointURL)).flatMap {
                            try? JSONDecoder().decode(OCRCheckpoint.self, from: $0)
                        },
                        checkpoint: { checkpoint in
                            try? JSONEncoder().encode(checkpoint).write(to: checkpointURL, options: .atomic)
                        }
                    )
                }.value
                paragraphs = extracted
                try JSONEncoder().encode(paragraphs).write(to: extractionURL, options: .atomic)
                try? FileManager.default.removeItem(at: ocrCheckpointURL)
            }

            try Task.checkCancellation()
            guard isCurrent(job) else { throw CancellationError() }

            if selectedRecord?.id == job.id {
                pdfDocument = PDFDocument(url: job.url)
                guard pdfDocument != nil else { throw ReaderFailure.invalidPDF }
                self.paragraphs = paragraphs
                audioState = .generating
                status = "Queued for audio generation…"
            }

            let normalized = paragraphs.map(\.text).joined(separator: "\n\n")
            let key = CacheKey.make(
                pdfData: pdfData,
                normalizedText: normalized,
                voiceFingerprint: job.voice.fingerprint,
                synthesisSettings: Self.synthesisSettings
            )
            let directory = Self.cacheRoot.appendingPathComponent(key, isDirectory: true)
            if let cached = validCachedAudio(in: directory, expectedParagraphs: paragraphs) {
                job.record.cacheKey = key
                job.record.audioDuration = (try? AudioFiles.duration(of: cached.audio)) ?? job.record.audioDuration
                try? libraryStore?.save(job.record)
                finishSelectedDocument(job, timeline: cached.timeline, audiobook: cached.audio)
                return
            }

            let initial = AudioGenerationProgress(completedParagraphs: 0, totalParagraphs: paragraphs.count, phase: .generatingParagraphs)
            audioProgressByDocument[job.id] = initial
            publishAudioProgress(for: job.id, token: job.token, initial)
            let jobID = job.id
            let jobToken = job.token
            let generated = try await synthesizer.synthesize(
                paragraphs: paragraphs,
                voice: job.voice,
                cacheDirectory: directory,
                progress: { [weak self] progress in
                    Task { @MainActor [weak self] in
                        self?.publishAudioProgress(for: jobID, token: jobToken, progress)
                    }
                }
            )
            try Task.checkCancellation()
            guard isCurrent(job) else { throw CancellationError() }
            try saveManifest(timeline: generated.timeline, directory: directory)
            job.record.cacheKey = key
            job.record.audioDuration = (try? AudioFiles.duration(of: generated.audiobook)) ?? job.record.audioDuration
            try? libraryStore?.save(job.record)
            audioProgressByDocument[job.id] = nil
            finishSelectedDocument(job, timeline: generated.timeline, audiobook: generated.audiobook)
        } catch is CancellationError {
            // Cancellation is an expected state transition when a document is
            // deleted, unloaded, or its voice/input version changes.
            if !cancelledJobTokens.contains(job.token) && selectedRecord?.id == job.id {
                publishError(for: job.id, token: job.token, message: "Processing paused; Generate Audio again to resume.")
            }
        } catch {
            publishError(for: job.id, token: job.token, message: error.localizedDescription)
        }
    }

    private func finishSelectedDocument(_ job: ProcessingJob, timeline: [ParagraphRecord], audiobook: URL) {
        guard isCurrent(job), selectedRecord?.id == job.id else { return }
        paragraphs = timeline
        do {
            try playback.load(url: audiobook, resumeAt: job.record.resumePosition, rate: Float(job.record.playbackSpeed))
            requestScrollToCurrentParagraph()
            audioState = .ready
            audioGenerationProgress = nil
            status = "Audio is ready and cached for offline playback."
        } catch {
            publishError(for: job.id, token: job.token, message: error.localizedDescription)
        }
    }

    private func publishAudioProgress(for id: UUID, token: UUID, _ progress: AudioGenerationProgress) {
        guard activeJobTokens[id] == token else { return }
        audioProgressByDocument[id] = progress
        guard selectedRecord?.id == id else { return }
        audioGenerationProgress = progress
        audioState = .generating
        status = "Generating audio…"
    }

    private func publishError(for id: UUID, token: UUID, message: String) {
        guard activeJobTokens[id] == token else { return }
        guard selectedRecord?.id == id else { return }
        audioState = .failed(message)
        audioGenerationProgress = nil
        status = message
    }

    private func refreshSelectedJobState(for id: UUID?) {
        guard let id, selectedRecord?.id == id else { return }
        audioGenerationProgress = audioProgressByDocument[id]
        if runningJobID == id || queuedJobIDs.contains(id) {
            audioState = .loading
            status = processingQueuePosition(for: id).map { "Queued for processing · \($0.position) of \($0.total)…" } ?? "Queued for processing…"
        }
    }

    private func publishProcessingQueueState() {
        processingQueueIDs = (runningJobID.map { [$0] } ?? []) + processingQueue.map(\.id)
    }

    private func validCachedAudio(in directory: URL, expectedParagraphs: [ParagraphRecord]) -> (timeline: [ParagraphRecord], audio: URL)? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("manifest.json")),
              let manifest = try? JSONDecoder().decode(CacheManifest.self, from: data),
              !manifest.paragraphs.isEmpty,
              manifest.paragraphs.map(\.text) == expectedParagraphs.map(\.text) else { return nil }
        let audio = directory.appendingPathComponent(manifest.audiobookFile)
        guard FileManager.default.fileExists(atPath: audio.path),
              (try? AudioFiles.duration(of: audio)) ?? 0 > 0 else { return nil }
        return (manifest.paragraphs, audio)
    }

    func setSpeed(_ speed: Float) {
        playback.setRate(speed)
        selectedRecord?.playbackSpeed = Double(playback.rate)
        if let record = selectedRecord {
            try? libraryStore?.save(record)
        }
    }

    func togglePlayback() {
        playback.isPlaying ? pause() : play()
    }

    func play() {
        guard isAudioReady else { return }
        playback.play()
    }

    func pause() {
        playback.pause()
    }

    func skip(by seconds: TimeInterval) {
        playback.skip(by: seconds)
    }

    func adjustSpeed(by offset: Int) {
        let rates: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2]
        guard let currentIndex = rates.indices.min(by: {
            abs(rates[$0] - playback.rate) < abs(rates[$1] - playback.rate)
        }) else { return }
        let destination = min(max(currentIndex + offset, rates.startIndex), rates.index(before: rates.endIndex))
        setSpeed(rates[destination])
    }

    func seek(to time: TimeInterval) {
        playback.seek(to: time)
    }

    func setScrubbing(_ scrubbing: Bool) {
        isScrubbing = scrubbing
        if !scrubbing, isPlaybackActive {
            requestScrollToCurrentParagraph()
        }
    }

    func selectParagraph(_ id: UUID) {
        guard paragraphs.contains(where: { $0.id == id }) else { return }
        selectedParagraphID = id
    }

    func clearParagraphSelection() {
        selectedParagraphID = nil
    }

    func playFromHere(at paragraphID: UUID) {
        guard isAudioReady,
              let paragraph = paragraphs.first(where: { $0.id == paragraphID }) else { return }
        selectedParagraphID = nil
        playback.seek(to: paragraph.audioStart)
        currentParagraphID = paragraph.id
        requestScrollToCurrentParagraph()
        playback.play()
    }

    func showCurrentParagraph() {
        requestScrollToCurrentParagraph()
    }

    func moveByParagraph(_ offset: Int) {
        guard isAudioReady, !paragraphs.isEmpty else { return }
        let currentIndex = currentParagraphID.flatMap { id in
            paragraphs.firstIndex(where: { $0.id == id })
        } ?? 0
        let destination = min(max(0, currentIndex + offset), paragraphs.count - 1)
        if isPlaybackActive {
            playFromHere(at: paragraphs[destination].id)
        } else {
            guard let paragraph = paragraphs.first(where: { $0.id == paragraphs[destination].id }) else { return }
            selectedParagraphID = nil
            playback.seek(to: paragraph.audioStart)
            currentParagraphID = paragraph.id
            requestScrollToCurrentParagraph()
        }
    }

    private func playbackAdvanced(to time: TimeInterval) {
        if let index = TimelineBuilder.paragraphIndex(at: time, in: paragraphs) {
            let id = paragraphs[index].id
            if currentParagraphID != id {
                currentParagraphID = id
            }
        }
        selectedRecord?.resumePosition = time
        if abs(time - lastPersistedResumePosition) >= 1,
           let record = selectedRecord {
            lastPersistedResumePosition = time
            try? libraryStore?.save(record)
        }
    }

    private func requestScrollToCurrentParagraph() {
        guard currentParagraphID != nil else { return }
        readerScrollRequestID = UUID()
    }

    private func saveManifest(timeline: [ParagraphRecord], directory: URL) throws {
        let manifest = CacheManifest(paragraphs: timeline, audiobookFile: "audiobook.caf")
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: directory.appendingPathComponent("manifest.json"), options: .atomic)
    }

    private static var cacheRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AudioPDF/AudioCache", isDirectory: true)
    }

    private static var extractionRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AudioPDF/ExtractionCache", isDirectory: true)
    }

    private static let synthesisSettings =
        "gap=0.30|chunk=800-combined|chunk-gap=0.08|engine=sherpa-onnx|voice-quality-v1"
}
