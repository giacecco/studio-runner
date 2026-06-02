import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

/// Captures audio from a specific CoreAudio input device (typically the
/// virtual loopback "BlackHole 2ch") into a 44.1 kHz stereo 16-bit PCM ring.
/// Distinct from the mic recorder because we have to switch the underlying
/// audio unit's `CurrentDevice` to a non-default input.
final class DAWRecorder {
    let buffer: RollingBuffer

    private let engine = AVAudioEngine()
    private let outFormat: AVAudioFormat

    private(set) var isRunning = false

    init(deviceID: AudioDeviceID) throws {
        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Config.dawSampleRate,
            channels: AVAudioChannelCount(Config.dawChannels),
            interleaved: true
        ) else {
            throw NSError(domain: "StudioRunner", code: 10,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to construct DAW target format"])
        }
        self.outFormat = target
        self.buffer = RollingBuffer(seconds: Config.dawBufferSeconds,
                                    bytesPerSecond: Config.dawBytesPerSecond)
        try setInputDevice(deviceID)
    }

    private func setInputDevice(_ deviceID: AudioDeviceID) throws {
        guard let au = engine.inputNode.audioUnit else {
            throw NSError(domain: "StudioRunner", code: 11,
                          userInfo: [NSLocalizedDescriptionKey: "Input node has no underlying audio unit"])
        }
        // Setting CurrentDevice requires the unit to be uninitialised.
        AudioUnitUninitialize(au)
        var devID = deviceID
        let status = AudioUnitSetProperty(
            au,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &devID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            throw NSError(domain: "StudioRunner", code: 12,
                          userInfo: [NSLocalizedDescriptionKey: "AudioUnitSetProperty(CurrentDevice) failed: \(status)"])
        }
        AudioUnitInitialize(au)
    }

    func start() throws {
        guard !isRunning else { return }
        let inFormat = engine.inputNode.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else {
            throw NSError(domain: "StudioRunner", code: 13,
                          userInfo: [NSLocalizedDescriptionKey: "DAW input device produced an empty format"])
        }
        guard let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
            throw NSError(domain: "StudioRunner", code: 14,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to build DAW AVAudioConverter"])
        }

        let buf = buffer
        let outFmt = outFormat

        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { inBuf, _ in
            let ratio = outFmt.sampleRate / inBuf.format.sampleRate
            let outCapacity = AVAudioFrameCount(Double(inBuf.frameLength) * ratio) + 32
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: outCapacity) else { return }

            var nsErr: NSError?
            var consumed = false
            let status = converter.convert(to: outBuf, error: &nsErr) { _, outStatus in
                if consumed { outStatus.pointee = .noDataNow; return nil }
                consumed = true
                outStatus.pointee = .haveData
                return inBuf
            }
            if status == .error { return }
            let frames = Int(outBuf.frameLength)
            if frames == 0 { return }
            let mb = outBuf.audioBufferList.pointee.mBuffers
            guard let basePtr = mb.mData else { return }
            let byteCount = frames * Int(outFmt.channelCount) * MemoryLayout<Int16>.size
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
