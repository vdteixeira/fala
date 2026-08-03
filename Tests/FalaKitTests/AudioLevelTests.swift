import Foundation
import Testing

@testable import FalaKit

/// Helpers shared by both suites.
private enum Signal {
  /// A sine of `amplitude` over a whole number of periods, so its discrete RMS
  /// is exactly `amplitude / sqrt(2)` and the test can assert against theory
  /// rather than against a previous run.
  static func sine(amplitude: Float, sampleCount: Int, periods: Int) -> [Float] {
    (0..<sampleCount).map { index in
      let phase = 2 * Double.pi * Double(periods) * Double(index) / Double(sampleCount)
      return amplitude * Float(sin(phase))
    }
  }

  static func constant(_ value: Float, count: Int) -> [Float] {
    [Float](repeating: value, count: count)
  }

  static func level(of samples: [Float]) -> AudioLevel? {
    var accumulator = AudioLevelAccumulator()
    accumulator.add(samples)
    return accumulator.take()
  }
}

/// The level math: what a meter is fed, and why raw RMS is not it.
@Suite("AudioLevel")
struct AudioLevelTests {

  @Test("Silence is an empty meter, not minus infinity")
  func silenceIsEmpty() throws {
    let level = try #require(Signal.level(of: Signal.constant(0, count: 4_096)))
    #expect(level.rms == 0)
    #expect(level.normalized == 0)
    #expect(level.decibels == AudioLevelScale.floorDecibels)
    #expect(level == AudioLevel.silence)
  }

  @Test("Full scale fills the meter")
  func fullScaleFillsTheMeter() throws {
    let level = try #require(Signal.level(of: Signal.constant(1, count: 4_096)))
    #expect(abs(level.rms - 1) < 1e-9)
    #expect(abs(level.decibels - 0) < 1e-9)
    #expect(abs(level.normalized - 1) < 1e-9)
  }

  /// The reference case: a sine of amplitude A has RMS A/√2, i.e. -3.01 dBFS at
  /// full amplitude. If the accumulator ever averages magnitudes instead of
  /// squares this is the test that notices (the mean magnitude of a sine is
  /// 2A/π ≈ 0.637, not 0.707).
  @Test("A full-amplitude sine measures its theoretical RMS")
  func knownSineMatchesTheory() throws {
    let samples = Signal.sine(amplitude: 1, sampleCount: 4_800, periods: 100)
    let level = try #require(Signal.level(of: samples))

    #expect(abs(level.rms - (1 / 2.0.squareRoot())) < 1e-4)
    #expect(abs(level.decibels - (-3.0103)) < 1e-3)
    // (-3.0103 + 60) / 60
    #expect(abs(level.normalized - 0.949828) < 1e-4)
  }

  @Test("A half-amplitude sine is 6 dB quieter, not half the meter")
  func halfAmplitudeSineIsSixDecibelsDown() throws {
    let loud = try #require(
      Signal.level(of: Signal.sine(amplitude: 1, sampleCount: 4_800, periods: 100)))
    let quiet = try #require(
      Signal.level(of: Signal.sine(amplitude: 0.5, sampleCount: 4_800, periods: 100)))

    #expect(abs(quiet.rms - (0.5 / 2.0.squareRoot())) < 1e-4)
    #expect(abs((loud.decibels - quiet.decibels) - 6.0206) < 1e-3)
    // Halving the amplitude moves the meter one tenth, not one half.
    #expect(abs((loud.normalized - quiet.normalized) - 0.100343) < 1e-4)
  }

  /// The whole reason the mapping is in decibels: raw RMS would put ordinary
  /// speech at 5% of the meter.
  @Test("Speech-level audio lands mid-meter instead of looking dead")
  func speechLevelAudioIsVisible() throws {
    // -25 dBFS, a comfortable dictation level.
    let rms = pow(10.0, -25.0 / 20.0)
    let level = AudioLevel(rms: rms)

    #expect(level.rms < 0.06)  // raw RMS: under 6% of the meter
    #expect(level.normalized > 0.55)  // mapped: over half of it
  }

  @Test("-20 dBFS sits exactly two thirds up the meter")
  func twentyDecibelsDownIsTwoThirds() {
    let level = AudioLevel(rms: 0.1)
    #expect(abs(level.decibels - (-20)) < 1e-9)
    #expect(abs(level.normalized - 2.0 / 3.0) < 1e-9)
  }

  @Test("Anything at or below the floor reads empty")
  func belowFloorReadsEmpty() {
    // -80 dBFS.
    #expect(AudioLevel(rms: 0.0001).normalized == 0)
    // -70 dBFS, still under the floor.
    #expect(AudioLevel(rms: 0.0003).decibels == AudioLevelScale.floorDecibels)
  }

  @Test("Nonsense from a driver is normalised, never trapped")
  func hostileInputsAreNormalised() {
    #expect(AudioLevel(rms: .nan).rms == 0)
    #expect(AudioLevel(rms: .infinity).rms == 0)
    #expect(AudioLevel(rms: -1).rms == 0)
    #expect(AudioLevel(rms: 5).rms == 1)
    #expect(AudioLevel(rms: 5).normalized == 1)
  }

  @Test("The mapping never decreases as the signal grows")
  func mappingIsMonotonic() {
    var previous = -1.0
    for step in 0...200 {
      let value = AudioLevelScale.normalized(rms: Double(step) / 200)
      #expect(value >= previous)
      previous = value
    }
    #expect(previous == 1)
  }
}

/// The accumulator: one window in, one reading out, nothing retained.
@Suite("AudioLevelAccumulator")
struct AudioLevelAccumulatorTests {

  @Test("Nothing in, nothing out — an empty tick is not silence")
  func emptyTakeReturnsNil() {
    var accumulator = AudioLevelAccumulator()
    #expect(accumulator.isEmpty)
    #expect(accumulator.take() == nil)
  }

  @Test("Taking a reading clears the window")
  func takeResets() throws {
    var accumulator = AudioLevelAccumulator()
    accumulator.add(Signal.constant(1, count: 128))
    let taken = accumulator.take()
    _ = try #require(taken)
    #expect(accumulator.isEmpty)
    #expect(accumulator.take() == nil)
  }

  /// Chunks arrive one per tap callback; the reading must describe the whole
  /// window, not the last chunk.
  @Test("Several chunks average as one window")
  func chunksCombineIntoOneWindow() throws {
    var accumulator = AudioLevelAccumulator()
    accumulator.add(Signal.constant(1, count: 100))
    accumulator.add(Signal.constant(0, count: 300))
    let taken = accumulator.take()
    let level = try #require(taken)

    // Mean square = (100 * 1 + 300 * 0) / 400 = 0.25 → RMS 0.5.
    #expect(abs(level.rms - 0.5) < 1e-9)
  }

  @Test("Multi-channel audio is measured across every channel")
  func multipleChannelsAreMeasuredTogether() throws {
    var accumulator = AudioLevelAccumulator()
    accumulator.add(Signal.constant(1, count: 256))  // live channel
    accumulator.add(Signal.constant(0, count: 256))  // dead channel
    let taken = accumulator.take()
    let level = try #require(taken)

    #expect(abs(level.rms - (1 / 2.0.squareRoot())) < 1e-9)
  }

  @Test("Sign does not matter — a negative half-cycle is still audio")
  func negativeSamplesCount() throws {
    var accumulator = AudioLevelAccumulator()
    accumulator.add(Signal.constant(-1, count: 512))
    let taken = accumulator.take()
    let level = try #require(taken)
    #expect(abs(level.rms - 1) < 1e-9)
  }

  @Test("Empty chunks are ignored rather than counted as silence")
  func emptyChunksAreIgnored() {
    var accumulator = AudioLevelAccumulator()
    accumulator.add([Float]())
    #expect(accumulator.isEmpty)
  }
}

/// The 12-segment mapping from `design/mockups/settings-window.dc.html`.
@Suite("InputLevelMeter")
struct InputLevelMeterTests {

  @Test("The meter is always twelve segments wide")
  func alwaysTwelveSegments() {
    for level in [-1.0, 0, 0.001, 0.5, 1, 2, Double.nan] {
      #expect(InputLevelMeter.segments(forNormalizedLevel: level).count == 12)
    }
  }

  @Test("Silence lights nothing")
  func silenceLightsNothing() {
    let segments = InputLevelMeter.segments(for: .silence)
    #expect(InputLevelMeter.litSegmentCount(forNormalizedLevel: 0) == 0)
    #expect(segments.allSatisfy { $0 == .off })
  }

  @Test("Full scale lights everything, top two amber")
  func fullScaleLightsEverything() {
    let segments = InputLevelMeter.segments(forNormalizedLevel: 1)
    #expect(InputLevelMeter.litSegmentCount(forNormalizedLevel: 1) == 12)
    #expect(segments.prefix(10).allSatisfy { $0 == .lit })
    #expect(segments[10] == .hot)
    #expect(segments[11] == .hot)
  }

  /// The mockup's own static render: `levels = [1,1,1,1,1,1,1,1,0,0,0,0]` — eight
  /// lit, none amber. -20 dBFS is what that picture is showing.
  @Test("The mockup's static render corresponds to -20 dBFS")
  func mockupStaticRenderMatches() {
    let segments = InputLevelMeter.segments(for: AudioLevel(rms: 0.1))
    #expect(segments.filter { $0 != .off }.count == 8)
    #expect(segments.allSatisfy { $0 != .hot })
    #expect(segments.suffix(4).allSatisfy { $0 == .off })
  }

  /// `i > 9` in the mockup: the warning band is the top TWO segments and nothing
  /// else. Getting this off by one paints an amber meter for normal speech.
  @Test("The warning band is exactly the top two segments")
  func warningBandIsTheTopTwo() {
    #expect(InputLevelMeter.firstWarningSegmentIndex == 10)

    // 0.83 → ceil(9.96) = 10 lit: the band is untouched.
    let below = InputLevelMeter.segments(forNormalizedLevel: 0.83)
    #expect(below.filter { $0 != .off }.count == 10)
    #expect(below.allSatisfy { $0 != .hot })

    // 0.9 → ceil(10.8) = 11 lit: the first amber segment, and only that one.
    let inBand = InputLevelMeter.segments(forNormalizedLevel: 0.9)
    #expect(inBand[9] == .lit)
    #expect(inBand[10] == .hot)
    #expect(inBand[11] == .off)
  }

  /// A meter that reads empty while the user is speaking is indistinguishable
  /// from a dead microphone — the exact diagnosis this row exists to support.
  @Test("Any audible input lights at least one segment")
  func audibleInputAlwaysShows() {
    #expect(InputLevelMeter.litSegmentCount(forNormalizedLevel: 0.0001) == 1)
    #expect(InputLevelMeter.segments(forNormalizedLevel: 0.0001)[0] == .lit)
  }

  @Test("Out-of-range levels and indices are clamped, never trapped")
  func hostileInputsAreClamped() {
    #expect(InputLevelMeter.litSegmentCount(forNormalizedLevel: 5) == 12)
    #expect(InputLevelMeter.litSegmentCount(forNormalizedLevel: -3) == 0)
    #expect(InputLevelMeter.litSegmentCount(forNormalizedLevel: .nan) == 0)
    #expect(InputLevelMeter.segmentState(at: -1, litSegmentCount: 12) == .off)
    #expect(InputLevelMeter.segmentState(at: 99, litSegmentCount: 12) == .off)
  }

  @Test("More signal never lights fewer segments")
  func litCountIsMonotonic() {
    var previous = 0
    for step in 0...240 {
      let count = InputLevelMeter.litSegmentCount(forNormalizedLevel: Double(step) / 240)
      #expect(count >= previous)
      previous = count
    }
    #expect(previous == 12)
  }

  @Test("Each segment state maps to its own token in both appearances")
  func segmentColoursComeFromTokens() {
    for appearance in DesignSystem.Appearance.allCases {
      let theme = Theme(appearance: appearance)
      let off = theme.meterSegmentColor(.off)
      let lit = theme.meterSegmentColor(.lit)
      let hot = theme.meterSegmentColor(.hot)

      #expect(off == theme.color.border.base)
      #expect(lit == theme.color.state.recording)
      #expect(hot == theme.color.state.warning)
      #expect(off != lit)
      #expect(lit != hot)
    }
  }
}
