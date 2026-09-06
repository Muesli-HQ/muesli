import CoreAudio
import Foundation

struct MicrophoneActivitySnapshot: Equatable {
    var deviceID: AudioDeviceID = 0
    var isActive: Bool? = nil
    var isMuted: Bool? = nil
}

@MainActor
final class MicrophoneActivityMonitor {
    private(set) var snapshot = MicrophoneActivitySnapshot()
    var deviceID: AudioDeviceID { snapshot.deviceID }
    var onActivityChanged: (() -> Void)?
    private let queue: DispatchQueue
    private let observer: MicrophoneActivityObserving
    private var generation = 0
    private var started = false

    init(queue: DispatchQueue = DispatchQueue(label: "com.muesli.meeting-mic-activity"),
         observer: MicrophoneActivityObserving? = nil) {
        self.queue = queue
        self.observer = observer ?? CoreAudioMicrophoneActivityObserver(queue: queue)
    }

    func start() {
        guard !started else { return }
        started = true
        generation += 1
        let token = generation
        queue.async { [observer, weak self] in
            observer.onActivityChanged = { [weak self] snapshot in
                Task { @MainActor [weak self] in
                    guard let self, self.started, self.generation == token else { return }
                    self.snapshot = snapshot
                    self.onActivityChanged?()
                }
            }
            observer.start()
        }
    }

    func stop() {
        guard started else { return }
        started = false
        generation += 1
        snapshot = MicrophoneActivitySnapshot()
        queue.async { [observer] in observer.stop() }
    }
}

protocol MicrophoneActivityObserving: AnyObject, Sendable {
    var onActivityChanged: ((MicrophoneActivitySnapshot) -> Void)? { get set }
    func start()
    func stop()
}

/// HAL listener registration, device reads and removal share one worker queue.
/// The owning monitor only posts events to MainActor and never waits for HAL.
final class CoreAudioMicrophoneActivityObserver: MicrophoneActivityObserving, @unchecked Sendable {
    var onActivityChanged: ((MicrophoneActivitySnapshot) -> Void)?
    private let queue: DispatchQueue
    private var isStarted = false
    private var micListenerDeviceID: AudioDeviceID = 0
    private var micListenerBlock: AudioObjectPropertyListenerBlock?
    private var muteListenerBlock: AudioObjectPropertyListenerBlock?
    private let observesMute: Bool
    private var preferredInputDeviceID: AudioDeviceID?
    private var deviceChangeListenerBlock: AudioObjectPropertyListenerBlock?

    init(queue: DispatchQueue, observesMute: Bool = false) {
        self.queue = queue
        self.observesMute = observesMute
    }

    // Called on the observer queue, like start/stop and HAL notifications.
    func selectInput(_ deviceID: AudioDeviceID?) {
        preferredInputDeviceID = deviceID
        guard isStarted else { return }
        removeMicListener()
        installMicListener()
        publishActivity()
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        installDeviceChangeListener()
        installMicListener()
        publishActivity()
    }

    func stop() {
        isStarted = false
        onActivityChanged = nil
        removeMicListener()
        removeDeviceChangeListener()
    }

    private func installMicListener() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)

        if let preferredInputDeviceID {
            deviceID = preferredInputDeviceID
        } else {
            guard AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &size,
                &deviceID
            ) == noErr, deviceID != 0 else { return }

        }
        micListenerDeviceID = deviceID

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, self.isStarted else { return }
            self.publishActivity()
        }
        micListenerBlock = block

        var runningAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(deviceID, &runningAddress, queue, block)
        if observesMute {
            let muteBlock: AudioObjectPropertyListenerBlock = { [weak self] count, addresses in
                guard let self, self.isStarted else { return }
                let relevant = (0..<Int(count)).contains {
                    [kAudioDevicePropertyMute, kAudioDevicePropertyVolumeScalar,
                     kAudioDevicePropertyStreamConfiguration].contains(addresses[$0].mSelector)
                }
                if relevant { self.publishActivity() }
            }
            muteListenerBlock = muteBlock
            var address = Self.inputControlAddress
            AudioObjectAddPropertyListenerBlock(deviceID, &address, queue, muteBlock)
        }
    }

    private func publishActivity() {
        guard isStarted else { return }
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = micListenerDeviceID == 0 ? kAudioHardwareBadDeviceError : AudioObjectGetPropertyData(
            micListenerDeviceID, &address, 0, nil, &size, &running
        )
        onActivityChanged?(MicrophoneActivitySnapshot(
            deviceID: micListenerDeviceID,
            isActive: status == noErr ? running != 0 : nil,
            isMuted: observesMute ? readInputMuted(deviceID: micListenerDeviceID) : nil
        ))
    }

    private func removeMicListener() {
        guard micListenerDeviceID != 0, let block = micListenerBlock else { return }
        var runningAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(micListenerDeviceID, &runningAddress, queue, block)
        if let muteListenerBlock {
            var address = Self.inputControlAddress
            AudioObjectRemovePropertyListenerBlock(micListenerDeviceID, &address, queue, muteListenerBlock)
            self.muteListenerBlock = nil
        }
        micListenerDeviceID = 0
        micListenerBlock = nil
    }

    private func installDeviceChangeListener() {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.queue.async { [weak self] in
                guard let self, self.isStarted else { return }
                self.removeMicListener()
                self.installMicListener()
                self.publishActivity()
            }
        }
        deviceChangeListenerBlock = block

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            queue,
            block
        )
    }

    private func removeDeviceChangeListener() {
        guard let block = deviceChangeListenerBlock else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            queue,
            block
        )
        deviceChangeListenerBlock = nil
    }
    private static var inputControlAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioObjectPropertySelectorWildcard,
            mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementWildcard)
    }

    private func readInputMuted(deviceID: AudioDeviceID) -> Bool? {
        guard deviceID != 0 else { return nil }
        // Volume and mute controls may live on the main element (0) or on any
        // input channel. Enumerate the device's actual input channel count via
        // the stream configuration and probe every channel; a read failure
        // just means "no control there".
        var elements: [AudioObjectPropertyElement] = [kAudioObjectPropertyElementMain]
        var configAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var configSize: UInt32 = 0
        if AudioObjectGetPropertyDataSize(deviceID, &configAddress, 0, nil, &configSize) == noErr, configSize > 0 {
            let raw = UnsafeMutableRawPointer.allocate(
                byteCount: Int(configSize),
                alignment: MemoryLayout<AudioBufferList>.alignment
            )
            defer { raw.deallocate() }
            if AudioObjectGetPropertyData(deviceID, &configAddress, 0, nil, &configSize, raw) == noErr {
                let bufferList = raw.assumingMemoryBound(to: AudioBufferList.self)
                let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
                let channelCount = buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
                if channelCount > 0 {
                    elements.append(contentsOf: (1...channelCount).map { AudioObjectPropertyElement($0) })
                }
            }
        }
        for element in elements {
            var volumeAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioObjectPropertyScopeInput,
                mElement: element
            )
            var volume: Float32 = 1
            var volumeSize = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(deviceID, &volumeAddress, 0, nil, &volumeSize, &volume) == noErr,
               volume <= 0.0001 {
                return true
            }
            var muteAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: kAudioObjectPropertyScopeInput,
                mElement: element
            )
            var muted: UInt32 = 0
            var muteSize = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(deviceID, &muteAddress, 0, nil, &muteSize, &muted) == noErr,
               muted != 0 {
                return true
            }
        }
        return false
    }

}
