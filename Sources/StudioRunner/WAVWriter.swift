import Foundation

/// Wraps interleaved PCM bytes in a minimal RIFF/WAVE container and writes it
/// to disk. Sufficient for whisper-cli, sox, and Audacity.
enum WAVWriter {
    static func write(
        samples: Data,
        sampleRate: Int,
        channels: Int,
        bitDepth: Int,
        to url: URL
    ) throws {
        let byteRate = sampleRate * channels * bitDepth / 8
        let blockAlign = channels * bitDepth / 8
        let dataSize = samples.count
        let fileSize = 36 + dataSize

        var header = Data()
        header.append("RIFF".data(using: .ascii)!)
        header.appendLE(UInt32(fileSize))
        header.append("WAVE".data(using: .ascii)!)
        header.append("fmt ".data(using: .ascii)!)
        header.appendLE(UInt32(16))                  // fmt chunk size
        header.appendLE(UInt16(1))                   // PCM
        header.appendLE(UInt16(channels))
        header.appendLE(UInt32(sampleRate))
        header.appendLE(UInt32(byteRate))
        header.appendLE(UInt16(blockAlign))
        header.appendLE(UInt16(bitDepth))
        header.append("data".data(using: .ascii)!)
        header.appendLE(UInt32(dataSize))

        try (header + samples).write(to: url, options: .atomic)
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { self.append(contentsOf: $0) }
    }
}
