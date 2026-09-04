import AVFoundation
import Combine
import Foundation
#if canImport(ReaderCore)
import ReaderCore
#endif

@preconcurrency @MainActor
final class PlaybackController: NSObject, ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var rate: Float = 1

    var onTimeChanged: ((TimeInterval) -> Void)?
    private var player: AVAudioPlayer?
    private var timer: Timer?
    private let delegate = PlaybackDelegate()

    override init() {
        super.init()
        delegate.onFinish = { [weak self] in
            Task { @MainActor in self?.didFinishPlaying() }
        }
    }

    func setRate(_ value: Float) {
        let normalized = PlaybackRate.normalize(value)
        rate = normalized
        player?.rate = normalized
    }

    func load(url: URL, resumeAt: TimeInterval = 0, rate: Float = 1) throws {
        clear()
        let player = try AVAudioPlayer(contentsOf: url)
        player.delegate = delegate
        player.enableRate = true
        player.prepareToPlay()
        self.player = player
        duration = player.duration
        setRate(rate)
        player.rate = self.rate
        seek(to: resumeAt)
    }

    func clear() {
        player?.stop()
        player = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        stopTimer()
    }

    func toggle() { isPlaying ? pause() : play() }

    func play() {
        guard let player else { return }
        if player.currentTime >= player.duration {
            player.currentTime = 0
            updateTime()
        }
        player.rate = rate
        isPlaying = player.play()
        if isPlaying { startTimer() }
    }

    func pause() {
        player?.pause()
        isPlaying = false
        stopTimer()
        updateTime()
    }

    func stop() {
        player?.stop()
        player?.currentTime = 0
        isPlaying = false
        stopTimer()
        updateTime()
    }

    func skip(by seconds: TimeInterval) { seek(to: currentTime + seconds) }

    func seek(to time: TimeInterval) {
        guard let player else { return }
        player.currentTime = TimelineBuilder.clampSeek(time, duration: player.duration)
        updateTime()
    }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(
            timeInterval: 0.05,
            target: self,
            selector: #selector(timerTick(_:)),
            userInfo: nil,
            repeats: true
        )
    }

    @objc private func timerTick(_ timer: Timer) {
        updateTime()
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func updateTime() {
        currentTime = player?.currentTime ?? 0
        onTimeChanged?(currentTime)
    }
    private func didFinishPlaying() {
        isPlaying = false
        stopTimer()
        updateTime()
    }
}

private final class PlaybackDelegate: NSObject, AVAudioPlayerDelegate {
    var onFinish: (() -> Void)?

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        onFinish?()
    }
}
