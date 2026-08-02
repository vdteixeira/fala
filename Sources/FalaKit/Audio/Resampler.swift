// `@preconcurrency` because `AVAudioConverterInputBlock` is imported as `@Sendable`
// while `AVAudioPCMBuffer` is not `Sendable`, so the block below could not receive
// the audio it exists to hand over. The annotation is not papering over a race:
// `convert(to:error:withInputFrom:)` invokes the block synchronously, on the calling
// thread, before it returns, and `Resampler` is deliberately non-`Sendable`, so two
// conversions can never overlap on one instance. (Same reasoning, same annotation,
// as FluidAudio's own `AudioConverter`.)
@preconcurrency import AVFoundation
import Foundation

/// Failures the resampler surfaces instead of trapping. A format it cannot handle
/// is a runtime condition (an exotic microphone, a driver change mid-session), not
/// a programmer error, so none of these paths use `fatalError` or `!`.
///
/// No case carries audio or text — only formats, counts and error codes (CLAUDE.md).
public enum ResamplerError: Error, Equatable, Sendable {
  /// The captured buffer's format is not usable as converter input.
  case unsupportedInputFormat(reason: String)
  /// The requested target sample rate cannot describe a 16-bit-clean mono format.
  case unsupportedTargetSampleRate(Double)
  /// `AVAudioConverter` refused this input → output pair. The documented trigger is
  /// voice processing being enabled, which turns the mic into a 5–9 channel device
  /// (CLAUDE.md "Known traps"); FR-3 forbids enabling it, and this is the guard.
  case converterUnavailable(inputSampleRate: Double, inputChannels: Int)
  /// The output `AVAudioPCMBuffer` could not be allocated.
  case allocationFailed(frameCapacity: Int)
  /// The converter reported an error status.
  case conversionFailed(code: Int)
}

/// The arithmetic and validation behind `Resampler`, kept free of AVFoundation and
/// of any state so it can be unit-tested directly (see the `swift-testing` skill).
enum ResamplerMath {
  /// Extra output frames requested on top of the exact ratio.
  ///
  /// `AVAudioConverter` does not emit `frames * outputRate / inputRate` per call:
  /// it withholds roughly a filter length at the start of a stream and later emits
  /// a catch-up burst. Measured on this SDK for 48 kHz → 16 kHz, a 0.1 s chunk that
  /// "should" yield 1600 frames yielded 1354 on the first call and 2773 on a later
  /// one. This headroom covers that burst; anything that still does not fit stays
  /// inside the converter and comes out of the next call or of `finish()`, so it is
  /// never lost.
  static let catchUpHeadroom = 2_048

  /// Returns the error describing why this input format is unusable, or `nil`.
  static func validateInputFormat(sampleRate: Double, channelCount: Int) -> ResamplerError? {
    guard sampleRate.isFinite, sampleRate > 0 else {
      return .unsupportedInputFormat(reason: "sample rate \(sampleRate)")
    }
    guard channelCount >= 1 else {
      return .unsupportedInputFormat(reason: "channel count \(channelCount)")
    }
    return nil
  }

  /// Frames to allocate for one conversion: the exact ratio plus `catchUpHeadroom`.
  /// Degenerate inputs fall back to the headroom alone rather than trapping on an
  /// `Int` conversion.
  static func outputFrameCapacity(
    inputFrameCount: Int,
    inputSampleRate: Double,
    outputSampleRate: Double
  ) -> Int {
    guard inputFrameCount > 0,
      inputSampleRate.isFinite, inputSampleRate > 0,
      outputSampleRate.isFinite, outputSampleRate > 0
    else { return catchUpHeadroom }
    let scaled = (Double(inputFrameCount) * (outputSampleRate / inputSampleRate)).rounded(.up)
    guard scaled.isFinite, scaled < Double(Int.max - catchUpHeadroom) else {
      return catchUpHeadroom
    }
    return Int(scaled) + catchUpHeadroom
  }
}

/// Converts microphone audio in its native format (44.1/48 kHz, one or more
/// channels) into the 16 kHz mono Float32 `AudioBuffer` every `TranscriptionEngine`
/// consumes (SPEC.md FR-2), using `AVAudioConverter`.
///
/// ## Usage — one call per utterance, or one call per chunk plus `finish()`
/// `AVAudioConverter` holds roughly a filter length of audio back (measured here:
/// up to ~62 ms) and only releases it when told the stream has ended. So:
///
/// - Whole utterance in one go: `try resampler.finish(buffer)`.
/// - Chunked capture: `try resampler.resample(chunk)` per tap callback, then
///   `try resampler.finish()` when the hotkey is released.
///
/// **Calling only `resample(_:)` and never `finish()` silently drops the last
/// ~60 ms of the recording** — exactly the truncation FR-4 exists to prevent.
/// Verified: ten 0.1 s chunks at 48 kHz yielded 15 008 frames from `resample` plus
/// 992 from `finish()`, i.e. exactly the 16 000 the duration demands.
///
/// ## Why this type is deliberately not `Sendable`
/// The converter's filter state carries across calls, so conversions must happen in
/// order, in one isolation domain. Leaving `Resampler` non-`Sendable` makes Swift 6
/// reject sharing it across domains at compile time, rather than letting two chunks
/// interleave and scramble the audio. Own exactly one instance per capture session,
/// as a stored property of the `AudioCapture` actor.
///
/// (The alternative, making it an `actor`, would have *created* the ordering
/// problem: two `await resampler.resample(...)` calls from different tasks have no
/// guaranteed order, and the converter's state is order-sensitive.)
public final class Resampler {
  /// Output buffer size for each flush pass; the tail is ~1 000 frames in practice.
  private static let flushFrameCapacity = 4_096

  /// Safety valve: a flush needs one pass, two if a backlog built up.
  private static let maximumFlushPasses = 8

  /// 16 kHz mono Float32, non-interleaved.
  public let targetFormat: AVAudioFormat

  public var targetSampleRate: Double { targetFormat.sampleRate }

  private var cachedConverter: AVAudioConverter?
  private var cachedInputFormat: AVAudioFormat?

  /// - Parameter targetSampleRate: defaults to the 16 kHz every engine requires
  ///   (`TranscriptionEngine.requiredSampleRate`); injectable so tests can prove
  ///   the ratio arithmetic at other rates.
  public init(targetSampleRate: Double = 16_000) throws {
    guard targetSampleRate.isFinite, targetSampleRate > 0,
      let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: targetSampleRate,
        channels: 1,
        interleaved: false)
    else {
      throw ResamplerError.unsupportedTargetSampleRate(targetSampleRate)
    }
    self.targetFormat = format
  }

  /// Converts one chunk of a recording that is still going. What the converter
  /// withholds (filter delay) is emitted by the following call or by `finish()`, so
  /// the number of samples returned by any single call is only approximately the
  /// input duration — the totals are what add up.
  ///
  /// An empty input buffer yields an empty `AudioBuffer` rather than an error: a tap
  /// can legitimately deliver zero frames, and that is not a failure.
  public func resample(_ buffer: AVAudioPCMBuffer) throws -> AudioBuffer {
    guard buffer.frameLength > 0 else {
      return AudioBuffer(samples: [], sampleRate: targetFormat.sampleRate)
    }
    let converter = try activeConverter(for: buffer.format)
    let samples = try convertOnce(
      converter: converter,
      input: buffer,
      endOfStream: false,
      frameCapacity: ResamplerMath.outputFrameCapacity(
        inputFrameCount: Int(buffer.frameLength),
        inputSampleRate: buffer.format.sampleRate,
        outputSampleRate: targetFormat.sampleRate))
    return AudioBuffer(samples: samples, sampleRate: targetFormat.sampleRate)
  }

  /// Ends the utterance: converts `buffer` if one is given, then flushes every frame
  /// still inside the converter and resets it for the next recording.
  ///
  /// Call this on hotkey release. With no argument it is a pure flush, so a chunked
  /// capture loop ends with `finish()` and a one-shot conversion is just
  /// `finish(wholeUtterance)`.
  public func finish(_ buffer: AVAudioPCMBuffer? = nil) throws -> AudioBuffer {
    var input: AVAudioPCMBuffer?
    if let buffer, buffer.frameLength > 0 {
      input = buffer
    }
    // Nothing was ever converted and nothing was handed in: nothing to flush.
    guard let converter = try input.map({ try activeConverter(for: $0.format) }) ?? cachedConverter
    else {
      return AudioBuffer(samples: [], sampleRate: targetFormat.sampleRate)
    }

    var samples = [Float]()
    for _ in 0..<Self.maximumFlushPasses {
      let capacity =
        input.map {
          ResamplerMath.outputFrameCapacity(
            inputFrameCount: Int($0.frameLength),
            inputSampleRate: $0.format.sampleRate,
            outputSampleRate: targetFormat.sampleRate)
        } ?? Self.flushFrameCapacity
      let produced = try convertOnce(
        converter: converter,
        input: input,
        endOfStream: true,
        frameCapacity: capacity)
      input = nil
      samples.append(contentsOf: produced)
      if produced.isEmpty { break }
    }

    // `.endOfStream` finalises the converter; reset so the next utterance starts
    // from a clean filter instead of inheriting this one's tail.
    converter.reset()
    return AudioBuffer(samples: samples, sampleRate: targetFormat.sampleRate)
  }

  /// Drops converter state without collecting the tail — for a cancelled recording.
  /// A completed recording should end with `finish()` instead.
  public func reset() {
    cachedConverter?.reset()
  }

  /// One `convert` call against a freshly allocated output buffer.
  ///
  /// A fresh buffer each time on purpose: `AVAudioPCMBuffer.frameLength` is not
  /// reliably cleared when a pass produces nothing, so reusing one buffer across
  /// passes can re-read stale frames and duplicate audio.
  private func convertOnce(
    converter: AVAudioConverter,
    input: AVAudioPCMBuffer?,
    endOfStream: Bool,
    frameCapacity: Int
  ) throws -> [Float] {
    guard
      let output = AVAudioPCMBuffer(
        pcmFormat: targetFormat,
        frameCapacity: AVAudioFrameCount(frameCapacity))
    else {
      throw ResamplerError.allocationFailed(frameCapacity: frameCapacity)
    }

    // The input block must hand the buffer over exactly once, so it needs one bit of
    // mutable state. `nonisolated(unsafe)` rather than a lock: the block is called
    // synchronously inside `convert` on this very thread (see the note on the import),
    // so there is no second accessor to synchronise with, and a lock here would sit
    // on the capture path for no benefit. Scope is this function body.
    nonisolated(unsafe) var pendingInput = input
    var conversionError: NSError?
    let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
      guard let next = pendingInput else {
        // `.noDataNow` keeps the converter alive for the next chunk; `.endOfStream`
        // makes it release the frames it is holding back.
        inputStatus.pointee = endOfStream ? .endOfStream : .noDataNow
        return nil
      }
      pendingInput = nil
      inputStatus.pointee = .haveData
      return next
    }

    switch status {
    case .haveData, .inputRanDry, .endOfStream:
      break
    case .error:
      throw ResamplerError.conversionFailed(code: conversionError?.code ?? -1)
    @unknown default:
      throw ResamplerError.conversionFailed(code: -1)
    }

    let produced = Int(output.frameLength)
    guard produced > 0, let channel = output.floatChannelData?[0] else { return [] }
    return Array(UnsafeBufferPointer(start: channel, count: produced))
  }

  /// Reuses the cached converter when the input format is unchanged; a device
  /// switch mid-session rebuilds it. Validates the format first so an impossible
  /// input is reported as such rather than as a missing converter.
  ///
  /// Rebuilding discards whatever the old converter was holding back (< ~62 ms).
  /// That is deliberate: those frames are in the *old* device's format and cannot be
  /// concatenated with the new one's output anyway, and a mid-utterance device
  /// switch already interrupts capture.
  private func activeConverter(for inputFormat: AVAudioFormat) throws -> AVAudioConverter {
    if let issue = ResamplerMath.validateInputFormat(
      sampleRate: inputFormat.sampleRate,
      channelCount: Int(inputFormat.channelCount))
    {
      throw issue
    }
    if let converter = cachedConverter, let cached = cachedInputFormat,
      cached.isEqual(inputFormat)
    {
      return converter
    }
    guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
      throw ResamplerError.converterUnavailable(
        inputSampleRate: inputFormat.sampleRate,
        inputChannels: Int(inputFormat.channelCount))
    }
    // Plain average down-mix when the mic has more channels than the engine wants.
    converter.downmix = true
    converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue
    cachedConverter = converter
    cachedInputFormat = inputFormat
    return converter
  }
}
