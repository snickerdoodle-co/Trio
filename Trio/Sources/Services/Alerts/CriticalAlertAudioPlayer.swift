import AudioToolbox
import AVFoundation
import MediaPlayer
import os.log
import UIKit

@MainActor
final class CriticalAlertAudioPlayer {
    private let log = OSLog(subsystem: "org.nightscout.Trio", category: "CriticalAlertAudioPlayer")

    private var player: AVAudioPlayer?
    private var vibrationTimer: Timer?
    private var volumeObservation: NSKeyValueObservation?
    private var onVolumeButtonPressed: (() -> Void)?
    private var hasTriggeredVolumeSnooze = false

    private let vibrationInterval: TimeInterval = 2.0
    /// System volume floor for critical alarms. The alarm has to be audible
    /// with the ringer down, but forcing 100% wakes the whole household and
    /// leaves the user no way to turn it down. Raise only up to this floor;
    /// anything already louder is left alone.
    private let minimumSystemVolume: Float = 0.5
    private let volumeBooster = SystemVolumeBooster()

    var isPlaying: Bool { player?.isPlaying ?? false }

    /// Start (or restart) looping playback of a bundled critical alert sound.
    /// Loops until `stop()` is called from `retractAlert` /
    /// `handleAcknowledgement` in `BaseTrioAlertManager` — modeled on the
    /// LoopFollow / Jonas loop-failure alarm. `.playback` audio session gives
    /// the app a privileged background state so the alarm continues even if
    /// the user has the screen locked.
    ///
    /// - Parameter onVolumeButtonPressed: Invoked (once per playback, on the
    ///   main thread) if a hardware volume-button press is detected while
    ///   this alarm is sounding — see `startVolumeButtonObservation`.
    func play(soundNamed soundName: String = "critical.caf", onVolumeButtonPressed: (() -> Void)? = nil) {
        stop()

        self.onVolumeButtonPressed = onVolumeButtonPressed
        hasTriggeredVolumeSnooze = false
        startVibration()

        let resource = (soundName as NSString).deletingPathExtension
        let ext = (soundName as NSString).pathExtension.isEmpty ? "caf" : (soundName as NSString).pathExtension
        let url = Bundle.main.url(forResource: resource, withExtension: ext)
            ?? Bundle.main.url(forResource: "critical", withExtension: "caf")
        guard let url else {
            os_log(
                "Neither %{public}@ nor critical.caf found in main bundle; audio fallback unavailable",
                log: log,
                type: .error,
                soundName
            )
            return
        }

        do {
            let session = AVAudioSession.sharedInstance()
            // .playback ignores the silent switch and Focus modes. Must be
            // mixable: iOS refuses to activate a non-mixable session from
            // the background (AVAudioSessionErrorCodeCannotInterruptOthers,
            // 560557684 "Session activation failed"). .duckOthers +
            // .mixWithOthers ducks/mixes our alarm over other audio instead
            // of failing outright. Mixable .playback still plays at full
            // volume when nothing else is active and still bypasses the
            // silent switch.
            try session.setCategory(.playback, mode: .default, options: [.duckOthers, .mixWithOthers])
            try session.setActive(true, options: [])
            volumeBooster.boost(to: minimumSystemVolume)
            startVolumeButtonObservation(session: session)

            let p = try AVAudioPlayer(contentsOf: url)
            p.numberOfLoops = -1
            p.volume = 1.0
            p.prepareToPlay()
            guard p.play() else {
                os_log("AVAudioPlayer.play() returned false for %{public}@", log: log, type: .error, url.lastPathComponent)
                try? session.setActive(false, options: [.notifyOthersOnDeactivation])
                return
            }
            player = p
            os_log("Started critical-alert audio playback (duration=%{public}.2fs)", log: log, type: .info, p.duration)
        } catch {
            os_log("Failed to start audio playback: %{public}@", log: log, type: .error, String(describing: error))
        }
    }

    private func startVibration() {
        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        vibrationTimer = Timer.scheduledTimer(withTimeInterval: vibrationInterval, repeats: true) { _ in
            AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        }
    }

    /// Lets the user snooze the currently-sounding alarm with a hardware
    /// volume button instead of unlocking the phone and opening Trio.
    /// `AVAudioSession.outputVolume` only delivers KVO changes to an app
    /// holding an active audio session, so this observation is only ever
    /// live while our own critical audio is actually playing — it's torn
    /// down again in `stop()`.
    ///
    /// Two caveats worth knowing: `SystemVolumeBooster` already pushes the
    /// system volume to max the moment this alarm starts, so a volume-UP
    /// press has no headroom left to register a change — in practice only
    /// volume-DOWN reliably triggers this. And there's no public API to
    /// intercept the button without also moving the real system volume, so
    /// the press will audibly/visibly change it as a side effect.
    private func startVolumeButtonObservation(session: AVAudioSession) {
        volumeObservation = session.observe(\.outputVolume, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.handleVolumeButtonPress()
            }
        }
    }

    private func handleVolumeButtonPress() {
        guard !hasTriggeredVolumeSnooze else { return }
        hasTriggeredVolumeSnooze = true
        os_log("Volume button pressed during critical alarm playback — triggering snooze", log: log, type: .info)
        onVolumeButtonPressed?()
    }

    /// Stop playback if any. Safe to call when not playing.
    func stop() {
        guard player != nil || vibrationTimer != nil else { return }
        player?.stop()
        player = nil
        vibrationTimer?.invalidate()
        vibrationTimer = nil
        volumeObservation?.invalidate()
        volumeObservation = nil
        onVolumeButtonPressed = nil
        volumeBooster.restore()
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        os_log("Stopped critical-alert audio playback", log: log, type: .info)
    }
}

/// Best-effort override of the system output volume.
///
/// iOS has no public API to set the hardware volume. `MPVolumeView` hosts a
/// `UISlider` that drives the system volume when its value changes — the
/// long-standing workaround. Used ONLY for critical-alert audio on builds
/// without the Critical Alerts entitlement: without it an urgent-low alarm
/// can be silent when the ringer is down overnight.
///
/// Raises the system volume to a floor, never to maximum, and never lowers a
/// user who is already louder than the floor.
///
/// Best-effort: the slider only populates once the hosting view is in an
/// on-screen window, so it may no-op when the app is fully backgrounded. The
/// alarm's audio and vibration run regardless. Pre-boost level is restored on
/// `restore()` unless the user manually changed the volume in the meantime.
@MainActor private final class SystemVolumeBooster {
    private let volumeView = MPVolumeView(frame: CGRect(x: -2000, y: -2000, width: 1, height: 1))
    private var savedVolume: Float?
    private var targetVolume: Float?
    private var generation = 0

    func boost(to target: Float) {
        guard let window = Self.activeWindow() else { return }
        attach(to: window)
        generation &+= 1
        let gen = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self, gen == self.generation, let slider = self.slider() else { return }
            let current = slider.value
            guard current < target else { return }
            self.savedVolume = current
            self.targetVolume = target
            slider.setValue(target, animated: false)
        }
    }

    func restore() {
        generation &+= 1
        if let saved = savedVolume,
           let target = targetVolume,
           let slider = slider(),
           abs(slider.value - target) < 0.05
        {
            slider.setValue(saved, animated: false)
        }
        savedVolume = nil
        targetVolume = nil
        volumeView.removeFromSuperview()
    }

    private func attach(to window: UIWindow) {
        volumeView.alpha = 0.0001
        volumeView.isUserInteractionEnabled = false
        if volumeView.superview !== window {
            volumeView.removeFromSuperview()
            window.addSubview(volumeView)
        }
    }

    private func slider() -> UISlider? {
        volumeView.subviews.compactMap { $0 as? UISlider }.first
    }

    private static func activeWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let active = scenes.first { $0.activationState == .foregroundActive }
        return active?.windows.first(where: { $0.isKeyWindow })
            ?? active?.windows.first
            ?? scenes.flatMap(\.windows).first
    }
}
