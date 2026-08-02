import Foundation

/// Fixed-capacity circular buffer of PCM samples for the capture path
/// (SPEC.md FR-4: ~60 s of headroom so releasing the hotkey never truncates an
/// utterance). It never grows, never allocates while appending, and never blocks.
///
/// ## Why a value type and not an `actor`
/// This is a `struct` with no internal synchronisation, intended to be owned as a
/// stored property of a single actor (`AudioCapture`). Two reasons, in order of
/// importance:
///
/// 1. **Ordering.** An `actor` would make every append `async`. The `AVAudioEngine`
///    tap block cannot `await`, so each callback would have to spawn a `Task`, and
///    the order in which independent tasks reach an actor is NOT guaranteed to
///    match the order they were created. Audio reassembled out of order is
///    silently corrupt — a worse failure than dropped audio, because nothing
///    downstream can detect it. A value type inherits its owner's serialisation:
///    ordering is exactly the order of the owner's single execution context.
/// 2. **Nothing expensive on the capture path.** `append` is a bounded memcpy into
///    preallocated storage: no locks (CLAUDE.md forbids locks in the audio callback
///    path), no `Task` allocation, no actor hop, no reallocation.
///
/// The intended wiring is: tap block → an order-preserving, non-blocking hand-off
/// (e.g. `AsyncStream.Continuation.yield`, which is synchronous and FIFO) → one
/// consumer task inside `AudioCapture` → `ringBuffer.append(contentsOf:)`. Swift's
/// exclusivity checking then turns a second concurrent writer into a compile error
/// instead of a data race.
///
/// The buffer holds raw samples only; it is deliberately free of AVFoundation and
/// of any notion of what the audio contains, and it never logs (CLAUDE.md).
public struct RingBuffer: Sendable {
  /// SPEC.md FR-4 headroom.
  public static let defaultHeadroomSeconds: TimeInterval = 60

  /// Sanity clamp for the seconds-based initialiser: 10 minutes at 48 kHz. It
  /// exists so a nonsensical `seconds`/`sampleRate` pair cannot trap converting to
  /// `Int` or ask for an absurd allocation — library code must not trap (CLAUDE.md).
  static let maximumCapacity = 10 * 60 * 48_000

  /// Number of samples the buffer can hold; always >= 1.
  public let capacity: Int

  /// Preallocated backing store. Its size never changes after `init`.
  private var storage: [Float]

  /// Index the next appended sample is written to.
  private var writeIndex: Int

  /// Number of valid samples currently held, in `0...capacity`.
  private var filled: Int

  /// Samples discarded since the last `drain()`/`removeAll()` because newer audio
  /// overwrote them. A count, never audio — safe to log (CLAUDE.md).
  public private(set) var droppedSampleCount: Int

  /// - Parameter capacity: capacity in samples. Values below 1 are clamped to 1: a
  ///   zero-capacity ring buffer would silently swallow every utterance, and this
  ///   type has no error channel on the audio path, so the degenerate case is
  ///   normalised rather than trapped.
  public init(capacity: Int) {
    let clamped = min(max(capacity, 1), RingBuffer.maximumCapacity)
    self.capacity = clamped
    self.storage = [Float](repeating: 0, count: clamped)
    self.writeIndex = 0
    self.filled = 0
    self.droppedSampleCount = 0
  }

  /// Convenience for the capture pipeline: headroom expressed in seconds at a
  /// known sample rate (60 s at 16 kHz = 960 000 samples ≈ 3.8 MB).
  ///
  /// Non-finite or non-positive inputs collapse to the minimum capacity rather
  /// than trapping.
  public init(seconds: TimeInterval = RingBuffer.defaultHeadroomSeconds, sampleRate: Double) {
    let requested = (seconds * sampleRate).rounded(.up)
    let bounded =
      requested.isFinite ? min(max(requested, 0), Double(RingBuffer.maximumCapacity)) : 0
    self.init(capacity: Int(bounded))
  }

  /// Samples currently held.
  public var count: Int { filled }

  public var isEmpty: Bool { filled == 0 }

  /// True once the buffer has wrapped at least once, i.e. further appends will
  /// start discarding the oldest audio.
  public var isFull: Bool { filled == capacity }

  /// Wall-clock length of the stored audio at `sampleRate`.
  public func duration(atSampleRate sampleRate: Double) -> TimeInterval {
    sampleRate > 0 ? TimeInterval(filled) / sampleRate : 0
  }

  /// Appends samples, overwriting the oldest ones when the buffer is full.
  ///
  /// The primitive overload: takes a raw buffer so audio arriving as
  /// `AVAudioPCMBuffer.floatChannelData` can be handed over without a bridging
  /// allocation. Never grows, never blocks, never allocates.
  ///
  /// If `newSamples` is longer than `capacity`, only its newest `capacity` samples
  /// are retained — the older prefix could not have survived the same append
  /// anyway.
  public mutating func append(contentsOf newSamples: UnsafeBufferPointer<Float>) {
    guard let source = newSamples.baseAddress, !newSamples.isEmpty else { return }
    let incoming = newSamples.count
    droppedSampleCount += max(0, filled + incoming - capacity)

    let copyCount = min(incoming, capacity)
    let sourceStart = source + (incoming - copyCount)
    let start = writeIndex
    let cap = capacity
    let headCount = min(copyCount, cap - start)

    storage.withUnsafeMutableBufferPointer { destination in
      guard let base = destination.baseAddress else { return }
      base.advanced(by: start).update(from: sourceStart, count: headCount)
      let tailCount = copyCount - headCount
      if tailCount > 0 {
        base.update(from: sourceStart + headCount, count: tailCount)
      }
    }

    writeIndex = (start + copyCount) % cap
    filled = min(filled + copyCount, cap)
  }

  /// Array convenience over the primitive overload.
  public mutating func append(contentsOf newSamples: [Float]) {
    newSamples.withUnsafeBufferPointer { append(contentsOf: $0) }
  }

  /// Slice convenience over the primitive overload.
  public mutating func append(contentsOf newSamples: ArraySlice<Float>) {
    newSamples.withUnsafeBufferPointer { append(contentsOf: $0) }
  }

  /// The stored samples in chronological order (oldest first), without consuming
  /// them. Allocates, so call it off the capture path.
  public func snapshot() -> [Float] {
    guard filled > 0 else { return [] }
    let start = (writeIndex - filled + capacity) % capacity
    if start + filled <= capacity {
      return Array(storage[start..<(start + filled)])
    }
    let headCount = capacity - start
    var result = [Float]()
    result.reserveCapacity(filled)
    result.append(contentsOf: storage[start...])
    result.append(contentsOf: storage[..<(filled - headCount)])
    return result
  }

  /// Snapshot and empty in one step — the hotkey-release path, where the utterance
  /// is handed to the transcription engine and the buffer starts a new recording.
  public mutating func drain() -> [Float] {
    let samples = snapshot()
    removeAll()
    return samples
  }

  /// Discards the contents and the drop counter, keeping the allocation so the
  /// next recording still appends without allocating.
  public mutating func removeAll() {
    writeIndex = 0
    filled = 0
    droppedSampleCount = 0
  }
}
