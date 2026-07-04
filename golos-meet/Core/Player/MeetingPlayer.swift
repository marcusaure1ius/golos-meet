import Foundation
import AVFoundation
import Combine

/// Синхронное воспроизведение двух дорожек встречи (mic + system) как одной записи.
/// Обе стартуют в t=0, поэтому играют/сикаются вместе по общему таймлайну.
@MainActor
final class MeetingPlayer: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    let duration: TimeInterval

    private var players: [AVAudioPlayer] = []
    private var ticker: Timer?

    var hasAudio: Bool { !players.isEmpty }

    init(folder: URL) {
        var loaded: [AVAudioPlayer] = []
        for name in ["mic.wav", "system.wav"] {
            let url = folder.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path),
                  let p = try? AVAudioPlayer(contentsOf: url) else { continue }
            p.prepareToPlay()
            loaded.append(p)
        }
        self.players = loaded
        self.duration = loaded.map(\.duration).max() ?? 0
    }

    deinit { ticker?.invalidate() }

    func toggle() {
        guard hasAudio else { return }
        if isPlaying { pause() } else { play() }
    }

    private func play() {
        // Выровнять дорожки к общему времени перед синхронным стартом (гасит дрейф после пауз).
        for p in players { p.currentTime = min(currentTime, p.duration) }
        // Синхронный старт: назначаем общий deviceCurrentTime + небольшой префикс.
        let at = (players.first?.deviceCurrentTime ?? 0) + 0.02
        for p in players { p.play(atTime: at) }
        isPlaying = true
        startTicker()
    }

    private func pause() {
        for p in players { p.pause() }
        isPlaying = false
        ticker?.invalidate(); ticker = nil
        syncCurrentTime()
    }

    func stop() {
        for p in players { p.stop(); p.currentTime = 0 }
        isPlaying = false
        ticker?.invalidate(); ticker = nil
        currentTime = 0
    }

    /// Перемотка на общий таймкод (клампится в [0, duration]).
    func seek(to t: TimeInterval) {
        let clamped = min(max(0, t), duration)
        for p in players { p.currentTime = min(clamped, p.duration) }
        currentTime = clamped
    }

    private func startTicker() {
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.onTick() }
        }
    }

    private func onTick() {
        syncCurrentTime()
        if !players.contains(where: \.isPlaying) {   // доиграли до конца
            isPlaying = false
            ticker?.invalidate(); ticker = nil
        }
    }

    private func syncCurrentTime() {
        currentTime = players.map(\.currentTime).max() ?? 0
    }
}
