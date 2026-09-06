import CoreMediaIO
import Foundation

/// CMIO listener block type — different from CoreAudio's AudioObjectPropertyListenerBlock.
private typealias CMIOListenerBlock = @convention(block) (UInt32, UnsafePointer<CMIOObjectPropertyAddress>?) -> Void

/// Main-actor state is a cache: discovery and driver listener operations must
/// never hold the UI behind a media-driver route transition.
@MainActor
final class CameraActivityMonitor {
    var onCameraStateChanged: ((Bool) -> Void)?
    private(set) var isCameraActive = false
    private var generation = 0
    private var isStarted = false
    private let queue: DispatchQueue
    private let observer: CameraActivityObserving

    init(
        observer: CameraActivityObserving? = nil,
        queue: DispatchQueue = DispatchQueue(label: "com.muesli.camera-activity")
    ) {
        self.queue = queue
        self.observer = observer ?? CoreMediaIOCameraActivityObserver(queue: queue)
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        generation += 1
        let expectedGeneration = generation
        queue.async { [observer, weak self] in
            observer.onCameraStateChanged = { [weak self] active in
                Task { @MainActor [weak self] in
                    guard let self, self.isStarted,
                          self.generation == expectedGeneration else { return }
                    guard self.isCameraActive != active else { return }
                    self.isCameraActive = active
                    self.onCameraStateChanged?(active)
                }
            }
            observer.start()
        }
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        generation += 1
        isCameraActive = false
        queue.async { [observer] in
            observer.onCameraStateChanged = nil
            observer.stop()
        }
    }

    func refresh() {
        guard isStarted else { return }
        queue.async { [observer] in observer.refresh() }
    }
}

/// All methods and callbacks belong to the monitor's serial worker queue.
protocol CameraActivityObserving: AnyObject, Sendable {
    var onCameraStateChanged: ((Bool) -> Void)? { get set }
    func start()
    func stop()
    func refresh()
}

/// Event-driven camera observation without creating AVCaptureHALDevice objects.
/// AVFoundation's device discovery installs its own main-queue HAL listeners;
/// a captured AirPods stall blocked that queue in _removePropertyListeners.
// Mutable state is confined to the serial queue supplied by the facade.
private final class CoreMediaIOCameraActivityObserver: CameraActivityObserving, @unchecked Sendable {
    var onCameraStateChanged: ((Bool) -> Void)?

    private var monitoredDevices: [CMIOObjectID: CMIOListenerBlock] = [:]
    private var deviceListListenerBlock: CMIOListenerBlock?
    private var isCameraActive = false
    private var isStarted = false
    private let queue: DispatchQueue

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        installDeviceListListener()
        refreshDeviceListeners()
    }

    func stop() {
        isStarted = false
        isCameraActive = false
        removeAllDeviceListeners()
        removeDeviceListListener()
    }

    func refresh() {
        checkCameraState()
    }

    // MARK: - Device List Listener

    /// Listens for camera hardware being added/removed (e.g. plugging in a USB webcam).
    private func installDeviceListListener() {
        let block: CMIOListenerBlock = { [weak self] _, _ in
            self?.queue.async { [weak self] in self?.refreshDeviceListeners() }
        }
        deviceListListenerBlock = block

        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        CMIOObjectAddPropertyListenerBlock(
            CMIOObjectID(kCMIOObjectSystemObject), &address, nil, block
        )
    }

    private func removeDeviceListListener() {
        guard let block = deviceListListenerBlock else { return }
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        CMIOObjectRemovePropertyListenerBlock(
            CMIOObjectID(kCMIOObjectSystemObject), &address, nil, block
        )
        deviceListListenerBlock = nil
    }

    // MARK: - Per-Device Listeners

    /// Discovers all video devices and installs a property listener on each
    /// for `kCMIODevicePropertyDeviceIsRunningSomewhere`.
    private func refreshDeviceListeners() {
        guard isStarted else { return }
        let currentDeviceIDs = Set(enumerateCameraDeviceIDs())

        // Remove listeners for devices that are gone
        for (deviceID, block) in monitoredDevices where !currentDeviceIDs.contains(deviceID) {
            removeRunningListener(deviceID: deviceID, block: block)
        }
        let staleDeviceIDs = monitoredDevices.keys.filter { !currentDeviceIDs.contains($0) }
        for id in staleDeviceIDs {
            monitoredDevices.removeValue(forKey: id)
        }

        // Add listeners for new devices
        for deviceID in currentDeviceIDs where monitoredDevices[deviceID] == nil {
            let block: CMIOListenerBlock = { [weak self] _, _ in
                self?.queue.async { [weak self] in self?.checkCameraState() }
            }
            monitoredDevices[deviceID] = block

            var address = CMIOObjectPropertyAddress(
                mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeWildcard),
                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementWildcard)
            )
            CMIOObjectAddPropertyListenerBlock(deviceID, &address, nil, block)
        }

        // Check initial state
        checkCameraState()
    }

    private func removeAllDeviceListeners() {
        for (deviceID, block) in monitoredDevices {
            removeRunningListener(deviceID: deviceID, block: block)
        }
        monitoredDevices.removeAll()
    }

    private func removeRunningListener(deviceID: CMIOObjectID, block: @escaping CMIOListenerBlock) {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeWildcard),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementWildcard)
        )
        CMIOObjectRemovePropertyListenerBlock(deviceID, &address, nil, block)
    }

    // MARK: - State Check

    private func checkCameraState() {
        guard isStarted else { return }
        let active = monitoredDevices.keys.contains { isDeviceRunning($0) }
        if active != isCameraActive {
            isCameraActive = active
            fputs("[camera-monitor] camera \(active ? "ON" : "OFF")\n", stderr)
            onCameraStateChanged?(active)
        }
    }

    private func isDeviceRunning(_ deviceID: CMIOObjectID) -> Bool {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeWildcard),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementWildcard)
        )
        var dataSize: UInt32 = 0
        var dataUsed: UInt32 = 0

        guard CMIOObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == OSStatus(kCMIOHardwareNoError),
              dataSize > 0 else {
            return false
        }

        var isRunning: UInt32 = 0
        guard CMIOObjectGetPropertyData(deviceID, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &dataUsed, &isRunning) == OSStatus(kCMIOHardwareNoError) else {
            return false
        }
        return isRunning != 0
    }

    // MARK: - Device Enumeration

    /// Enumerate camera input streams through the public DAL API. Do not use
    /// AVCaptureDevice discovery or its private _connectionID KVC property.
    private func enumerateCameraDeviceIDs() -> [CMIOObjectID] {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var size: UInt32 = 0
        let system = CMIOObjectID(kCMIOObjectSystemObject)
        guard CMIOObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        var devices = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        let status = devices.withUnsafeMutableBytes { buffer in
            CMIOObjectGetPropertyData(system, &address, 0, nil, size, &used, buffer.baseAddress)
        }
        guard status == noErr else { return [] }
        return devices.prefix(Int(used) / MemoryLayout<CMIOObjectID>.size).filter { device in
            var streams = CMIOObjectPropertyAddress(
                mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyStreams),
                mScope: CMIOObjectPropertyScope(kCMIODevicePropertyScopeInput),
                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
            )
            var streamSize: UInt32 = 0
            return CMIOObjectGetPropertyDataSize(device, &streams, 0, nil, &streamSize) == noErr
                && streamSize > 0
        }
    }
}
