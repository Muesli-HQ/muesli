import CoreAudio
import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("Dictation capture health events")
struct DictationCaptureHealthTests {
    @Test("selected device loss fails once; old notifications cannot fail a replacement session")
    func deviceLossAndReplacement() {
        let driver = HealthHALDriver()
        let observer = driver.observer()
        var failures: [DictationMicrophoneStartupError] = []
        let first = UUID(), second = UUID()
        observer.start(sessionID: first, preferredInputDeviceID: 42) { failures.append($0) }
        driver.flush()
        let stale = driver.queue.sync { driver.listeners.last!.block }
        driver.notify(42, kAudioDevicePropertyDeviceIsAlive, value: 0)
        driver.notify(42, kAudioDevicePropertyIOStoppedAbnormally)
        #expect(failures == [.deviceUnavailable])
        observer.start(sessionID: second, preferredInputDeviceID: 43) { failures.append($0) }
        driver.flush()
        driver.queue.sync {
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyIOStoppedAbnormally, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            stale(1, &address)
        }
        #expect(failures == [.deviceUnavailable])
        observer.stop(sessionID: first) // Must not remove the replacement listeners.
        driver.flush()
        driver.notify(43, kAudioDevicePropertyIOStoppedAbnormally)
        #expect(failures == [.deviceUnavailable, .ioStoppedAbnormally])
        observer.stop(sessionID: second)
        driver.flush()
        #expect(driver.queue.sync { driver.listeners.isEmpty })
    }

    @Test("default input changes rebind; unsupported state and listener registration are not failures")
    func defaultRouteAndUnknownState() {
        let driver = HealthHALDriver()
        let observer = driver.observer()
        var failures: [DictationMicrophoneStartupError] = []
        let id = UUID()
        observer.start(sessionID: id, preferredInputDeviceID: nil) { failures.append($0) }
        driver.flush()
        driver.notify(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice, value: 43)
        #expect(failures.isEmpty)
        #expect(driver.queue.sync { !driver.listeners.contains { $0.device == 42 } })
        driver.notify(43, kAudioDevicePropertyDeviceIsAlive, value: nil)
        #expect(failures.isEmpty)
        driver.notify(43, kAudioDevicePropertyDeviceIsAlive, value: 0)
        #expect(failures == [.deviceUnavailable])
        observer.stop(sessionID: id)
        driver.flush()
        driver.queue.sync { driver.registrationAllowed = false }
        let next = UUID()
        observer.start(sessionID: next, preferredInputDeviceID: 44) { failures.append($0) }
        driver.flush()
        #expect(failures.count == 1)
        observer.stop(sessionID: next)
        driver.flush()
    }

    @Test("old default device loss rebinds even if the default-change notification arrives later")
    func reorderedRouteNotifications() {
        let driver = HealthHALDriver()
        let observer = driver.observer()
        let id = UUID()
        var failures = 0
        observer.start(sessionID: id, preferredInputDeviceID: nil) { _ in failures += 1 }
        driver.flush()
        driver.queue.sync {
            driver.setValue(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice, 43)
        }
        driver.notify(42, kAudioDevicePropertyDeviceIsAlive, value: 0)
        #expect(failures == 0)
        #expect(driver.queue.sync { driver.listeners.contains { $0.device == 43 } })
        observer.stop(sessionID: id)
        driver.flush()
    }

    @Test("cancellation removes listeners and ignores notifications already queued by HAL")
    func cancellation() {
        let driver = HealthHALDriver()
        let observer = driver.observer()
        let id = UUID()
        var failures = 0
        observer.start(sessionID: id, preferredInputDeviceID: 42) { _ in failures += 1 }
        driver.flush()
        let stale = driver.queue.sync { driver.listeners.last!.block }
        observer.stop(sessionID: id)
        driver.flush()
        driver.queue.sync {
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyIOStoppedAbnormally, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            stale(1, &address)
        }
        #expect(failures == 0)
    }
}

private final class HealthHALDriver: @unchecked Sendable {
    struct Listener {
        let device: AudioObjectID
        let selector: AudioObjectPropertySelector
        let block: AudioObjectPropertyListenerBlock
    }
    let queue = DispatchQueue(label: "test.dictation.health.hal")
    var listeners: [Listener] = []
    var values: [UInt64: UInt32] = [:]
    var registrationAllowed = true
    init() {
        values[key(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice)] = 42
        values[key(42, kAudioDevicePropertyDeviceIsAlive)] = 1
        values[key(43, kAudioDevicePropertyDeviceIsAlive)] = 1
    }
    private func key(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt64 {
        UInt64(device) << 32 | UInt64(selector)
    }
    func observer() -> CoreAudioDictationInputObserver {
        var native = CoreAudioDictationInputObserver.NativeOperations()
        native.read = { [self] device, selector in values[key(device, selector)] }
        native.add = { [self] device, selector, _, block in
            guard registrationAllowed else { return false }
            listeners.append(.init(device: device, selector: selector, block: block))
            return true
        }
        native.remove = { [self] device, selector, _, _ in
            listeners.removeAll { $0.device == device && $0.selector == selector }
        }
        return CoreAudioDictationInputObserver(queue: queue, native: native)
    }
    func setValue(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: UInt32) { values[key(device, selector)] = value }
    func flush() { queue.sync {} }
    func notify(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector, value: UInt32? = nil) {
        queue.sync {
            values[key(device, selector)] = value
            for listener in listeners.filter({ $0.device == device && $0.selector == selector }) {
                var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
                listener.block(1, &address)
            }
        }
    }
}
