import AVFoundation
import CoreAudio
import CoreMedia
import Foundation

/// Continuously captures an input device into a 16 kHz mono 16-bit signed-PCM
/// ring buffer via AVCaptureSession. Applies a linear gain to compensate for
/// low input levels.
///
/// Uses AVCaptureSession (not AVAudioEngine) because on macOS Sequoia the
/// AVAudioEngine input tap silently delivers no data when the engine has no
/// complete audio graph — a workaround that is fragile and output-device
/// dependent. AVCaptureSession delivers audio reliably on all macOS versions.
final class MicRecorder: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    let buffer: RollingBuffer

    private let session = AVCaptureSession()
    private let captureQueue = DispatchQueue(label: "studio.runner.mic.capture", qos: .userInitiated)
    private let outFormat: AVAudioFormat
    private let gainFactor: Float
    private let requestedDeviceID: AudioDeviceID?

    private(set) var isRunning = false

    init(gainDb: Double, deviceID: AudioDeviceID? = nil) throws {
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
        self.requestedDeviceID = deviceID
        super.init()
    }

    func start() throws {
        guard !isRunning else { return }

        let device: AVCaptureDevice
        if let devID = requestedDeviceID,
           let found = MicRecorder.captureDevice(forCoreAudioID: devID) {
            device = found
        } else {
            guard let def = AVCaptureDevice.default(for: .audio) else {
                throw NSError(domain: "StudioRunner", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "No default audio input device"])
            }
            device = def
        }

        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(self, queue: captureQueue)

        session.beginConfiguration()
        if session.canAddInput(input) { session.addInput(input) }
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()
        session.startRunning()

        guard session.isRunning else {
            throw NSError(domain: "StudioRunner", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "AVCaptureSession failed to start"])
        }
        isRunning = true
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

        // Fresh converter each call — AVAudioConverter retains internal SRC state
        // across calls, which causes zero output frames on the second and later
        // discrete CMSampleBuffer chunks when the converter is reused.
        guard let conv = AVAudioConverter(from: inFmt, to: outFormat) else { return }

        // Copy CMSampleBuffer data into an AVAudioPCMBuffer for the converter.
        guard let inputBuf = AVAudioPCMBuffer(pcmFormat: inFmt,
                                               frameCapacity: AVAudioFrameCount(frameCount)) else { return }
        inputBuf.frameLength = AVAudioFrameCount(frameCount)
        let copyStatus = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frameCount),
            into: inputBuf.mutableAudioBufferList
        )
        guard copyStatus == noErr else { return }

        // Convert to 16 kHz mono Int16.
        let ratio = outFormat.sampleRate / inFmt.sampleRate
        let outCapacity = AVAudioFrameCount(Double(frameCount) * ratio) + 32
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat,
                                             frameCapacity: outCapacity) else { return }
        var consumed = false
        var nsErr: NSError?
        let status = conv.convert(to: outBuf, error: &nsErr) { _, outStatus in
            if consumed { outStatus.pointee = .noDataNow; return nil }
            consumed = true; outStatus.pointee = .haveData
            return inputBuf
        }
        if status == .error { return }
        let frames = Int(outBuf.frameLength)
        if frames == 0 { return }

        // Apply gain and append interleaved Int16 bytes to the ring buffer.
        let mb = outBuf.audioBufferList.pointee.mBuffers
        guard let basePtr = mb.mData else { return }
        let int16Ptr = basePtr.assumingMemoryBound(to: Int16.self)
        let g = gainFactor
        for i in 0..<frames {
            let s = Float(int16Ptr[i]) * g
            int16Ptr[i] = Int16(max(-32768, min(32767, Int(s))))
        }
        buffer.append(UnsafeRawBufferPointer(start: basePtr, count: frames * 2))
    }

    // MARK: - Device mapping

    private static func captureDevice(forCoreAudioID devID: AudioDeviceID) -> AVCaptureDevice? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(devID, &addr, 0, nil, &size, &uid)
        guard status == noErr, let uidStr = uid?.takeRetainedValue() as String? else { return nil }
        return AVCaptureDevice(uniqueID: uidStr)
    }
}
