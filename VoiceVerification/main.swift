import Foundation
import SherpaOnnxRuntime

private let keepGenerating:
    @convention(c) (UnsafePointer<Float>?, Int32, Float, UnsafeMutableRawPointer?) -> Int32 = {
        _, _, _, _ in 1
    }

@main
enum VoiceVerification {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            fatalError("Usage: VoiceVerification /path/to/voice-folder")
        }

        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let children = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        guard let model = children.first(where: { $0.pathExtension == "onnx" }),
              let tokens = children.first(where: { $0.lastPathComponent == "tokens.txt" }) else {
            fatalError("Voice folder is incomplete: \(directory.path)")
        }
        let dataDirectory = directory.appendingPathComponent("espeak-ng-data", isDirectory: true)
        guard FileManager.default.fileExists(atPath: dataDirectory.path) else {
            fatalError("Voice folder has no espeak-ng-data: \(directory.path)")
        }

        var tts: OpaquePointer?
        model.path.withCString { modelPath in
            tokens.path.withCString { tokensPath in
                dataDirectory.path.withCString { dataPath in
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
                            config.model.num_threads = 2
                            config.model.debug = 0
                            config.model.provider = provider
                            config.rule_fsts = empty
                            config.rule_fars = empty
                            config.max_num_sentences = 1
                            config.silence_scale = 0.2
                            tts = SherpaOnnxCreateOfflineTts(&config)
                        }
                    }
                }
            }
        }
        guard let tts else {
            fatalError("Could not load voice: \(directory.lastPathComponent)")
        }
        defer { SherpaOnnxDestroyOfflineTts(tts) }

        var generation = SherpaOnnxGenerationConfig()
        generation.silence_scale = 0.2
        generation.speed = 1
        generation.sid = 0
        generation.num_steps = 1
        var audio: UnsafePointer<SherpaOnnxGeneratedAudio>?
        "The quick brown fox jumps over the lazy dog.".withCString { text in
            audio = SherpaOnnxOfflineTtsGenerateWithConfig(
                tts,
                text,
                &generation,
                keepGenerating,
                nil
            )
        }
        guard let audio else {
            fatalError("Voice generated no audio: \(directory.lastPathComponent)")
        }
        defer { SherpaOnnxDestroyOfflineTtsGeneratedAudio(audio) }
        guard audio.pointee.n > 0, audio.pointee.sample_rate > 0 else {
            fatalError("Voice generated empty audio: \(directory.lastPathComponent)")
        }
        let duration = Double(audio.pointee.n) / Double(audio.pointee.sample_rate)
        print("\(directory.lastPathComponent): generated \(String(format: "%.2f", duration)) seconds")
    }
}
