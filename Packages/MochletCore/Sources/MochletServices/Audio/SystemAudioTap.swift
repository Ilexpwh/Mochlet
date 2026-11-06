import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation

/// Everything the Mac plays (the other people of a call, whatever the app), through a Core Audio
/// process tap. macOS asks once for the "System Audio Recording" permission. Nothing is muted: you keep
/// hearing the call. The tap is rebuilt when the default output device changes (AirPods arriving).
/// Core Audio process tap that captures system output for the meeting pipeline.
public final class SystemAudioTap: @unchecked Sendable {
    public enum TapError: LocalizedError {
        case failed(String, OSStatus)
        public var errorDescription: String? {
            switch self {
            case .failed(let step, let status): return "System audio: \(step) failed (\(status))"
            }
        }
    }

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var tapList: UnsafeMutableAudioBufferListPointer?
    private let queue = DispatchQueue(label: "com.ilexpwh.Mochlet.meeting.system", qos: .userInitiated)
    private var sink: (@Sendable ([Float]) -> Void)?
    private var listenerInstalled = false
    private var outputListener: AudioObjectPropertyListenerBlock?

    public init() {}

    public func start(sink: @escaping @Sendable ([Float]) -> Void) throws {
        self.sink = sink
        try build()
        installOutputListener()
    }

    private func build() throws {
        guard let sink else { return }
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.name = "Mochlet meeting notes"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var tap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr else { throw TapError.failed("process tap", status) }
        tapID = tap

        var formatAddress = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        status = AudioObjectGetPropertyData(tap, &formatAddress, 0, nil, &size, &asbd)
        guard status == noErr, let format = AVAudioFormat(streamDescription: &asbd), let resampler = Resampler16k(from: format) else {
            teardown()
            throw TapError.failed("tap format", status)
        }

        let outputUID = try Self.defaultOutputUID()
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Mochlet meeting notes",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        var device = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device)
        guard status == noErr else {
            teardown()
            throw TapError.failed("aggregate device", status)
        }
        aggregateID = device

        // The aggregate's input is the output device's own inputs (a headset's microphone), if any,
        // then the tap: the tap's buffers are the last ones.
        let tapBuffers = format.isInterleaved ? 1 : Int(format.channelCount)
        let scratch = AudioBufferList.allocate(maximumBuffers: tapBuffers)
        tapList = scratch
        var proc: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&proc, device, queue) { _, input, _, _, _ in
            let all = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            var list = input
            if all.count > tapBuffers {
                for i in 0..<tapBuffers { scratch[i] = all[all.count - tapBuffers + i] }
                list = UnsafePointer(scratch.unsafePointer)
            }
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: list, deallocator: nil) else { return }
            sink(resampler.convert(buffer))
        }
        guard status == noErr, let proc else {
            teardown()
            throw TapError.failed("io proc", status)
        }
        procID = proc
        status = AudioDeviceStart(device, proc)
        guard status == noErr else {
            teardown()
            throw TapError.failed("start", status)
        }
    }

    private func installOutputListener() {
        guard !listenerInstalled else { return }
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            self.queue.asyncAfter(deadline: .now() + 0.5) {
                self.teardown()
                try? self.build()
            }
        }
        outputListener = block
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, block) == noErr { listenerInstalled = true }
    }

    /// `start` on a background thread: creating the tap can wait on the System Audio Recording prompt,
    /// and the app must stay responsive while the person reads it.
    public func start(offMain sink: @escaping @Sendable ([Float]) -> Void) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do { try self.start(sink: sink); c.resume() } catch { c.resume(throwing: error) }
            }
        }
    }

    public func stop() {
        if listenerInstalled, let block = outputListener {
            var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, block)
            listenerInstalled = false
        }
        sink = nil
        teardown()
    }

    private func teardown() {
        if aggregateID != AudioObjectID(kAudioObjectUnknown) {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != AudioObjectID(kAudioObjectUnknown) { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        if let tapList { free(tapList.unsafeMutablePointer) }
        tapList = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    private static func defaultOutputUID() throws -> String {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        guard status == noErr, device != AudioObjectID(kAudioObjectUnknown) else { throw TapError.failed("output device", status) }
        address.mSelector = kAudioDevicePropertyDeviceUID
        var uid: CFString = "" as CFString
        size = UInt32(MemoryLayout<CFString>.stride)
        status = withUnsafeMutablePointer(to: &uid) { AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0) }
        guard status == noErr else { throw TapError.failed("output device uid", status) }
        return uid as String
    }
}

// MARK: - Who holds the microphone

/// Which processes record from the microphone right now, from Core Audio's process list (no
/// Accessibility or screen permission needed).
public enum MicUsageMonitor {
    public struct Process: Sendable, Equatable {
        public var pid: pid_t
        public var bundleID: String
    }

    public static func processesUsingInput() -> [Process] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        var out: [Process] = []
        for id in ids {
            var a = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningInput, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var running: UInt32 = 0
            var s = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(id, &a, 0, nil, &s, &running) == noErr, running != 0 else { continue }
            a.mSelector = kAudioProcessPropertyPID
            var pid: pid_t = 0
            s = UInt32(MemoryLayout<pid_t>.size)
            _ = AudioObjectGetPropertyData(id, &a, 0, nil, &s, &pid)
            a.mSelector = kAudioProcessPropertyBundleID
            var bundle: CFString = "" as CFString
            s = UInt32(MemoryLayout<CFString>.stride)
            let ok = withUnsafeMutablePointer(to: &bundle) { AudioObjectGetPropertyData(id, &a, 0, nil, &s, $0) } == noErr
            out.append(Process(pid: pid, bundleID: ok ? (bundle as String) : ""))
        }
        return out
    }
}
