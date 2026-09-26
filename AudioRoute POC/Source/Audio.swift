import AppKit
import CoreAudio

struct AudioFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
func checked(_ status: OSStatus, _ action: String) throws {
    guard status == noErr else { throw AudioFailure(message: "\(action) (Core Audio \(status)).") }
}
enum HAL {
    static let system = AudioObjectID(kAudioObjectSystemObject)
    static func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
    static func value<T: BitwiseCopyable>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, _ initial: T, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> T {
        var property = address(selector, scope), result = initial
        var size = UInt32(MemoryLayout<T>.size)
        try checked(AudioObjectGetPropertyData(id, &property, 0, nil, &size, &result), "Could not read audio information")
        return result
    }
    static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var property = address(selector)
        var result: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &property, 0, nil, &size, &result) == noErr else { return nil }
        return result?.takeRetainedValue() as String?
    }
    static func ids(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
        var property = address(selector, scope), size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &property, 0, nil, &size) == noErr, size > 0 else { return [] }
        var result = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        let status = result.withUnsafeMutableBytes { AudioObjectGetPropertyData(id, &property, 0, nil, &size, $0.baseAddress!) }
        return status == noErr ? Array(result.prefix(Int(size) / 4)) : []
    }
    static func streams(_ device: AudioObjectID, _ scope: AudioObjectPropertyScope) -> [(AudioObjectID, AudioStreamBasicDescription)] {
        ids(device, kAudioDevicePropertyStreams, scope: scope).compactMap { stream in
            guard let format = try? value(stream, kAudioStreamPropertyVirtualFormat, AudioStreamBasicDescription()) else { return nil }
            return (stream, format)
        }
    }
    static func defaultOutput() -> AudioObjectID {
        (try? value(system, kAudioHardwarePropertyDefaultOutputDevice, AudioObjectID(0))) ?? 0
    }
}

struct OutputDevice: Identifiable, Equatable {
    let id: AudioObjectID
    let uid: String
    let name: String
    let channels: UInt32
    static func discover() -> [OutputDevice] {
        HAL.ids(HAL.system, kAudioHardwarePropertyDevices).compactMap { id in
            let channels = HAL.streams(id, kAudioObjectPropertyScopeOutput).reduce(UInt32(0)) { $0 + $1.1.mChannelsPerFrame }
            guard channels > 0, let uid = HAL.string(id, kAudioDevicePropertyDeviceUID), !uid.hasPrefix("local.audioroute.") else { return nil }
            let alive = (try? HAL.value(id, kAudioDevicePropertyDeviceIsAlive, UInt32(0))) ?? 0
            guard alive != 0 else { return nil }
            return OutputDevice(id: id, uid: uid, name: HAL.string(id, kAudioObjectPropertyName) ?? "Audio output", channels: channels)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
struct AudioSource: Identifiable {
    let id: String
    let name: String
    let icon: NSImage?
    var processes: [AudioObjectID]
    var active: Bool
    static func discover() -> [AudioSource] {
        let apps = NSWorkspace.shared.runningApplications
        var groups: [String: AudioSource] = [:]
        for object in HAL.ids(HAL.system, kAudioHardwarePropertyProcessObjectList) {
            guard let pid = try? HAL.value(object, kAudioProcessPropertyPID, pid_t(0)), pid != getpid(), pid > 0 else { continue }
            let bundleID = HAL.string(object, kAudioProcessPropertyBundleID) ?? ""
            let app = NSRunningApplication(processIdentifier: pid)
            // Prefer Core Audio's identity; for embedded Chromium/Electron helpers, recover the outer app.
            var owner = apps.first { !$0.isTerminated && $0.bundleIdentifier == bundleID && $0.activationPolicy == .regular }
            if owner == nil, let url = app?.bundleURL {
                let parts = url.path.components(separatedBy: "/")
                if let last = parts.firstIndex(where: { $0.hasSuffix(".app") }) {
                    let outer = parts.prefix(last + 1).joined(separator: "/")
                    owner = apps.first { $0.bundleURL?.path == outer }
                }
            }
            let identity = owner?.bundleIdentifier ?? (bundleID.isEmpty ? "pid:\(pid)" : bundleID)
            guard identity != Bundle.main.bundleIdentifier else { continue }
            let name = owner?.localizedName ?? app?.localizedName ?? HAL.string(object, kAudioObjectPropertyName) ?? (bundleID.isEmpty ? "Process \(pid)" : bundleID)
            let active = ((try? HAL.value(object, kAudioProcessPropertyIsRunningOutput, UInt32(0))) ?? 0) != 0
            if groups[identity] == nil {
                groups[identity] = AudioSource(id: identity, name: name, icon: owner?.icon ?? app?.icon, processes: [], active: false)
            }
            groups[identity]!.processes.append(object)
            groups[identity]!.active = groups[identity]!.active || active
        }
        return groups.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

// All Route operations run on one serial control queue. The callback only touches its C state.
final class Route {
    let createdAt = Date()
    var tap: AudioObjectID = 0
    var aggregate: AudioObjectID = 0
    var ioProc: AudioDeviceIOProcID?
    var render: OpaquePointer?
    let source: AudioSource
    let output: OutputDevice
    init(source: AudioSource, output: OutputDevice) throws {
        self.source = source
        self.output = output
        do { try start() } catch { stop(); throw error }
    }
    private func start() throws {
        guard output.channels >= 2 else { throw AudioFailure(message: "This prototype supports stereo outputs. Choose another device.") }
        let description = CATapDescription(stereoMixdownOfProcesses: source.processes)
        description.name = "AudioRoute · \(source.name)"
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped
        try checked(AudioHardwareCreateProcessTap(description, &tap), "Could not capture \(source.name)")
        guard let tapUID = HAL.string(tap, kAudioTapPropertyUID) else { throw AudioFailure(message: "Could not identify the audio tap.") }
        let composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "AudioRoute · \(source.name)",
            kAudioAggregateDeviceUIDKey: "local.audioroute.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceMainSubDeviceKey: output.uid,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: output.uid]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID, kAudioSubTapDriftCompensationKey: true]]
        ]
        try checked(AudioHardwareCreateAggregateDevice(composition as CFDictionary, &aggregate), "Could not prepare \(output.name)")
        for _ in 0..<30 {
            if (try? HAL.value(aggregate, kAudioDevicePropertyDeviceIsAlive, UInt32(0))) == 1,
               !HAL.streams(aggregate, kAudioObjectPropertyScopeInput).isEmpty { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        let inputs = HAL.streams(aggregate, kAudioObjectPropertyScopeInput)
        let outputs = HAL.streams(aggregate, kAudioObjectPropertyScopeOutput)
        let tapFormat = try HAL.value(tap, kAudioTapPropertyFormat, AudioStreamBasicDescription())
        guard tapFormat.mChannelsPerFrame == 2, !inputs.isEmpty, !outputs.isEmpty else { throw AudioFailure(message: "The audio device did not become ready.") }
        let inputChannels = inputs.reduce(UInt32(0)) { $0 + $1.1.mChannelsPerFrame }
        let outputChannels = outputs.reduce(UInt32(0)) { $0 + $1.1.mChannelsPerFrame }
        // Hardware input streams precede the appended tap. Disable them so no microphone is read.
        let hardwareInputs = HAL.streams(output.id, kAudioObjectPropertyScopeInput)
        let hardwareChannels = hardwareInputs.reduce(UInt32(0)) { $0 + $1.1.mChannelsPerFrame }
        guard inputChannels == hardwareChannels + 2,
              inputs.count > hardwareInputs.count else { throw AudioFailure(message: "This device has an unsupported input layout.") }
        let tapInputs = Array(inputs.dropFirst(hardwareInputs.count))
        let usedFormats = tapInputs.map(\.1) + outputs.map(\.1)
        guard usedFormats.allSatisfy({ $0.mFormatID == kAudioFormatLinearPCM && $0.mBitsPerChannel == 32 && ($0.mFormatFlags & kAudioFormatFlagIsFloat) != 0 && ($0.mFormatFlags & kAudioFormatFlagIsBigEndian) == 0 }) else {
            throw AudioFailure(message: "This prototype requires 32-bit floating-point audio streams.")
        }
        guard let rate = outputs.first?.1.mSampleRate, usedFormats.allSatisfy({ abs($0.mSampleRate - rate) < 1 }) else {
            throw AudioFailure(message: "These devices use different sample rates. Match their rates in Audio MIDI Setup, then try again.")
        }
        guard let state = ARCreateState(hardwareChannels, inputChannels, outputChannels) else { throw AudioFailure(message: "Could not allocate the audio buffer state.") }
        render = state
        try checked(AudioDeviceCreateIOProcID(aggregate, ARIOProc, UnsafeMutableRawPointer(state), &ioProc), "Could not create the audio route")
        guard let ioProc else { throw AudioFailure(message: "Could not create the playback callback.") }
        if !hardwareInputs.isEmpty {
            try checked(ARDisableHardwareInputs(aggregate, ioProc, UInt32(inputs.count), UInt32(hardwareInputs.count)), "Could not disable microphone inputs")
        }
        try checked(AudioDeviceStart(aggregate, ioProc), "Could not start routing; check System Audio Recording permission in System Settings")
    }
    func stop() {
        if let ioProc, aggregate != 0 {
            AudioDeviceStop(aggregate, ioProc)
            AudioDeviceDestroyIOProcID(aggregate, ioProc)
        }
        ioProc = nil
        if aggregate != 0 { AudioHardwareDestroyAggregateDevice(aggregate); aggregate = 0 }
        if tap != 0 { AudioHardwareDestroyProcessTap(tap); tap = 0 }
        if let render { ARDestroyState(render); self.render = nil }
    }
    deinit { stop() }
}
