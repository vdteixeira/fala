import Foundation

/// One input-level reading: the loudness of a short window of microphone audio,
/// in the two forms a meter needs.
///
/// Carries no audio and nothing derived from what was *said* — only how loud it
/// was — so it is safe to hand to a view (CLAUDE.md: nothing on the audio path
/// may become observable content).
public struct AudioLevel: Sendable, Equatable {
  /// Linear RMS of the window, clamped to `0...1`.
  ///
  /// Honest but useless on its own: ordinary speech sits around 0.03–0.1, which
  /// on a 12-segment meter is less than one lit segment. `normalized` is what a
  /// meter draws.
  public let rms: Double

  /// `rms` mapped through `AudioLevelScale` onto `0...1`: linear in DECIBELS, so
  /// the meter behaves the way a listener expects.
  public let normalized: Double

  /// An empty meter. Published whenever the microphone closes, so a stale
  /// reading can never sit on screen implying the mic is still open.
  public static let silence = AudioLevel(rms: 0)

  /// Non-finite and out-of-range inputs are normalised rather than trapped: a
  /// driver that hands over a NaN must not take the app down (CLAUDE.md).
  public init(rms: Double) {
    let bounded = rms.isFinite ? min(max(rms, 0), 1) : 0
    self.rms = bounded
    self.normalized = AudioLevelScale.normalized(rms: bounded)
  }

  /// dBFS, floored at `AudioLevelScale.floorDecibels`.
  public var decibels: Double { AudioLevelScale.decibels(rms: rms) }
}

/// The RMS → meter-position mapping, as pure arithmetic so it can be tested
/// without a microphone.
///
/// ## Why decibels and not raw RMS
/// A 12-segment meter fed raw RMS is dead: comfortable speech measured at this
/// mic (~-25 dBFS) is an RMS of about 0.056, i.e. 0.7 of one segment. Mapping
/// -60…0 dBFS onto 0…1 puts that same speech at roughly seven segments and
/// leaves the top two — the amber warning band the mockup draws — for audio that
/// is genuinely close to clipping.
public enum AudioLevelScale {
  /// Everything at or below this reads as an empty meter. -60 dBFS is below the
  /// noise floor of every built-in mic this app runs on, so an idle room shows
  /// nothing rather than a permanently twitching first segment.
  public static let floorDecibels: Double = -60

  /// Full scale. A sample of magnitude 1.0 held for the whole window.
  public static let ceilingDecibels: Double = 0

  /// dBFS for a linear RMS, clamped to `floorDecibels...ceilingDecibels`.
  /// Silence (and anything non-finite) is the floor, not `-infinity`.
  public static func decibels(rms: Double) -> Double {
    guard rms.isFinite, rms > 0 else { return floorDecibels }
    let value = 20 * log10(min(rms, 1))
    guard value.isFinite else { return floorDecibels }
    return min(max(value, floorDecibels), ceilingDecibels)
  }

  /// `0...1` meter position for a linear RMS: linear in decibels between the
  /// floor and full scale.
  public static func normalized(rms: Double) -> Double {
    let span = ceilingDecibels - floorDecibels
    guard span > 0 else { return 0 }
    let position = (decibels(rms: rms) - floorDecibels) / span
    return min(max(position, 0), 1)
  }
}

/// Sums squares of the samples that are already flowing through the capture
/// path, so a level can be read at the meter's refresh rate instead of at the
/// tap's callback rate.
///
/// This is the whole reason the capture path does not pay for the UI: `add` is
/// one multiply-accumulate per sample with no allocation, no lock and no
/// continuation wake-up, and `take` — the only thing that produces a value and
/// wakes a subscriber — is called by a timer, roughly 20 times a second.
///
/// Accumulating in `Double` is deliberate: a `Float` running sum loses precision
/// after a few hundred thousand samples, and a 60 s utterance at 48 kHz is 2.9
/// million.
public struct AudioLevelAccumulator: Sendable {
  private var sumOfSquares: Double = 0
  private var sampleCount: Int = 0

  public init() {}

  /// True when nothing has arrived since the last `take()`/`reset()`.
  public var isEmpty: Bool { sampleCount == 0 }

  /// The primitive overload: takes a raw buffer so tap audio can be measured
  /// without a bridging allocation.
  public mutating func add(_ samples: UnsafeBufferPointer<Float>) {
    guard let base = samples.baseAddress, !samples.isEmpty else { return }
    var total = 0.0
    for index in 0..<samples.count {
      let sample = Double(base[index])
      total += sample * sample
    }
    guard total.isFinite else { return }
    sumOfSquares += total
    sampleCount += samples.count
  }

  public mutating func add(_ samples: [Float]) {
    samples.withUnsafeBufferPointer { add($0) }
  }

  /// RMS of everything added since the last call, then resets.
  ///
  /// `nil` when nothing arrived. That is not the same as silence: at 48 kHz with
  /// a 4096-frame tap the microphone wakes about 12 times a second while the
  /// meter ticks 20 times a second, so empty ticks are NORMAL. Publishing zero
  /// for them would make the meter flicker to empty between real readings.
  public mutating func take() -> AudioLevel? {
    guard sampleCount > 0 else { return nil }
    let meanSquare = sumOfSquares / Double(sampleCount)
    reset()
    return AudioLevel(rms: meanSquare > 0 ? meanSquare.squareRoot() : 0)
  }

  public mutating func reset() {
    sumOfSquares = 0
    sampleCount = 0
  }
}
