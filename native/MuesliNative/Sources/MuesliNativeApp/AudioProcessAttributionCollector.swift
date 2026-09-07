import AppKit
import CoreAudio
import Foundation

struct AudioProcessActivity: Equatable {
    let audioObjectID: AudioObjectID?
    let pid: pid_t
    let bundleID: String
    let appName: String
    let isRunningInput: Bool
    let isRunningOutput: Bool
    let deviceIDs: [AudioObjectID]

    init(
        audioObjectID: AudioObjectID? = nil,
        pid: pid_t,
        bundleID: String,
        appName: String,
        isRunningInput: Bool,
        isRunningOutput: Bool,
        deviceIDs: [AudioObjectID] = []
    ) {
        self.audioObjectID = audioObjectID
        self.pid = pid
        self.bundleID = bundleID
        self.appName = appName
        self.isRunningInput = isRunningInput
        self.isRunningOutput = isRunningOutput
        self.deviceIDs = deviceIDs
    }
}

final class AudioProcessAttributionCollector {
    func activeInputProcesses() -> [AudioProcessActivity] {
        processObjectIDs().compactMap { processID in
            guard boolProperty(kAudioProcessPropertyIsRunningInput, objectID: processID) else {
                return nil
            }
            guard let pid = pidProperty(objectID: processID),
                  pid > 0 else { return nil }

            let bundleID = stringProperty(kAudioProcessPropertyBundleID, objectID: processID)
                ?? NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
                ?? "pid:\(pid)"
            let appName = NSRunningApplication(processIdentifier: pid)?.localizedName
                ?? MeetingCandidateResolver.browserApps[bundleID]
                ?? MeetingCandidateResolver.dedicatedApps[bundleID]?.name
                ?? bundleID

            return AudioProcessActivity(
                audioObjectID: processID,
                pid: pid,
                bundleID: bundleID,
                appName: appName,
                isRunningInput: true,
                isRunningOutput: boolProperty(kAudioProcessPropertyIsRunningOutput, objectID: processID),
                deviceIDs: deviceIDsForInput(processID)
            )
        }
    }

    /// Rechecks only process objects retained by a previous full attribution
    /// pass. This avoids enumerating every CoreAudio process merely to observe
    /// an input/output transition on an already identified client.
    func refreshTrackedProcesses(_ processes: [AudioProcessActivity]) -> [AudioProcessActivity] {
        processes.compactMap { process in
            guard let objectID = process.audioObjectID,
                  pidProperty(objectID: objectID) == process.pid else {
                return nil
            }
            return AudioProcessActivity(
                audioObjectID: objectID,
                pid: process.pid,
                bundleID: process.bundleID,
                appName: process.appName,
                isRunningInput: boolProperty(kAudioProcessPropertyIsRunningInput, objectID: objectID),
                isRunningOutput: boolProperty(kAudioProcessPropertyIsRunningOutput, objectID: objectID),
                deviceIDs: process.deviceIDs
            )
        }
    }

    private func processObjectIDs() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize
        ) == noErr, dataSize > 0 else {
            return []
        }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: AudioObjectID(kAudioObjectUnknown), count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &ids
        ) == noErr else {
            return []
        }
        return ids.filter { $0 != AudioObjectID(kAudioObjectUnknown) }
    }

    private func pidProperty(objectID: AudioObjectID) -> pid_t? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid = pid_t(0)
        var dataSize = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(
            objectID,
            &address,
            0,
            nil,
            &dataSize,
            &pid
        ) == noErr else {
            return nil
        }
        return pid
    }

    private func stringProperty(_ selector: AudioObjectPropertySelector, objectID: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString?
        var dataSize = UInt32(MemoryLayout<CFString?>.size)
        guard AudioObjectGetPropertyData(
            objectID,
            &address,
            0,
            nil,
            &dataSize,
            &value
        ) == noErr else {
            return nil
        }
        return value as String?
    }

    private func boolProperty(_ selector: AudioObjectPropertySelector, objectID: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(
            objectID,
            &address,
            0,
            nil,
            &dataSize,
            &value
        ) == noErr else {
            return false
        }
        return value != 0
    }

    private func deviceIDsForInput(_ objectID: AudioObjectID) -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyDevices,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &dataSize) == noErr,
              dataSize > 0 else {
            return []
        }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: AudioObjectID(kAudioObjectUnknown), count: count)
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &dataSize, &ids) == noErr else {
            return []
        }
        return ids.filter { $0 != AudioObjectID(kAudioObjectUnknown) }
    }
}
