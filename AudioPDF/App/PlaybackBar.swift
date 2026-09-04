import SwiftUI

struct PlaybackBar: View {
    @ObservedObject var controller: ReaderController
    @ObservedObject private var playback: PlaybackController

    init(controller: ReaderController) {
        self.controller = controller
        self.playback = controller.playback
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text(format(playback.currentTime))
                    .monospacedDigit()
                    .frame(width: 54, alignment: .trailing)
                Slider(
                    value: Binding(
                        get: { playback.currentTime },
                        set: { controller.seek(to: $0) }
                    ),
                    in: 0...max(playback.duration, 0.001),
                    onEditingChanged: controller.setScrubbing
                )
                .accessibilityLabel("Playback position")
                .accessibilityValue("\(format(playback.currentTime)) of \(format(playback.duration))")
                .disabled(!controller.isAudioReady)
                Text(format(playback.duration))
                    .monospacedDigit()
                    .frame(width: 54, alignment: .leading)
            }

            HStack(spacing: 16) {
                Button {
                    controller.moveByParagraph(-1)
                } label: {
                    Label("Previous paragraph", systemImage: "backward.end.fill")
                        .labelStyle(.iconOnly)
                }
                .help("Previous paragraph")
                .disabled(!controller.isAudioReady)
                Button {
                    controller.skip(by: -10)
                } label: {
                    Label("Back 10 seconds", systemImage: "gobackward.10")
                        .labelStyle(.iconOnly)
                }
                .help("Back 10 seconds")
                .disabled(!controller.isAudioReady)
                Button {
                    controller.togglePlayback()
                } label: {
                    Label(
                        playback.isPlaying ? "Pause" : "Play",
                        systemImage: playback.isPlaying ? "pause.fill" : "play.fill"
                    )
                    .labelStyle(.iconOnly)
                    .font(.title2)
                }
                .disabled(!controller.isAudioReady)
                Button {
                    controller.skip(by: 10)
                } label: {
                    Label("Forward 10 seconds", systemImage: "goforward.10")
                        .labelStyle(.iconOnly)
                }
                .help("Forward 10 seconds")
                .disabled(!controller.isAudioReady)
                Button {
                    controller.moveByParagraph(1)
                } label: {
                    Label("Next paragraph", systemImage: "forward.end.fill")
                        .labelStyle(.iconOnly)
                }
                .help("Next paragraph")
                .disabled(!controller.isAudioReady)

                Divider().frame(height: 22)

                Picker(
                    "Speed",
                    selection: Binding(
                        get: { playback.rate },
                        set: { controller.setSpeed($0) }
                    )
                ) {
                    ForEach([0.5, 0.75, 1, 1.25, 1.5, 1.75, 2], id: \.self) {
                        Text("\($0, specifier: "%g")×").tag(Float($0))
                    }
                }
                .frame(width: 120)
                .disabled(!controller.isAudioReady)

                Spacer()

                if controller.currentParagraph != nil {
                    Button {
                        controller.showCurrentParagraph()
                    } label: {
                        Label(
                            controller.isPlaybackActive ? "Following text" : "Show current paragraph",
                            systemImage: controller.isPlaybackActive ? "location.fill" : "location"
                        )
                    }
                    .labelStyle(.titleAndIcon)
                    .help(
                        controller.isPlaybackActive
                            ? "The current paragraph is locked in view during playback"
                            : "Return to the paragraph at the current playback position"
                    )
                }

                switch controller.audioState {
                case .loading:
                    EmptyView()
                case .generating:
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Generating audio")
                    Button("Stop") { controller.stopSynthesis() }
                        .help("Stop audio generation; start again to resume")
                case .failed:
                    Button("Generate Audio", action: controller.synthesize)
                        .keyboardShortcut(.defaultAction)
                        .disabled(controller.voices.isEmpty)
                case .ready:
                    EmptyView()
                case .unavailable:
                    if controller.pdfDocument != nil {
                        Button("Generate Audio", action: controller.synthesize)
                            .keyboardShortcut(.defaultAction)
                            .disabled(controller.voices.isEmpty)
                    }
                }
            }
        }
        .padding(12)
        .background(.bar)
    }

    private func format(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite else { return "0:00" }
        let total = max(0, Int(seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
