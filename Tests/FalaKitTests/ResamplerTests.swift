import AVFoundation
import Foundation
import Testing

@testable import FalaKit

/// Covers the DoD for T1.3: a known in-memory buffer converts to exactly 16 kHz
/// mono Float32 with the expected duration (SPEC.md FR-2). Fixtures are generated
/// in code — no audio files are committed (see the `swift-testing` skill).
@Suite("Resampler")
struct ResamplerTests {

  /// The engine's contract (`TranscriptionEngine.requiredSampleRate`).
  private let targetRate: Double = 16_000

  // MARK: - Fixtures

  /// A sine at `frequency`, amplitude 0.5, in the mic-like float32 non-interleaved
  /// format. Every channel carries the same tone, so a stereo→mono down-mix must
  /// preserve amplitude.
  private func makeSine(
    frequency: Double = 440,
    seconds: Double = 1.0,
    sampleRate: Double,
    channels: AVAudioChannelCount = 1
  ) throws -> AVAudioPCMBuffer {
    let format = try #require(
      AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels))
    let frames = AVAudioFrameCount((seconds * sampleRate).rounded())
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
    buffer.frameLength = frames
    let channelData = try #require(buffer.floatChannelData)
    for channel in 0..<Int(format.channelCount) {
      for frame in 0..<Int(frames) {
        let phase = 2.0 * Double.pi * frequency * Double(frame) / sampleRate
        channelData[channel][frame] = Float(sin(phase) * 0.5)
      }
    }
    return buffer
  }

  /// Sign changes in the signal. For a clean sine this is `2 * frequency * seconds`,
  /// which is enough to prove the output is the same tone and not aliased mush.
  private func zeroCrossings(_ samples: [Float]) -> Int {
    guard samples.count > 1 else { return 0 }
    var crossings = 0
    for index in 1..<samples.count where (samples[index - 1] < 0) != (samples[index] < 0) {
      crossings += 1
    }
    return crossings
  }

  // MARK: - Format conversion (the DoD)

  @Test("48 kHz stereo converts to exactly 16 kHz mono of the same duration")
  func stereo48kToMono16k() throws {
    let resampler = try Resampler()
    let input = try makeSine(seconds: 1.0, sampleRate: 48_000, channels: 2)

    let output = try resampler.finish(input)

    #expect(output.sampleRate == targetRate)
    #expect(resampler.targetFormat.channelCount == 1)
    #expect(resampler.targetFormat.commonFormat == .pcmFormatFloat32)
    #expect(!resampler.targetFormat.isInterleaved)
    #expect(output.samples.count == 16_000)
    #expect(abs(output.duration - 1.0) < 0.001)
  }

  @Test("44.1 kHz mono converts to exactly 16 kHz mono of the same duration")
  func mono44kToMono16k() throws {
    let resampler = try Resampler()
    let input = try makeSine(seconds: 0.5, sampleRate: 44_100, channels: 1)

    let output = try resampler.finish(input)

    #expect(output.sampleRate == targetRate)
    #expect(output.samples.count == 8_000)
    #expect(abs(output.duration - 0.5) < 0.001)
  }

  @Test("Input already at 16 kHz mono passes through at full length")
  func passthroughAt16k() throws {
    let resampler = try Resampler()
    let input = try makeSine(seconds: 0.25, sampleRate: 16_000, channels: 1)

    let output = try resampler.finish(input)

    #expect(output.sampleRate == targetRate)
    #expect(output.samples.count == 4_000)
  }

  @Test("A non-default target rate still resamples by the exact ratio")
  func injectedTargetRate() throws {
    let resampler = try Resampler(targetSampleRate: 8_000)
    let input = try makeSine(seconds: 0.5, sampleRate: 48_000, channels: 1)

    let output = try resampler.finish(input)

    #expect(output.sampleRate == 8_000)
    #expect(output.samples.count == 4_000)
  }

  // MARK: - Signal integrity

  @Test("The resampled tone is still the tone that went in")
  func preservesFrequency() throws {
    let resampler = try Resampler()
    let input = try makeSine(frequency: 440, seconds: 1.0, sampleRate: 48_000, channels: 2)

    let output = try resampler.finish(input)

    // 440 Hz over 1 s = 880 sign changes; allow a little slack at the edges.
    let crossings = zeroCrossings(output.samples)
    #expect(crossings > 860)
    #expect(crossings < 900)

    // Down-mixing two identical channels must not double or halve the amplitude,
    // and must not clip.
    let peak = output.samples.map(abs).max() ?? 0
    #expect(peak > 0.4)
    #expect(peak <= 1.0)
  }

  // MARK: - Chunked capture (the AudioCapture path)

  @Test("Chunked capture plus finish() reassembles the exact duration")
  func chunkedConversionIsLossless() throws {
    let resampler = try Resampler()
    var streamed = 0
    // Ten 100 ms tap-sized chunks through one converter, as AudioCapture will do.
    for _ in 0..<10 {
      let chunk = try makeSine(seconds: 0.1, sampleRate: 48_000, channels: 2)
      let output = try resampler.resample(chunk)
      #expect(output.sampleRate == targetRate)
      streamed += output.samples.count
    }
    let tail = try resampler.finish()

    // The converter withholds ~a filter length until the stream ends, so the
    // streamed part alone is short — the total is what must be exact.
    #expect(streamed < 16_000)
    #expect(!tail.isEmpty)
    #expect(streamed + tail.samples.count == 16_000)
  }

  @Test("finish() leaves the converter usable for the next utterance")
  func finishResetsForNextUtterance() throws {
    let resampler = try Resampler()
    let first = try resampler.finish(
      try makeSine(seconds: 0.2, sampleRate: 48_000, channels: 1))
    let second = try resampler.finish(
      try makeSine(seconds: 0.2, sampleRate: 48_000, channels: 1))

    #expect(first.samples.count == 3_200)
    #expect(second.samples.count == 3_200)
  }

  @Test("finish() with nothing pending is an empty buffer, not an error")
  func finishWithoutInput() throws {
    let resampler = try Resampler()
    let output = try resampler.finish()
    #expect(output.isEmpty)
    #expect(output.sampleRate == targetRate)
  }

  @Test("reset() discards the tail instead of returning it (cancelled recording)")
  func resetDiscardsTail() throws {
    let resampler = try Resampler()
    _ = try resampler.resample(try makeSine(seconds: 0.2, sampleRate: 48_000, channels: 1))
    resampler.reset()

    let output = try resampler.finish(
      try makeSine(seconds: 0.2, sampleRate: 48_000, channels: 1))
    #expect(output.samples.count == 3_200)
  }

  @Test("A device switch mid-session rebuilds the converter instead of failing")
  func handlesInputFormatChange() throws {
    let resampler = try Resampler()
    let first = try resampler.finish(
      try makeSine(seconds: 0.2, sampleRate: 48_000, channels: 2))
    let second = try resampler.finish(
      try makeSine(seconds: 0.2, sampleRate: 44_100, channels: 1))

    #expect(first.samples.count == 3_200)
    #expect(second.samples.count == 3_200)
  }

  // MARK: - Degenerate input (never crash)

  @Test("A zero-frame buffer yields empty audio rather than an error")
  func emptyInputIsNotAnError() throws {
    let resampler = try Resampler()
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
    let empty = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512))
    empty.frameLength = 0

    let streamed = try resampler.resample(empty)
    #expect(streamed.isEmpty)
    #expect(streamed.sampleRate == targetRate)
    #expect(streamed.duration == 0)

    // And it must not leave a half-built converter behind.
    #expect(try resampler.finish(empty).isEmpty)
  }

  @Test("An exotic multi-channel format either converts or throws a typed error")
  func multiChannelInputNeverCrashes() throws {
    // The voice-processing trap (CLAUDE.md): a 5–9 channel mic format must not take
    // the process down. Some channel counts have no standard layout, in which case
    // the fixture cannot be built and there is nothing to assert.
    guard let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 6),
      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800)
    else { return }
    buffer.frameLength = 4_800
    if let channelData = buffer.floatChannelData {
      for channel in 0..<Int(format.channelCount) {
        for frame in 0..<4_800 {
          channelData[channel][frame] = Float(sin(Double(frame) * 0.01) * 0.5)
        }
      }
    }

    let resampler = try Resampler()
    do {
      let output = try resampler.finish(buffer)
      #expect(output.sampleRate == targetRate)
    } catch is ResamplerError {
      // Acceptable: the contract is a typed error, not a crash. Any other error
      // type escapes this catch and fails the test.
    }
  }

  @Test("A target sample rate that cannot describe a format is rejected at init")
  func invalidTargetSampleRate() {
    #expect(throws: ResamplerError.unsupportedTargetSampleRate(0)) {
      _ = try Resampler(targetSampleRate: 0)
    }
    #expect(throws: ResamplerError.unsupportedTargetSampleRate(-16_000)) {
      _ = try Resampler(targetSampleRate: -16_000)
    }
  }

  // MARK: - Pure logic, no AVFoundation

  @Test("Input-format validation rejects impossible formats")
  func validationRejectsImpossibleFormats() {
    #expect(ResamplerMath.validateInputFormat(sampleRate: 48_000, channelCount: 2) == nil)
    #expect(ResamplerMath.validateInputFormat(sampleRate: 0, channelCount: 1) != nil)
    #expect(ResamplerMath.validateInputFormat(sampleRate: -48_000, channelCount: 1) != nil)
    #expect(ResamplerMath.validateInputFormat(sampleRate: .nan, channelCount: 1) != nil)
    #expect(ResamplerMath.validateInputFormat(sampleRate: 48_000, channelCount: 0) != nil)
  }

  @Test("Output capacity covers the exact ratio plus catch-up headroom")
  func outputCapacityArithmetic() {
    let headroom = ResamplerMath.catchUpHeadroom

    #expect(
      ResamplerMath.outputFrameCapacity(
        inputFrameCount: 48_000, inputSampleRate: 48_000, outputSampleRate: 16_000)
        == 16_000 + headroom)

    // 44 100 → 16 000 does not divide evenly; capacity must round up.
    #expect(
      ResamplerMath.outputFrameCapacity(
        inputFrameCount: 4_410, inputSampleRate: 44_100, outputSampleRate: 16_000)
        == 1_600 + headroom)
    #expect(
      ResamplerMath.outputFrameCapacity(
        inputFrameCount: 4_411, inputSampleRate: 44_100, outputSampleRate: 16_000)
        == 1_601 + headroom)
  }

  @Test("Output capacity degrades to the headroom instead of trapping")
  func outputCapacityDegradesSafely() {
    let headroom = ResamplerMath.catchUpHeadroom
    #expect(
      ResamplerMath.outputFrameCapacity(
        inputFrameCount: 0, inputSampleRate: 48_000, outputSampleRate: 16_000) == headroom)
    #expect(
      ResamplerMath.outputFrameCapacity(
        inputFrameCount: 1_024, inputSampleRate: 0, outputSampleRate: 16_000) == headroom)
    #expect(
      ResamplerMath.outputFrameCapacity(
        inputFrameCount: 1_024, inputSampleRate: .nan, outputSampleRate: 16_000) == headroom)
    #expect(
      ResamplerMath.outputFrameCapacity(
        inputFrameCount: Int.max, inputSampleRate: 1, outputSampleRate: 16_000) == headroom)
  }
}
