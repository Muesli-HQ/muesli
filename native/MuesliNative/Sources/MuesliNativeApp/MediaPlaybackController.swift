import AppKit
import CoreAudio
import Foundation

protocol MediaPlaybackManaging: AnyObject {
    func beginDictationMediaPause(enabled: Bool, routeKind: AudioOutputRouteKind)
    func restoreDictationMediaPause()
}

protocol MediaPlaybackClient {
    func outputActivityStatus() -> AudioOutputActivityStatus
    func sendMediaPlayPauseToggle()
}

final class MediaPlaybackController: MediaPlaybackManaging {
    private let client: MediaPlaybackClient
    private let queue: DispatchQueue
    private var pausedForSession = false

    init(
        client: MediaPlaybackClient = SystemMediaPlaybackClient(),
        queue: DispatchQueue = DispatchQueue(label: "com.muesli.media-playback")
    ) {
        self.client = client
        self.queue = queue
    }

    func beginDictationMediaPause(enabled: Bool, routeKind: AudioOutputRouteKind) {
        queue.async { [self] in
            guard enabled else { return }
            guard !pausedForSession else { return }
            guard routeKind == .speakerLike else { return }
            guard client.outputActivityStatus() == .active else { return }
            client.sendMediaPlayPauseToggle()
            pausedForSession = true
        }
    }

    func restoreDictationMediaPause() {
        queue.async { [self] in
            guard pausedForSession else { return }
            pausedForSession = false
            // macOS exposes a reliable public media key toggle, not a global
            // "resume only what I paused" API. Resume only when output still
            // does not look active so we do not pause user-started playback.
            // If activity is unknown, prefer restoring media we know Muesli
            // paused over leaving playback stranded.
            guard client.outputActivityStatus() != .active else { return }
            client.sendMediaPlayPauseToggle()
        }
    }

    func waitForIdle() {
        queue.sync {}
    }
}

final class SystemMediaPlaybackClient: MediaPlaybackClient {
    private let currentProcessID = ProcessInfo.processInfo.processIdentifier

    func outputActivityStatus() -> AudioOutputActivityStatus {
        guard let processIDs = processObjectIDs() else { return .unknown }
        for processObjectID in processIDs {
            guard boolProperty(kAudioProcessPropertyIsRunningOutput, objectID: processObjectID),
                  let pid = pidProperty(objectID: processObjectID),
                  pid > 0,
                  pid != currentProcessID else { continue }
            return .active
        }
        return .inactive
    }

    func sendMediaPlayPauseToggle() {
        postAuxKey(keyCode: 16)
    }

    private func postAuxKey(keyCode: Int) {
        postAuxKeyEvent(keyCode: keyCode, keyState: 0xA)
        postAuxKeyEvent(keyCode: keyCode, keyState: 0xB)
    }

    private func postAuxKeyEvent(keyCode: Int, keyState: Int) {
        let data1 = (keyCode << 16) | (keyState << 8)
        guard let event = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(keyState << 8)),
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: 8,
            data1: data1,
            data2: -1
        )?.cgEvent else { return }
        event.post(tap: .cghidEventTap)
    }

    private func processObjectIDs() -> [AudioObjectID]? {
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
        ) == noErr else {
            return nil
        }
        guard dataSize > 0 else { return [] }

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
            return nil
        }
        return ids.filter { $0 != AudioObjectID(kAudioObjectUnknown) }
    }

    private func pidProperty(objectID: AudioObjectID) -> pid_t? {
        var pid = pid_t(0)
        guard getPid(kAudioProcessPropertyPID, objectID: objectID, value: &pid) else {
            return nil
        }
        return pid
    }

    private func boolProperty(_ selector: AudioObjectPropertySelector, objectID: AudioObjectID) -> Bool {
        var value: UInt32 = 0
        guard getUInt32(
            selector,
            objectID: objectID,
            scope: kAudioObjectPropertyScopeGlobal,
            element: kAudioObjectPropertyElementMain,
            value: &value
        ) else {
            return false
        }
        return value != 0
    }

    private func getPid(
        _ selector: AudioObjectPropertySelector,
        objectID: AudioObjectID,
        value: inout pid_t
    ) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize = UInt32(MemoryLayout<pid_t>.size)
        return AudioObjectGetPropertyData(objectID, &address, 0, nil, &dataSize, &value) == noErr
    }

    private func getUInt32(
        _ selector: AudioObjectPropertySelector,
        objectID: AudioObjectID,
        scope: AudioObjectPropertyScope,
        element: AudioObjectPropertyElement,
        value: inout UInt32
    ) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: element
        )
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(objectID, &address, 0, nil, &dataSize, &value) == noErr
    }
}
