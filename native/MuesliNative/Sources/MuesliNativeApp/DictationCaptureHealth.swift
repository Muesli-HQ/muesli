import CoreAudio
import Foundation

protocol DictationInputObserving: AnyObject {
    func start(sessionID: UUID, preferredInputDeviceID: AudioObjectID?,
               onFailure: @escaping (DictationMicrophoneStartupError) -> Void)
    func stop(sessionID: UUID)
}

/// HAL runs only on this worker, never on the capture or UI queue. Device
/// availability is evidence of failure; running-somewhere and silence are not.
final class CoreAudioDictationInputObserver: DictationInputObserving, @unchecked Sendable {
    struct NativeOperations {
        var read: (AudioObjectID, AudioObjectPropertySelector) -> UInt32? = { device, selector in
            var address = Self.address(selector)
            var value: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
            if selector == kAudioDevicePropertyDeviceIsAlive, status == kAudioHardwareBadDeviceError { return 0 }
            return status == noErr ? value : nil
        }
        var add: (AudioObjectID, AudioObjectPropertySelector, DispatchQueue, @escaping AudioObjectPropertyListenerBlock) -> Bool = {
            device, selector, queue, block in
            var address = Self.address(selector)
            guard AudioObjectHasProperty(device, &address) else { return false }
            return AudioObjectAddPropertyListenerBlock(device, &address, queue, block) == noErr
        }
        var remove: (AudioObjectID, AudioObjectPropertySelector, DispatchQueue, @escaping AudioObjectPropertyListenerBlock) -> Void = {
            device, selector, queue, block in
            var address = Self.address(selector)
            AudioObjectRemovePropertyListenerBlock(device, &address, queue, block)
        }
        private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
            .init(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        }
    }

    private struct Listener {
        let device: AudioObjectID
        let selector: AudioObjectPropertySelector
        let block: AudioObjectPropertyListenerBlock
    }
    private let queue: DispatchQueue
    private let native: NativeOperations
    private var sessionID: UUID?
    private var followsDefault = false
    private var bindingID = UUID()
    private var deviceID: AudioObjectID = 0
    private var listeners: [Listener] = []
    private var failure: ((DictationMicrophoneStartupError) -> Void)?

    init(queue: DispatchQueue = DispatchQueue(label: "com.muesli.dictation-input-health"),
         native: NativeOperations = NativeOperations()) {
        self.queue = queue
        self.native = native
    }

    deinit {
        let registrations = listeners, native = native, queue = queue
        queue.async {
            for listener in registrations { native.remove(listener.device, listener.selector, queue, listener.block) }
        }
    }

    func start(sessionID: UUID, preferredInputDeviceID: AudioObjectID?,
               onFailure: @escaping (DictationMicrophoneStartupError) -> Void) {
        queue.async { [self] in
            removeListeners()
            self.sessionID = sessionID
            failure = onFailure
            followsDefault = preferredInputDeviceID == nil
            if let preferredInputDeviceID {
                bindDevice(preferredInputDeviceID, session: sessionID)
            } else {
                listen(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice) { [weak self] in
                    self?.followDefault(session: sessionID)
                }
                followDefault(session: sessionID)
            }
        }
    }

    func stop(sessionID: UUID) {
        queue.async { [self] in
            guard self.sessionID == sessionID else { return }
            self.sessionID = nil
            failure = nil
            removeListeners()
        }
    }

    private func followDefault(session: UUID) {
        guard sessionID == session,
              let device = native.read(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice) else { return }
        // Default-route changes are transitions, not failures. Rebind to the
        // new input and let our queue report whether its capture actually stops.
        bindDevice(device, session: session)
    }

    private func bindDevice(_ device: AudioObjectID, session: UUID) {
        let old = listeners.filter { $0.device != AudioObjectID(kAudioObjectSystemObject) }
        listeners.removeAll { $0.device != AudioObjectID(kAudioObjectSystemObject) }
        for listener in old { native.remove(listener.device, listener.selector, queue, listener.block) }
        bindingID = UUID()
        let binding = bindingID
        deviceID = device
        guard device != kAudioObjectUnknown else {
            if !followsDefault { fail(.deviceUnavailable) }
            return // A default-route transition may temporarily have no input.
        }
        listen(device, kAudioDevicePropertyDeviceIsAlive) { [weak self] in
            guard let self, self.sessionID == session, self.bindingID == binding, self.deviceID == device else { return }
            self.checkAlive(device)
        }
        listen(device, kAudioDevicePropertyIOStoppedAbnormally) { [weak self] in
            guard let self, self.sessionID == session, self.bindingID == binding, self.deviceID == device else { return }
            if !self.refreshChangedDefault() { self.fail(.ioStoppedAbnormally) }
        }
        checkAlive(device)
    }

    private func refreshChangedDefault() -> Bool {
        guard followsDefault,
              let current = native.read(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice),
              current != deviceID else { return false }
        guard let sessionID else { return false }
        bindDevice(current, session: sessionID)
        return true
    }

    private func checkAlive(_ device: AudioObjectID) {
        if refreshChangedDefault() { return }
        if native.read(device, kAudioDevicePropertyDeviceIsAlive) == 0 { fail(.deviceUnavailable) }
    }

    private func fail(_ error: DictationMicrophoneStartupError) {
        let callback = failure
        failure = nil // One failure per observed attempt.
        callback?(error)
    }

    private func listen(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector, changed: @escaping () -> Void) {
        let session = sessionID
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, self.sessionID == session else { return }
            changed()
        }
        if native.add(device, selector, queue, block) {
            listeners.append(.init(device: device, selector: selector, block: block))
        }
    }

    private func removeListeners() {
        for listener in listeners { native.remove(listener.device, listener.selector, queue, listener.block) }
        listeners.removeAll()
        deviceID = 0
    }
}
