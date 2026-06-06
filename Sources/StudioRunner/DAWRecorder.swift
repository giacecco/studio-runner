import AVFoundation
import CoreAudio
import CoreMedia
import Foundation

/// Captures audio from a specific CoreAudio input device (typically the
/// virtual loopback "BlackHole 2ch") into a stereo 16-bit PCM ring at
/// the device's actual sample rate.
///
/// Uses AVCaptureSession (not AVAudioEngine) so the device is addressed
/// directly rather than through an AVAudioEngine aggregate, which on macOS
/// Sequoia exposes non-default input devices with a broken channel map
/// (mono, wrong sample rate).
final class DAWRecorder: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    let buffer: RollingBuffer

    private let session = AVCaptureSession()
    private let captureQueue = DispatchQueue(label: "studio.runner.daw.capture", qos: .userInitiated)
    private let coreAudioDeviceID: AudioDeviceID
    private var firstBuffer = true

    private(set) var isRunning = false

    init(deviceID: AudioDeviceID) throws {
        self.coreAudioDeviceID = deviceID

        // Seed the buffer with the device's nominal rate; corrected on first callback.
        var sr: Float64 = Config.dawSampleRate
        var srSize = UInt32(MemoryLayout<Float64>.size)
        var srAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(deviceID, &srAddr, 0, nil, &srSize, &sr)

        let bps = Int(sr) * Int(Config.dawChannels) * MemoryLayout<Int16>.size
        self.buffer = RollingBuffer(seconds: Config.dawBufferSeconds, bytesPerSecond: bps)
        NSLog("studio-runner: DAWRecorder init — deviceID=%d sr=%.0f", deviceID, sr)
        super.init()
    }

    func start() throws {
        guard !isRunning else { return }

        guard let device = DAWRecorder.captureDevice(forCoreAudioID: coreAudioDeviceID) else {
            throw NSError(domain: "StudioRunner", code: 11,
                          userInfo: [NSLocalizedDescriptionKey: "DAW device not found as AVCaptureDevice (id=\(coreAudioDeviceID))"])
        }

        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(self, queue: captureQueue)

        session.beginConfiguration()
        if session.canAddInput(input)  { session.addInput(input) }
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()
        session.startRunning()

        guard session.isRunning else {
            throw NSError(domain: "StudioRunner", code: 12,
                          userInfo: [NSLocalizedDescriptionKey: "DAW AVCaptureSession failed to start"])
        }
        isRunning = true
        NSLog("studio-runner: DAWRecorder session started")
    }

    func stop() {
        guard isRunning else { return }
        session.stopRunning()
        isRunning = false
    }

    // MARK: - AVCaptureAudioDataOutputSampleBufferDelegate

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc),
              let inFmt = AVAudioFormat(streamDescription: asbdPtr) else { return }

        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0 else { return }

        let inChannels  = Int(inFmt.channelCount)
        let outChannels = Int(Config.dawChannels)

        if firstBuffer {
            firstBuffer = false
            let actualBps = Int(inFmt.sampleRate) * outChannels * MemoryLayout<Int16>.size
            buffer.updateBytesPerSecond(actualBps)
            NSLog("studio-runner: DAWRecorder first buffer — sr=%.0f inCh=%d interleaved=%d",
                  inFmt.sampleRate, inChannels, inFmt.isInterleaved ? 1 : 0)
        }

        // Copy sample buffer data into an AVAudioPCMBuffer for channel access.
        guard let inputBuf = AVAudioPCMBuffer(pcmFormat: inFmt,
                                               frameCapacity: AVAudioFrameCount(frameCount)) else { return }
        inputBuf.frameLength = AVAudioFrameCount(frameCount)
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frameCount),
            into: inputBuf.mutableAudioBufferList) == noErr else { return }

        // Manual Float32 → Int16 interleaved.
        // Handles both interleaved and non-interleaved source layouts.
        // If input is mono, duplicates to all output channels.
        guard let floatData = inputBuf.floatChannelData else { return }
        var out = [Int16](repeating: 0, count: frameCount * outChannels)
        if inFmt.isInterleaved {
            // floatData[0] = [ch0_f0, ch1_f0, ch0_f1, ch1_f1, …]
            for frame in 0..<frameCount {
                for ch in 0..<outChannels {
                    let srcCh = min(ch, inChannels - 1)
                    let f = floatData[0][frame * inChannels + srcCh]
                    out[frame * outChannels + ch] = Int16(max(-1.0, min(1.0, f)) * 32767.0)
                }
            }
        } else {
            // floatData[ch] = channel ch samples
            for frame in 0..<frameCount {
                for ch in 0..<outChannels {
                    let srcCh = min(ch, inChannels - 1)
                    let f = floatData[srcCh][frame]
                    out[frame * outChannels + ch] = Int16(max(-1.0, min(1.0, f)) * 32767.0)
                }
            }
        }
        out.withUnsafeBytes { buffer.append($0) }
    }

    // MARK: - Device lookup

    private static func captureDevice(forCoreAudioID devID: AudioDeviceID) -> AVCaptureDevice? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(devID, &addr, 0, nil, &size, &uid) == noErr,
              let uidStr = uid?.takeRetainedValue() as String? else { return nil }
        return AVCaptureDevice(uniqueID: uidStr)
    }
}
