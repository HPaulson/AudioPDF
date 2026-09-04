import AVFoundation
import Foundation
import os.log
#if canImport(ReaderCore)
import ReaderCore
#endif

enum AudioFiles {
    static func duration(of url: URL) throws -> TimeInterval {
        let file = try AVAudioFile(forReading: url)
        guard file.fileFormat.sampleRate > 0 else { return 0 }
        return Double(file.length) / file.fileFormat.sampleRate
    }

    static func writeWAV(samples: [Float], sampleRate: Int, to url: URL) throws {
        let started = ContinuousClock.now
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(sampleRate),
            channels: 1,
            interleaved: false
        ), let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ) else {
            throw ReaderFailure.synthesisFailed("Could not create an audio buffer.")
        }
        buffer.frameLength = buffer.frameCapacity
        samples.withUnsafeBufferPointer { source in
            if let destination = buffer.floatChannelData?[0], let base = source.baseAddress {
                destination.update(from: base, count: samples.count)
            }
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        let elapsed = started.duration(to: .now).components
        Logger.audio.info("Wrote \(samples.count, privacy: .public) samples in \(Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1_000_000_000_000_000_000, privacy: .public) seconds")
    }

    static func concatenate(_ urls: [URL], gap: TimeInterval, to output: URL) throws {
        guard let firstURL = urls.first else {
            throw ReaderFailure.synthesisFailed("There are no paragraph clips to join.")
        }
        let first = try AVAudioFile(forReading: firstURL)
        let format = first.processingFormat
        if FileManager.default.fileExists(atPath: output.path) {
            try FileManager.default.removeItem(at: output)
        }
        let destination = try AVAudioFile(forWriting: output, settings: format.settings)

        for (index, url) in urls.enumerated() {
            let source = try AVAudioFile(forReading: url)
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: source.processingFormat,
                frameCapacity: AVAudioFrameCount(source.length)
            ) else { continue }
            try source.read(into: buffer)
            try destination.write(from: buffer)

            if index < urls.count - 1 {
                let frames = AVAudioFrameCount(gap * format.sampleRate)
                if let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) {
                    silence.frameLength = frames
                    if let channels = silence.floatChannelData {
                        for channel in 0..<Int(format.channelCount) {
                            channels[channel].initialize(repeating: 0, count: Int(frames))
                        }
                    }
                    try destination.write(from: silence)
                }
            }
        }
    }
}

private extension Logger {
    static var audio: Logger {
        Logger(subsystem: "AudioPDF", category: "audio-files")
    }
}
