import AVFoundation
import CoreMediaIO
import Foundation

/// CMIO listener block type — different from CoreAudio's AudioObjectPropertyListenerBlock.
private typealias CMIOListenerBlock = @convention(block) (UInt32, UnsafePointer<CMIOObjectPropertyAddress>?) -> Void

/// Event-driven camera activity monitor using CoreMediaIO property listeners.
/// Fires a callback the moment any camera turns on or off — no polling.
@MainActor
final class CameraActivityMonitor {
    var onCameraStateChanged: ((Bool) -> Void)?

    private var monitoredDevices: [CMIOObjectID: CMIOListenerBlock] = [:]
    private var deviceListListenerBlock: CMIOListenerBlock?
    private(set) var isCameraActive = false

    func start() {
        installDeviceListListener()
        refreshDeviceListeners()
    }

    func stop() {
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
            DispatchQueue.main.async { self?.refreshDeviceListeners() }
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
                DispatchQueue.main.async { self?.checkCameraState() }
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

    /// Uses AVCaptureDevice.DiscoverySession to find video devices,
    /// then extracts their CMIOObjectID via the private `_connectionID` key.
    private func enumerateCameraDeviceIDs() -> [CMIOObjectID] {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external],
            mediaType: .video,
            position: .unspecified
        )
        return session.devices.compactMap { device -> CMIOObjectID? in
            device.value(forKey: "_connectionID") as? CMIOObjectID
        }
    }
}
