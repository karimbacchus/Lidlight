import CoreAudio
import Foundation
import LidlightKit

/// One live capture: process tap → private aggregate device → IOProc → ring buffer → beat detector.
///
/// `start` creates and starts everything, or tears down what it built and throws.
/// `stop` tears down in reverse order and is idempotent.
@available(macOS 14.2, *)
final class AudioCaptureSession {
    private typealias PropertyListener = (AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var deviceStarted = false
    private var listeners: [PropertyListener] = []

    private let ring = MonoRingBuffer(minimumCapacity: 1 << 16)
    private let ioScratch: UnsafeMutablePointer<Float>
    private let analysisScratch: UnsafeMutablePointer<Float>
    private static let scratchFrames = 4096
    private let analysisQueue = DispatchQueue(label: "app.lidlight.audio.analysis", qos: .utility)
    private var timer: DispatchSourceTimer?

    init() {
        ioScratch = .allocate(capacity: Self.scratchFrames)
        ioScratch.initialize(repeating: 0, count: Self.scratchFrames)
        analysisScratch = .allocate(capacity: Self.scratchFrames)
        analysisScratch.initialize(repeating: 0, count: Self.scratchFrames)
    }

    deinit {
        ioScratch.deallocate()
        analysisScratch.deallocate()
    }

    /// Builds and starts the capture. `onBeat` and `onLevel` are delivered on the main queue;
    /// `onConfigurationChange` fires (on an arbitrary queue) when the default output device or tap format changes.
    func start(
        onBeat: @escaping (BeatEvent) -> Void,
        onLevel: ((Double) -> Void)?,
        onConfigurationChange: @escaping () -> Void
    ) throws {
        do {
            try build(onBeat: onBeat, onLevel: onLevel, onConfigurationChange: onConfigurationChange)
        } catch {
            stop()
            throw error
        }
    }

    private func build(
        onBeat: @escaping (BeatEvent) -> Void,
        onLevel: ((Double) -> Void)?,
        onConfigurationChange: @escaping () -> Void
    ) throws {
        // 1. Tap: all processes' output, mixed to stereo, unmuted, private to this process.
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.muteBehavior = .unmuted
        description.isPrivate = true
        var status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else {
            // Creation is refused with a generic error when System Audio Recording isn't allowed.
            if status == kAudioHardwareIllegalOperationError || status == kAudioHardwareUnspecifiedError {
                throw AudioCaptureError.denied
            }
            throw AudioCaptureError.coreAudio(step: "create the audio tap", status: status)
        }

        // 2. Tap format (always 32-bit float PCM).
        let (formatStatus, format) = CoreAudioProperty.get(
            tapID, kAudioTapPropertyFormat, as: AudioStreamBasicDescription.self, initial: AudioStreamBasicDescription())
        guard formatStatus == noErr, format.mSampleRate > 0, format.mChannelsPerFrame > 0 else {
            throw AudioCaptureError.coreAudio(step: "read the tap format", status: formatStatus)
        }

        // 3. Private aggregate device whose only content is the tap, clocked by the default output device.
        guard let outputUID = CoreAudioProperty.defaultOutputDeviceUID() else {
            throw AudioCaptureError.coreAudio(step: "find the default output device", status: kAudioHardwareBadDeviceError)
        }
        let composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Lidlight Audio Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: description.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        status = AudioHardwareCreateAggregateDevice(composition as CFDictionary, &aggregateID)
        guard status == noErr else {
            if status == kAudioHardwareIllegalOperationError { throw AudioCaptureError.denied }
            throw AudioCaptureError.coreAudio(step: "create the aggregate device", status: status)
        }

        // 4. IOProc: real-time mixdown into the ring buffer.
        let ring = self.ring
        let scratch = ioScratch
        let capacity = Self.scratchFrames
        let channels = Int(format.mChannelsPerFrame)
        let interleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, nil) { _, inputData, _, _, _ in
            Self.mixDown(inputData, channels: channels, interleaved: interleaved, scratch: scratch, capacity: capacity, into: ring)
        }
        guard status == noErr, let ioProcID else {
            throw AudioCaptureError.coreAudio(step: "create the IO proc", status: status)
        }

        // 5. Analysis loop (before the device starts so no audio is missed).
        startAnalysis(sampleRate: format.mSampleRate, onBeat: onBeat, onLevel: onLevel)

        // 6. Observe changes that invalidate this graph.
        let system = AudioObjectID(kAudioObjectSystemObject)
        observe(system, kAudioHardwarePropertyDefaultOutputDevice, onChange: onConfigurationChange)
        observe(tapID, kAudioTapPropertyFormat, onChange: onConfigurationChange)

        status = AudioDeviceStart(aggregateID, ioProcID)
        guard status == noErr else {
            if status == kAudioHardwareIllegalOperationError { throw AudioCaptureError.denied }
            throw AudioCaptureError.coreAudio(step: "start the audio device", status: status)
        }
        deviceStarted = true
    }

    /// Stops and destroys everything in reverse order of creation.
    func stop() {
        for (object, address, block) in listeners {
            var address = address
            AudioObjectRemovePropertyListenerBlock(object, &address, DispatchQueue.global(qos: .utility), block)
        }
        listeners.removeAll()
        if let timer {
            timer.cancel()
            self.timer = nil
        }
        if deviceStarted, let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
            deviceStarted = false
        }
        if let ioProcID, aggregateID != kAudioObjectUnknown {
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    // MARK: Real-time

    /// Runs on the audio thread: no allocation, locks, logging or Objective-C messaging.
    private static func mixDown(
        _ inputData: UnsafePointer<AudioBufferList>, channels: Int, interleaved: Bool,
        scratch: UnsafeMutablePointer<Float>, capacity: Int, into ring: MonoRingBuffer
    ) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        guard buffers.count > 0 else { return }
        let scale = 1 / Float(channels)
        if interleaved {
            guard let base = buffers[0].mData?.assumingMemoryBound(to: Float.self) else { return }
            let frames = Int(buffers[0].mDataByteSize) / (MemoryLayout<Float>.size * channels)
            var done = 0
            while done < frames {
                let n = min(capacity, frames - done)
                for i in 0..<n {
                    var sum: Float = 0
                    let frame = base + (done + i) * channels
                    for c in 0..<channels { sum += frame[c] }
                    scratch[i] = sum * scale
                }
                ring.write(scratch, count: n)
                done += n
            }
        } else {
            let planes = min(buffers.count, channels)
            guard planes > 0, buffers[0].mData != nil else { return }
            let frames = Int(buffers[0].mDataByteSize) / MemoryLayout<Float>.size
            let planeScale = 1 / Float(planes)
            var done = 0
            while done < frames {
                let n = min(capacity, frames - done)
                for i in 0..<n { scratch[i] = 0 }
                for p in 0..<planes {
                    guard let data = buffers[p].mData?.assumingMemoryBound(to: Float.self) else { continue }
                    for i in 0..<n { scratch[i] += data[done + i] }
                }
                for i in 0..<n { scratch[i] *= planeScale }
                ring.write(scratch, count: n)
                done += n
            }
        }
    }

    // MARK: Analysis

    private func startAnalysis(sampleRate: Double, onBeat: @escaping (BeatEvent) -> Void, onLevel: ((Double) -> Void)?) {
        let detector = BeatDetector(sampleRate: sampleRate)
        let ring = self.ring
        let scratch = analysisScratch
        let capacity = Self.scratchFrames
        var processedSamples = 0
        var lastLevelUptime = 0.0
        let timer = DispatchSource.makeTimerSource(queue: analysisQueue)
        timer.schedule(deadline: .now() + .milliseconds(10), repeating: .milliseconds(10), leeway: .milliseconds(2))
        timer.setEventHandler {
            var beats: [BeatDetector.Beat] = []
            while ring.availableToRead > 0 {
                let n = ring.read(into: scratch, maxCount: capacity)
                beats += detector.process(UnsafeBufferPointer(start: scratch, count: n))
                processedSamples += n
            }
            let now = ProcessInfo.processInfo.systemUptime
            let streamSeconds = Double(processedSamples) / sampleRate
            for beat in beats {
                let event = BeatEvent(uptime: now - (streamSeconds - beat.time), strength: beat.strength, isStrong: beat.isStrong)
                DispatchQueue.main.async { onBeat(event) }
            }
            if let onLevel, now - lastLevelUptime >= 1.0 / 30.0 {
                lastLevelUptime = now
                let level = detector.level
                DispatchQueue.main.async { onLevel(level) }
            }
        }
        timer.resume()
        self.timer = timer
    }

    private func observe(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, onChange: @escaping () -> Void) {
        var address = CoreAudioProperty.address(selector)
        let block: AudioObjectPropertyListenerBlock = { _, _ in onChange() }
        let status = AudioObjectAddPropertyListenerBlock(object, &address, DispatchQueue.global(qos: .utility), block)
        if status == noErr {
            listeners.append((object, address, block))
        } else {
            Log.audio.error("Could not observe audio property \(fourCharacterCode(Int32(selector)), privacy: .public): \(status)")
        }
    }
}
