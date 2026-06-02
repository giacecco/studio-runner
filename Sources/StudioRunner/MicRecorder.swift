import AVFoundation
import Foundation

/// Continuously captures the default input device into a 16 kHz mono 16-bit
/// signed-PCM ring buffer. Applies a linear gain to compensate for low input
/// levels (mirrors the bun script's `sox gain <dB>` step).
final class MicRecorder {
    let buffer: RollingBuffer

    private let engine = AVAudioEngine()
    private let outFormat: AVAudioFormat
    private let gainFactor: Float

    private(set) var isRunning = false

    init(gainDb: Double) throws {
        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Config.micSampleRate,
            channels: AVAudioChannelCount(Config.micChannels),
            interleaved: true
        ) else {
            throw NSError(domain: "StudioRunner", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to construct mic target format"])
        }
        self.outFormat = target
        self.gainFactor = Float(pow(10.0, gainDb / 20.0))
        self.buffer = RollingBuffer(seconds: Config.micBufferSeconds,
                                    bytesPerSecond: Config.micBytesPerSecond)
    }

    func start() throws {
        guard !isRunning else { return }
        let inFormat = engine.inputNode.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0 else {
            throw NSError(domain: "StudioRunner", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Default input device has no input channels"])
        }
        guard let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
            throw NSError(domain: "StudioRunner", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to build mic AVAudioConverter"])
        }

        let gain = gainFactor
        let buf = buffer
        let outFmt = outFormat

        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { inBuf, _ in
            let ratio = outFmt.sampleRate / inBuf.format.sampleRate
            let outCapacity = AVAudioFrameCount(Double(inBuf.frameLength) * ratio) + 32
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: outCapacity) else { return }

            var nsErr: NSError?
            var consumed = false
            let status = converter.convert(to: outBuf, error: &nsErr) { _, outStatus in
                if consumed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                consumed = true
                outStatus.pointee = .haveData
                return inBuf
            }
            if status == .error { return }
            let frames = Int(outBuf.frameLength)
            if frames == 0 { return }

            // Interleaved Int16 → audioBufferList.pointee.mBuffers.mData is the
            // contiguous byte run we want.
            let abl = outBuf.audioBufferList
            let mb = abl.pointee.mBuffers
            guard let basePtr = mb.mData else { return }
            let int16Ptr = basePtr.assumingMemoryBound(to: Int16.self)
            let sampleCount = frames * Int(outFmt.channelCount)
            for i in 0..<sampleCount {
                let scaled = Float(int16Ptr[i]) * gain
                int16Ptr[i] = Int16(max(-32768, min(32767, Int(scaled))))
            }
            let byteCount = sampleCount * MemoryLayout<Int16>.size
            buf.append(UnsafeRawBufferPointer(start: basePtr, count: byteCount))
        }

        engine.prepare()
        try engine.start()
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
    }
}
