import AVFoundation
import Testing

@testable import FalaKit

/// `AudioCapture` itself needs a microphone and TCC, so it is verified manually
/// (T1.10). What IS testable is `CapturedChunk`: the copy that carries tap audio
/// across the isolation boundary. If it drops or reorders a channel, every
/// transcription degrades silently, so it is worth pinning.
@Suite("CapturedChunk")
struct CapturedChunkTests {

  private func makeBuffer(channels: [[Float]], sampleRate: Double) throws -> AVAudioPCMBuffer {
    let format = try #require(
      AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: sampleRate,
        channels: AVAudioChannelCount(channels.count),
        interleaved: false))
    let frames = channels[0].count
    let buffer = try #require(
      AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
    buffer.frameLength = AVAudioFrameCount(frames)
    let data = try #require(buffer.floatChannelData)
    for (index, samples) in channels.enumerated() {
      for (frame, sample) in samples.enumerated() {
        data[index][frame] = sample
      }
    }
    return buffer
  }

  @Test("Mono audio survives the copy exactly")
  func monoRoundTrip() throws {
    let samples: [Float] = (0..<512).map { Float($0) / 512 }
    let buffer = try makeBuffer(channels: [samples], sampleRate: 48_000)

    let chunk = try #require(CapturedChunk(buffer))
    #expect(chunk.sampleRate == 48_000)
    #expect(chunk.channels.count == 1)
    #expect(chunk.channels[0] == samples)
  }

  /// The regression that matters: channels must not be swapped or merged. A
  /// stereo mic with a dead channel would otherwise be indistinguishable from a
  /// working one.
  @Test("Stereo channels keep their identity and order")
  func stereoChannelsPreserved() throws {
    let left: [Float] = (0..<256).map { Float($0) }
    let right: [Float] = (0..<256).map { -Float($0) }
    let buffer = try makeBuffer(channels: [left, right], sampleRate: 44_100)

    let chunk = try #require(CapturedChunk(buffer))
    #expect(chunk.channels.count == 2)
    #expect(chunk.channels[0] == left)
    #expect(chunk.channels[1] == right)
  }

  @Test("Rebuilding produces a buffer the resampler can consume, unchanged")
  func rebuildPreservesEverything() throws {
    let left: [Float] = [0.1, -0.2, 0.3, -0.4]
    let right: [Float] = [0.5, -0.6, 0.7, -0.8]
    let original = try makeBuffer(channels: [left, right], sampleRate: 48_000)

    let chunk = try #require(CapturedChunk(original))
    let rebuilt = try #require(chunk.makeBuffer())

    #expect(rebuilt.format.sampleRate == 48_000)
    #expect(rebuilt.format.channelCount == 2)
    #expect(rebuilt.frameLength == 4)
    let data = try #require(rebuilt.floatChannelData)
    #expect(Array(UnsafeBufferPointer(start: data[0], count: 4)) == left)
    #expect(Array(UnsafeBufferPointer(start: data[1], count: 4)) == right)
  }

  @Test("A round-tripped chunk resamples to 16 kHz mono like the original would")
  func rebuiltBufferResamplesCorrectly() throws {
    // One second of 48 kHz stereo must yield exactly 16 000 samples at 16 kHz.
    let frames = 48_000
    let tone: [Float] = (0..<frames).map { sin(Float($0) * 0.01) }
    let buffer = try makeBuffer(channels: [tone, tone], sampleRate: 48_000)

    let chunk = try #require(CapturedChunk(buffer))
    let rebuilt = try #require(chunk.makeBuffer())

    let resampler = try Resampler()
    let converted = try resampler.finish(rebuilt)
    #expect(converted.sampleRate == 16_000)
    #expect(converted.samples.count == 16_000)
  }

  @Test("An empty tap callback is dropped rather than treated as audio")
  func emptyBufferIsRejected() throws {
    let format = try #require(
      AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 128))
    buffer.frameLength = 0

    #expect(CapturedChunk(buffer) == nil)
  }
}
