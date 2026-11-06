import AudioToolbox
import CoreAudio
import Foundation
import os

public enum AudioTapError: Error, LocalizedError {
    case status(String, OSStatus)

    public var errorDescription: String? {
        switch self {
        case .status(let step, let code): return "Audio tap: \(step) fallito (\(code))"
        }
    }
}

/// Listens to everything the Mac plays through a Core Audio process tap (macOS 14.2+)
/// and publishes smoothed bass/mid/treble levels. Only levels leave the audio queue.
public final class SystemAudioTap: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.livedesk.audio-tap", qos: .userInteractive)
    private let analyzer = SpectrumAnalyzer(size: 2048)
    private let latest = OSAllocatedUnfairLock(initialState: AudioBands.zero)
    private let log = Logger(subsystem: "dev.livedesk", category: "audio")

    // Accessed on `queue` only.
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var smoother = BandSmoother()
    private var buffer: [Float] = []
    private var sampleRate: Double = 48_000
    private var running = false
    private var outputListener: AudioObjectPropertyListenerBlock?

    public init() {}

    public var bands: AudioBands { latest.withLock { $0 } }

    public func start() {
        queue.async { [self] in
            guard !running else { return }
            do {
                try build()
                running = true
                installOutputListener()
                log.info("audio tap started")
            } catch {
                log.error("\(error.localizedDescription, privacy: .public)")
                teardown()
            }
        }
    }

    public func stop() {
        queue.async { [self] in
            removeOutputListener()
            teardown()
            running = false
            latest.withLock { $0 = .zero }
        }
    }

    // MARK: Setup (queue)

    private func build() throws {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .unmuted
        description.name = "LiveDesk"

        var tap = AudioObjectID(kAudioObjectUnknown)
        var err = AudioHardwareCreateProcessTap(description, &tap)
        guard err == noErr else { throw AudioTapError.status("CreateProcessTap", err) }
        tapID = tap

        let outputUID = try Self.defaultOutputUID()
        let config: [String: Any] = [
            kAudioAggregateDeviceNameKey: "LiveDesk Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        var aggregate = AudioObjectID(kAudioObjectUnknown)
        err = AudioHardwareCreateAggregateDevice(config as CFDictionary, &aggregate)
        guard err == noErr else { throw AudioTapError.status("CreateAggregateDevice", err) }
        aggregateID = aggregate

        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        err = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format)
        guard err == noErr else { throw AudioTapError.status("TapFormat", err) }
        if format.mSampleRate > 0 { sampleRate = format.mSampleRate }

        var proc: AudioDeviceIOProcID?
        err = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregateID, queue) { [weak self] _, input, _, _, _ in
            self?.consume(input)
        }
        guard err == noErr, let proc else { throw AudioTapError.status("CreateIOProc", err) }
        procID = proc
        err = AudioDeviceStart(aggregateID, proc)
        guard err == noErr else { throw AudioTapError.status("DeviceStart", err) }
    }

    private func teardown() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        buffer.removeAll(keepingCapacity: true)
    }

    private var outputAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
                                                           mScope: kAudioObjectPropertyScopeGlobal,
                                                           mElement: kAudioObjectPropertyElementMain)

    private func installOutputListener() {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, self.running else { return }
            self.log.info("output device changed; rebuilding tap")
            self.teardown()
            do { try self.build() } catch { self.running = false }
        }
        outputListener = block
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &outputAddress, queue, block)
    }

    private func removeOutputListener() {
        guard let block = outputListener else { return }
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &outputAddress, queue, block)
        outputListener = nil
    }

    // MARK: Processing (queue)

    private func consume(_ input: UnsafePointer<AudioBufferList>) {
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let first = list.first, first.mDataByteSize > 0 else { return }
        if list.count == 1 {
            let channels = Int(max(1, first.mNumberChannels))
            let frames = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * channels)
            guard let data = first.mData?.assumingMemoryBound(to: Float.self) else { return }
            for f in 0..<frames {
                var sum: Float = 0
                for c in 0..<channels { sum += data[f * channels + c] }
                buffer.append(sum / Float(channels))
            }
        } else {
            let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size
            var mono = [Float](repeating: 0, count: frames)
            var count: Float = 0
            for buf in list {
                guard let data = buf.mData?.assumingMemoryBound(to: Float.self) else { continue }
                for f in 0..<min(frames, Int(buf.mDataByteSize) / MemoryLayout<Float>.size) { mono[f] += data[f] }
                count += 1
            }
            if count > 0 { buffer.append(contentsOf: mono.map { $0 / count }) }
        }
        let size = analyzer.size
        let hop = size / 2
        while buffer.count >= size {
            let raw = analyzer.bands(Array(buffer[0..<size]), sampleRate: sampleRate)
            let value = smoother.process(raw)
            latest.withLock { $0 = value }
            buffer.removeFirst(hop)
        }
    }

    // MARK: Helpers

    static func defaultOutputUID() throws -> String {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var err = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        guard err == noErr else { throw AudioTapError.status("DefaultOutputDevice", err) }

        var uid: CFString = "" as CFString
        size = UInt32(MemoryLayout<CFString>.size)
        address.mSelector = kAudioDevicePropertyDeviceUID
        err = withUnsafeMutablePointer(to: &uid) { ptr in
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, ptr)
        }
        guard err == noErr else { throw AudioTapError.status("DeviceUID", err) }
        return uid as String
    }
}
