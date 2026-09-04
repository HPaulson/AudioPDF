import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @State private var importing = false
    @State private var message = ""
    @AppStorage(VoiceQuality.userDefaultsKey) private var voiceQuality = VoiceQuality.defaultValue.rawValue
    @AppStorage(SynthesisPerformance.userDefaultsKey) private var performance = SynthesisPerformance.Level.medium.rawValue

    var body: some View {
        Form {
            Section("Local voice models") {
                Text(
                    "Install a sherpa-onnx converted Piper voice folder containing an ONNX model, tokens.txt, and espeak-ng-data. Files stay on this Mac and the app never downloads models."
                )
                .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Install Voice Folder…") { importing = true }
                    Button("Show Voice Folder") {
                        try? VoiceModelStore.ensureDirectory()
                        NSWorkspace.shared.open(VoiceModelStore.applicationSupport)
                    }
                }
                if !message.isEmpty {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Voice quality") {
                Picker("Quality", selection: $voiceQuality) {
                    ForEach(VoiceQuality.allCases) { quality in
                        Text("\(quality.displayName) · \(quality.detail)").tag(quality.rawValue)
                    }
                }
                .pickerStyle(.radioGroup)
                Text("This is an app-wide setting. It applies to every PDF and starts regenerating the open PDF when changed. Low quality is intended for near-immediate generation, while Very high quality may take substantially longer.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("Audio generation performance") {
                Picker("CPU usage", selection: $performance) {
                    ForEach(SynthesisPerformance.Level.allCases) { level in
                        Text(level.displayName).tag(level.rawValue)
                    }
                }
                .pickerStyle(.menu)
                Text("This controls how much CPU is devoted to generating audio, independently of voice quality. Medium is the default. Fast leaves one logical core free; Very Fast uses all available cores and may make the Mac loud or less responsive.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 620, height: 470)
        .fileImporter(
            isPresented: $importing,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            do {
                guard let source = try result.get().first else { return }
                let accessed = source.startAccessingSecurityScopedResource()
                defer { if accessed { source.stopAccessingSecurityScopedResource() } }
                try VoiceModelStore.ensureDirectory()
                let destination = VoiceModelStore.applicationSupport
                    .appendingPathComponent(source.lastPathComponent, isDirectory: true)
                guard !FileManager.default.fileExists(atPath: destination.path) else {
                    message = "A voice with that folder name already exists. Rename it or remove the old folder first."
                    return
                }
                try FileManager.default.copyItem(at: source, to: destination)
                message = "Installed \(source.lastPathComponent). Reopen the reader window to refresh the voice list."
            } catch {
                message = error.localizedDescription
            }
        }
    }
}
