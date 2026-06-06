import Foundation

/// Fixed-size in-memory ring of PCM bytes with wall-clock-aware extraction.
///
/// We don't store per-sample timestamps. Instead, we derive the wall-clock
/// time of the oldest byte from how much audio is currently in the ring:
///
///     bufferStartMs = now − (bytesInRing / bytesPerSecond) · 1000
///
/// This self-corrects for write-thread jitter: it doesn't matter when bytes
/// arrived, only how many we hold right now. Same idea as the bun script's
/// `statSync(rolling.raw).size / bytesPerSec` derivation, but in memory.
final class RollingBuffer {
    let capacityBytes: Int
    private(set) var bytesPerSecond: Int

    private var store: UnsafeMutableRawPointer
    private var writeOffset: Int = 0
    private(set) var totalBytesWritten: Int = 0
    private let lock = NSLock()

    init(seconds: Double, bytesPerSecond: Int) {
        self.bytesPerSecond = bytesPerSecond
        // Round up to an even sample boundary so wraps never split a 16-bit sample.
        let raw = Int((seconds * Double(bytesPerSecond)).rounded(.up))
        self.capacityBytes = raw + (raw & 1)
        self.store = UnsafeMutableRawPointer.allocate(byteCount: capacityBytes, alignment: 16)
        memset(self.store, 0, capacityBytes)
    }

    deinit {
        store.deallocate()
    }

    func updateBytesPerSecond(_ bps: Int) {
        lock.lock(); defer { lock.unlock() }
        bytesPerSecond = bps
    }

    func append(_ bytes: UnsafeRawBufferPointer) {
        guard let src = bytes.baseAddress, !bytes.isEmpty else { return }
        let n = bytes.count
        lock.lock(); defer { lock.unlock() }

        var srcIdx = 0
        var dst = writeOffset
        while srcIdx < n {
            let chunk = min(n - srcIdx, capacityBytes - dst)
            memcpy(store.advanced(by: dst), src.advanced(by: srcIdx), chunk)
            srcIdx += chunk
            dst = (dst + chunk) % capacityBytes
        }
        writeOffset = dst
        totalBytesWritten += n
    }

    /// Copy the slice covering `[startMs, endMs]` wall-clock. Returns `nil` if
    /// the requested window has already fallen out of the ring or is empty.
    /// Bytes are aligned to the 2-byte 16-bit sample boundary.
    func extract(startMs: Double, endMs: Double) -> Data? {
        lock.lock(); defer { lock.unlock() }
        guard totalBytesWritten > 0 else { return nil }
        let nowMs = Date().timeIntervalSince1970 * 1000
        let inRing = min(totalBytesWritten, capacityBytes)
        let bufferStartMs = nowMs - Double(inRing) / Double(bytesPerSecond) * 1000

        let s = max(startMs, bufferStartMs)
        let e = min(endMs, nowMs)
        if e <= s { return nil }

        // Offset into the logical (oldest-byte-first) buffer where we want to start.
        let rawStartOffset = Int(((s - bufferStartMs) / 1000 * Double(bytesPerSecond)).rounded())
        let rawDuration = Int(((e - s) / 1000 * Double(bytesPerSecond)).rounded())
        let startOffset = max(0, rawStartOffset & ~0x1)
        let duration = max(0, rawDuration & ~0x1)
        if duration == 0 || startOffset >= inRing { return nil }
        let clampedDuration = min(duration, inRing - startOffset)
        if clampedDuration <= 0 { return nil }

        // Index in the physical ring where "oldest byte" lives.
        let ringOldestIdx = totalBytesWritten >= capacityBytes ? writeOffset : 0
        var srcIdx = (ringOldestIdx + startOffset) % capacityBytes
        var out = Data(count: clampedDuration)
        out.withUnsafeMutableBytes { dst in
            guard let dstBase = dst.baseAddress else { return }
            var written = 0
            while written < clampedDuration {
                let chunk = min(clampedDuration - written, capacityBytes - srcIdx)
                memcpy(dstBase.advanced(by: written), store.advanced(by: srcIdx), chunk)
                written += chunk
                srcIdx = (srcIdx + chunk) % capacityBytes
            }
        }
        return out
    }
}
