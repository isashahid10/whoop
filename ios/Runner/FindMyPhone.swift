// FindMyPhone.swift — the loud one.
//
// WHY NOT AudioServicesPlaySystemSound. That was the previous implementation
// and it is the wrong API for this job: system sounds are routed through the
// RINGER, so with the mute switch flipped they play nothing at all. The one
// moment you need to find your phone is the moment it is face-down and
// silenced, so a find-my-phone that respects silent mode is a find-my-phone
// that does not work.
//
// WHAT ACTUALLY BREAKS THROUGH. An AVAudioSession with the `.playback`
// category ignores the mute switch — that is the documented, sanctioned
// behaviour, and the same reason music keeps playing when you silence the
// phone. Focus / Do Not Disturb suppress NOTIFICATIONS, not audio playback, so
// `.playback` clears both.
//
// The tone is SYNTHESISED rather than shipped as an asset: a two-tone siren
// sweeping between 880 Hz and 1320 Hz sits in the band the human ear is most
// sensitive to, carries through a sofa cushion far better than a soft chime,
// and costs no bundle size.

import AVFoundation
import Foundation
import MediaPlayer

enum FindMyPhone {
  private static var player: AVAudioPlayer?
  private static var stopTimer: Timer?

  /// How long to keep ringing if nothing stops it. Long enough to walk a flat,
  /// short enough that a pocket-fired gesture is not a public event.
  private static let maxDuration: TimeInterval = 30

  static var isRinging: Bool { player?.isPlaying == true }

  /// Start ringing. Returns false only if audio could not be started at all.
  @discardableResult
  static func start() -> Bool {
    stop()

    do {
      let session = AVAudioSession.sharedInstance()
      // .playback is the whole point — it is the category that ignores the
      // mute switch. `.duckOthers` rather than `.mixWithOthers` so this cuts
      // through music instead of competing with it.
      try session.setCategory(.playback, mode: .default, options: [.duckOthers])
      try session.setActive(true, options: [])
    } catch {
      return false
    }

    // Nudge the system output volume up. MPVolumeView's embedded slider is the
    // only public way to do this; it is best-effort and deliberately not
    // treated as required, because the .playback route alone already beats
    // silent mode.
    raiseSystemVolume()

    guard let data = sirenWav() else { return false }
    do {
      let p = try AVAudioPlayer(data: data)
      p.numberOfLoops = -1  // "on loop", per the ask
      p.volume = 1.0
      p.prepareToPlay()
      p.play()
      player = p
    } catch {
      return false
    }

    stopTimer?.invalidate()
    stopTimer = Timer.scheduledTimer(withTimeInterval: maxDuration, repeats: false) { _ in
      stop()
    }
    return true
  }

  static func stop() {
    stopTimer?.invalidate()
    stopTimer = nil
    player?.stop()
    player = nil
    // Deactivate with .notifyOthersOnDeactivation so whatever we ducked
    // (music, a podcast) resumes at full volume instead of staying quiet.
    try? AVAudioSession.sharedInstance()
      .setActive(false, options: [.notifyOthersOnDeactivation])
  }

  /// Best-effort system-volume raise via MPVolumeView's slider.
  private static func raiseSystemVolume() {
    DispatchQueue.main.async {
      let view = MPVolumeView(frame: .zero)
      guard
        let slider = view.subviews.compactMap({ $0 as? UISlider }).first
      else { return }
      slider.value = 1.0
    }
  }

  // ── tone synthesis ─────────────────────────────────────────────────────────

  /// Build a short looping two-tone siren as an in-memory 16-bit PCM WAV.
  private static func sirenWav() -> Data? {
    let sampleRate = 44100.0
    let toneDuration = 0.35  // per tone
    let tones: [Double] = [880, 1320]  // A5 / E6 — piercing, not shrill
    let totalFrames = Int(sampleRate * toneDuration * Double(tones.count))

    var samples = [Int16]()
    samples.reserveCapacity(totalFrames)

    for (index, freq) in tones.enumerated() {
      let frames = Int(sampleRate * toneDuration)
      for i in 0..<frames {
        let t = Double(i) / sampleRate
        // Short attack/release ramp so each tone does not click on the loop
        // seam — a click every 0.35 s reads as a fault, not an alarm.
        let ramp = 0.01
        var envelope = 1.0
        if t < ramp { envelope = t / ramp }
        let remaining = toneDuration - t
        if remaining < ramp { envelope = max(0, remaining / ramp) }
        let value = sin(2.0 * Double.pi * freq * t) * envelope * 0.9
        samples.append(Int16(value * Double(Int16.max)))
      }
      _ = index
    }

    return wavData(samples: samples, sampleRate: Int(sampleRate))
  }

  /// Minimal 16-bit mono PCM WAV container.
  private static func wavData(samples: [Int16], sampleRate: Int) -> Data {
    var d = Data()
    let byteRate = sampleRate * 2
    let dataSize = samples.count * 2

    func append(_ s: String) { d.append(s.data(using: .ascii)!) }
    func append32(_ v: Int) {
      var le = UInt32(v).littleEndian
      d.append(Data(bytes: &le, count: 4))
    }
    func append16(_ v: Int) {
      var le = UInt16(v).littleEndian
      d.append(Data(bytes: &le, count: 2))
    }

    append("RIFF")
    append32(36 + dataSize)
    append("WAVE")
    append("fmt ")
    append32(16)  // PCM header size
    append16(1)  // PCM
    append16(1)  // mono
    append32(sampleRate)
    append32(byteRate)
    append16(2)  // block align
    append16(16)  // bits per sample
    append("data")
    append32(dataSize)
    for s in samples {
      var le = s.littleEndian
      d.append(Data(bytes: &le, count: 2))
    }
    return d
  }
}
