import Foundation
import Testing

@testable import FalaKit

/// Covers the DoD for T1.2: wrap-around, overflow, exact capacity, empty, and
/// chronological drain order.
@Suite("RingBuffer")
struct RingBufferTests {

  // MARK: - Capacity

  @Test("Sixty seconds at 16 kHz is 960 000 samples (SPEC.md FR-4)")
  func headroomCapacity() {
    let buffer = RingBuffer(sampleRate: 16_000)
    #expect(buffer.capacity == 960_000)
    #expect(buffer.isEmpty)
  }

  @Test("Seconds initialiser rounds up to a whole sample")
  func secondsRoundUp() {
    let buffer = RingBuffer(seconds: 0.0001, sampleRate: 44_100)
    #expect(buffer.capacity == 5)  // 4.41 samples
  }

  @Test("Degenerate capacities are clamped, never trapped")
  func degenerateCapacities() {
    #expect(RingBuffer(capacity: 0).capacity == 1)
    #expect(RingBuffer(capacity: -100).capacity == 1)
    #expect(RingBuffer(seconds: -60, sampleRate: 16_000).capacity == 1)
    #expect(RingBuffer(seconds: .nan, sampleRate: 16_000).capacity == 1)
    #expect(RingBuffer(seconds: .infinity, sampleRate: 16_000).capacity == 1)
  }

  @Test("An absurd but finite request is capped instead of allocating unboundedly")
  func hugeCapacityIsCapped() {
    let buffer = RingBuffer(seconds: 1_000_000, sampleRate: 48_000)
    #expect(buffer.capacity == RingBuffer.maximumCapacity)
  }

  // MARK: - Empty

  @Test("An empty buffer snapshots and drains to nothing")
  func emptyBuffer() {
    var buffer = RingBuffer(capacity: 8)
    #expect(buffer.isEmpty)
    #expect(!buffer.isFull)
    #expect(buffer.count == 0)
    #expect(buffer.snapshot().isEmpty)
    #expect(buffer.drain().isEmpty)
    #expect(buffer.droppedSampleCount == 0)
    #expect(buffer.duration(atSampleRate: 16_000) == 0)
  }

  @Test("Appending nothing is a no-op")
  func appendEmpty() {
    var buffer = RingBuffer(capacity: 4)
    buffer.append(contentsOf: [Float]())
    #expect(buffer.isEmpty)
    #expect(buffer.droppedSampleCount == 0)
  }

  // MARK: - Partial fill and drain order

  @Test("Below capacity everything is kept, oldest first")
  func partialFillPreservesOrder() {
    var buffer = RingBuffer(capacity: 8)
    buffer.append(contentsOf: [1, 2, 3] as [Float])
    buffer.append(contentsOf: [4, 5] as [Float])
    #expect(buffer.count == 5)
    #expect(!buffer.isFull)
    #expect(buffer.snapshot() == [1, 2, 3, 4, 5])
    #expect(buffer.droppedSampleCount == 0)
  }

  @Test("Snapshot does not consume; drain does")
  func snapshotVersusDrain() {
    var buffer = RingBuffer(capacity: 8)
    buffer.append(contentsOf: [1, 2, 3] as [Float])
    #expect(buffer.snapshot() == [1, 2, 3])
    #expect(buffer.count == 3)

    #expect(buffer.drain() == [1, 2, 3])
    #expect(buffer.isEmpty)
    #expect(buffer.snapshot().isEmpty)

    // A drained buffer is reusable for the next utterance.
    buffer.append(contentsOf: [9, 8] as [Float])
    #expect(buffer.snapshot() == [9, 8])
  }

  @Test("Duration reflects the stored sample count")
  func durationAtSampleRate() {
    var buffer = RingBuffer(capacity: 16_000)
    buffer.append(contentsOf: [Float](repeating: 0.1, count: 8_000))
    #expect(abs(buffer.duration(atSampleRate: 16_000) - 0.5) < 1e-9)
    #expect(buffer.duration(atSampleRate: 0) == 0)
  }

  // MARK: - Exact capacity

  @Test("Filling to exactly capacity keeps every sample")
  func exactCapacity() {
    var buffer = RingBuffer(capacity: 4)
    buffer.append(contentsOf: [1, 2, 3, 4] as [Float])
    #expect(buffer.count == 4)
    #expect(buffer.isFull)
    #expect(buffer.snapshot() == [1, 2, 3, 4])
    #expect(buffer.droppedSampleCount == 0)
  }

  @Test("Exact capacity reached in chunks that land on the boundary")
  func exactCapacityInChunks() {
    var buffer = RingBuffer(capacity: 6)
    buffer.append(contentsOf: [1, 2, 3] as [Float])
    buffer.append(contentsOf: [4, 5, 6] as [Float])
    #expect(buffer.isFull)
    #expect(buffer.snapshot() == [1, 2, 3, 4, 5, 6])
  }

  // MARK: - Overflow

  @Test("One sample past capacity drops exactly the oldest sample")
  func overflowByOne() {
    var buffer = RingBuffer(capacity: 4)
    buffer.append(contentsOf: [1, 2, 3, 4] as [Float])
    buffer.append(contentsOf: [5] as [Float])
    #expect(buffer.count == 4)
    #expect(buffer.snapshot() == [2, 3, 4, 5])
    #expect(buffer.droppedSampleCount == 1)
  }

  @Test("A single chunk longer than capacity keeps only its newest tail")
  func chunkLargerThanCapacity() {
    var buffer = RingBuffer(capacity: 4)
    buffer.append(contentsOf: [1, 2, 3, 4, 5, 6, 7, 8, 9] as [Float])
    #expect(buffer.count == 4)
    #expect(buffer.snapshot() == [6, 7, 8, 9])
    #expect(buffer.droppedSampleCount == 5)
  }

  @Test("An oversized chunk on a partly filled buffer still keeps the newest tail")
  func oversizedChunkOverPartialContents() {
    var buffer = RingBuffer(capacity: 4)
    buffer.append(contentsOf: [100, 101] as [Float])
    buffer.append(contentsOf: [1, 2, 3, 4, 5] as [Float])
    #expect(buffer.snapshot() == [2, 3, 4, 5])
    // 2 pre-existing + 5 incoming = 7 samples through a 4-sample window.
    #expect(buffer.droppedSampleCount == 3)
  }

  @Test("Capacity never grows, however much audio is pushed through")
  func capacityNeverGrows() {
    var buffer = RingBuffer(capacity: 100)
    for _ in 0..<50 {
      buffer.append(contentsOf: [Float](repeating: 0.25, count: 64))
    }
    #expect(buffer.capacity == 100)
    #expect(buffer.count == 100)
    #expect(buffer.snapshot().count == 100)
    #expect(buffer.droppedSampleCount == 50 * 64 - 100)
  }

  // MARK: - Wrap-around

  @Test("Writes that straddle the physical end read back in chronological order")
  func wrapAroundAcrossChunks() {
    var buffer = RingBuffer(capacity: 5)
    buffer.append(contentsOf: [1, 2, 3, 4] as [Float])  // writeIndex = 4
    buffer.append(contentsOf: [5, 6, 7] as [Float])  // wraps: 1 head + 2 tail
    #expect(buffer.count == 5)
    #expect(buffer.snapshot() == [3, 4, 5, 6, 7])
    #expect(buffer.droppedSampleCount == 2)
  }

  @Test("Repeated wraps keep exactly the newest window")
  func repeatedWraps() {
    var buffer = RingBuffer(capacity: 5)
    var next: Float = 1
    for _ in 0..<10 {
      buffer.append(contentsOf: [next, next + 1, next + 2] as [Float])
      next += 3
    }
    // 30 samples appended in threes through a 5-sample window.
    #expect(buffer.snapshot() == [26, 27, 28, 29, 30])
    #expect(buffer.droppedSampleCount == 25)
  }

  @Test("Wrapping one sample at a time matches the naive suffix")
  func wrapOneSampleAtATime() {
    var buffer = RingBuffer(capacity: 7)
    var expected = [Float]()
    for value in 1...40 {
      buffer.append(contentsOf: [Float(value)])
      expected.append(Float(value))
      expected = Array(expected.suffix(7))
      #expect(buffer.snapshot() == expected)
    }
  }

  @Test("Drain after a wrap returns chronological order and resets the drop count")
  func drainAfterWrap() {
    var buffer = RingBuffer(capacity: 4)
    buffer.append(contentsOf: [1, 2, 3, 4, 5, 6] as [Float])
    #expect(buffer.drain() == [3, 4, 5, 6])
    #expect(buffer.isEmpty)
    #expect(buffer.droppedSampleCount == 0)
  }

  // MARK: - Alternative append overloads

  @Test("Slice and raw-pointer overloads behave like the array overload")
  func appendOverloadsAgree() {
    let source: [Float] = [1, 2, 3, 4, 5, 6]

    var fromSlice = RingBuffer(capacity: 4)
    fromSlice.append(contentsOf: source[0..<6])

    var fromPointer = RingBuffer(capacity: 4)
    source.withUnsafeBufferPointer { fromPointer.append(contentsOf: $0) }

    #expect(fromSlice.snapshot() == [3, 4, 5, 6])
    #expect(fromPointer.snapshot() == [3, 4, 5, 6])
  }

  // MARK: - Value semantics

  @Test("Copies are independent — the reason this is a struct, not a reference type")
  func valueSemantics() {
    var original = RingBuffer(capacity: 4)
    original.append(contentsOf: [1, 2] as [Float])

    var copy = original
    copy.append(contentsOf: [3, 4, 5] as [Float])

    #expect(original.snapshot() == [1, 2])
    #expect(copy.snapshot() == [2, 3, 4, 5])
  }
}
