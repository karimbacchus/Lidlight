import Darwin

/// Lock-free single-producer/single-consumer ring buffer of mono samples.
///
/// One thread (the real-time audio callback) calls `write`; another (the analysis queue) calls `read`.
/// Neither allocates or blocks. When full, `write` drops the samples that don't fit.
package final class MonoRingBuffer {
    private let storage: UnsafeMutablePointer<Float>
    private let capacity: Int
    private let mask: Int
    // Monotonic counters; the producer owns `written`, the consumer owns `consumed`.
    private let written: UnsafeMutablePointer<Int>
    private let consumed: UnsafeMutablePointer<Int>

    /// Creates a buffer holding at least `minimumCapacity` samples (rounded up to a power of two).
    package init(minimumCapacity: Int) {
        var size = 16
        while size < minimumCapacity { size <<= 1 }
        capacity = size
        mask = size - 1
        storage = .allocate(capacity: size)
        storage.initialize(repeating: 0, count: size)
        written = .allocate(capacity: 1)
        written.initialize(to: 0)
        consumed = .allocate(capacity: 1)
        consumed.initialize(to: 0)
    }

    deinit {
        storage.deallocate()
        written.deallocate()
        consumed.deallocate()
    }

    /// Samples currently readable.
    package var availableToRead: Int {
        let w = written.pointee
        OSMemoryBarrier()
        return w - consumed.pointee
    }

    /// Producer side. Returns how many samples were stored.
    @discardableResult
    package func write(_ samples: UnsafePointer<Float>, count: Int) -> Int {
        let w = written.pointee
        let free = capacity - (w - consumed.pointee)
        let n = min(count, free)
        if n <= 0 { return 0 }
        for i in 0..<n { storage[(w + i) & mask] = samples[i] }
        OSMemoryBarrier()
        written.pointee = w + n
        return n
    }

    /// Consumer side. Copies up to `maxCount` samples into `destination`; returns the number copied.
    @discardableResult
    package func read(into destination: UnsafeMutablePointer<Float>, maxCount: Int) -> Int {
        let r = consumed.pointee
        let n = min(maxCount, availableToRead)
        if n <= 0 { return 0 }
        for i in 0..<n { destination[i] = storage[(r + i) & mask] }
        OSMemoryBarrier()
        consumed.pointee = r + n
        return n
    }
}
