import AVFoundation
import AudioToolbox
import Foundation
import UIKit

/**
 担保人 App 内的持续响铃和震动（设计文档 3.5、4.3）。
 - 常驻框挂着时循环播放报警铃声（.playback 类别，静音开关下也响）并每 1.2 秒震一次；
 - 按音量键暂停 5 分钟（App 在前台时才能听到音量键），框还在，5 分钟后没结果就重新响。
 */
@MainActor
final class AlarmPlayer: NSObject {
    static let shared = AlarmPlayer()
    static let snoozeDuration: TimeInterval = 5 * 60

    var onVolumeButton: (() -> Void)?
    private(set) var isRinging = false
    private(set) var snoozedUntil: Date?

    private var player: AVAudioPlayer?
    private var vibrateTimer: Timer?
    private var resumeTimer: Timer?
    private var volumeObservation: NSKeyValueObservation?
    private var lastVolume: Float = -1

    func start(snoozedUntil: Date? = nil) {
        isRinging = true
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [])
        try? session.setActive(true)
        if player == nil, let url = Bundle.main.url(forResource: "alarm", withExtension: "caf") {
            player = try? AVAudioPlayer(contentsOf: url)
            player?.numberOfLoops = -1
            player?.volume = 1.0
        }
        observeVolume()
        if let s = snoozedUntil, s > Date() {
            pause(until: s)
        } else {
            resume()
        }
    }

    func snooze() {
        pause(until: Date().addingTimeInterval(Self.snoozeDuration))
    }

    func stop() {
        isRinging = false
        snoozedUntil = nil
        player?.stop()
        player = nil
        vibrateTimer?.invalidate()
        vibrateTimer = nil
        resumeTimer?.invalidate()
        resumeTimer = nil
        volumeObservation = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func resume() {
        guard isRinging else { return }
        snoozedUntil = nil
        player?.play()
        vibrateTimer?.invalidate()
        vibrateTimer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: true) { _ in
            AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        }
        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
    }

    private func pause(until: Date) {
        snoozedUntil = until
        player?.pause()
        vibrateTimer?.invalidate()
        vibrateTimer = nil
        resumeTimer?.invalidate()
        resumeTimer = Timer.scheduledTimer(withTimeInterval: max(1, until.timeIntervalSinceNow), repeats: false) { [weak self] _ in
            Task { @MainActor in self?.resume() }
        }
    }

    /// 音量键：通过系统音量变化来感知
    private func observeVolume() {
        guard volumeObservation == nil else { return }
        let session = AVAudioSession.sharedInstance()
        lastVolume = session.outputVolume
        volumeObservation = session.observe(\.outputVolume, options: [.new]) { [weak self] _, change in
            guard let v = change.newValue else { return }
            Task { @MainActor in
                guard let self else { return }
                if self.lastVolume >= 0, v != self.lastVolume, self.snoozedUntil == nil, self.isRinging {
                    self.onVolumeButton?()
                }
                self.lastVolume = v
            }
        }
    }
}
