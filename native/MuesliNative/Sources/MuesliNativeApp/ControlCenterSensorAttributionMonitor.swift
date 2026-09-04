import Foundation
import os

struct SensorAttributionSnapshot: Equatable {
    let micBundleIDs: Set<String>
    let cameraBundleIDs: Set<String>
    let observedAt: Date?

    static let empty = SensorAttributionSnapshot(
        micBundleIDs: [],
        cameraBundleIDs: [],
        observedAt: nil
    )
}

final class ControlCenterSensorAttributionMonitor {
    private static let logger = Logger(subsystem: "com.muesli.native", category: "MeetingDetection")
    private static let attributionRegex = try? NSRegularExpression(pattern: #""(mic|cam):([^"]+)""#)

    var onAttributionsChanged: (() -> Void)?

    private let lock = NSLock()
    private var process: Process?
    private var outputPipe: Pipe?
    private var lineBuffer = ""
    private var currentSnapshot: SensorAttributionSnapshot

    init(initialSnapshot: SensorAttributionSnapshot = .empty) {
        currentSnapshot = initialSnapshot
    }

    func start() {
        lock.lock()
        let alreadyRunning = process != nil
        lock.unlock()
        guard !alreadyRunning else { return }

        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = [
            "stream",
            "--style",
            "compact",
            "--level",
            "debug",
            "--predicate",
            "subsystem == \"com.apple.controlcenter\" && category == \"sensor-indicators\" && eventMessage BEGINSWITH \"Active activity attributions changed to \"",
        ]
        process.standardOutput = pipe
        process.standardError = Pipe()

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty,
                  let text = String(data: data, encoding: .utf8) else { return }
            self?.consume(text)
        }

        process.terminationHandler = { [weak self] terminatedProcess in
            self?.clearProcess(ifCurrent: terminatedProcess)
        }

        do {
            try process.run()
            Self.logger.notice("sensor_attribution_stream_started")
            lock.lock()
            self.process = process
            outputPipe = pipe
            lock.unlock()
        } catch {
            Self.logger.error("sensor_attribution_stream_failed error=\(String(describing: error), privacy: .public)")
            pipe.fileHandleForReading.readabilityHandler = nil
        }
    }

    func stop() {
        lock.lock()
        let runningProcess = process
        let pipe = outputPipe
        process = nil
        outputPipe = nil
        lineBuffer = ""
        currentSnapshot = .empty
        lock.unlock()

        pipe?.fileHandleForReading.readabilityHandler = nil
        if runningProcess?.isRunning == true {
            runningProcess?.terminate()
        }
    }

    func snapshot() -> SensorAttributionSnapshot {
        lock.lock()
        let snapshot = currentSnapshot
        lock.unlock()
        return snapshot
    }

    private func consume(_ text: String) {
        let lines: [String]
        lock.lock()
        lineBuffer += text
        let parts = lineBuffer.split(separator: "\n", omittingEmptySubsequences: false)
        if lineBuffer.hasSuffix("\n") {
            lines = parts.map(String.init)
            lineBuffer = ""
        } else {
            lines = parts.dropLast().map(String.init)
            lineBuffer = parts.last.map(String.init) ?? ""
        }
        lock.unlock()

        for line in lines {
            guard let snapshot = Self.parseSnapshot(from: line) else { continue }
            lock.lock()
            currentSnapshot = snapshot
            let callback = onAttributionsChanged
            lock.unlock()
            logSnapshot(snapshot)
            callback?()
        }
    }

    private func clearProcess(ifCurrent terminatedProcess: Process) {
        lock.lock()
        guard process === terminatedProcess else {
            lock.unlock()
            return
        }
        let hadActiveAttribution = !currentSnapshot.micBundleIDs.isEmpty
            || !currentSnapshot.cameraBundleIDs.isEmpty
        process = nil
        outputPipe = nil
        lineBuffer = ""
        currentSnapshot = .empty
        let callback = onAttributionsChanged
        lock.unlock()

        if hadActiveAttribution {
            Self.logger.notice("sensor_attribution_stream_ended_clearing_snapshot")
            callback?()
        }
    }

    private func logSnapshot(_ snapshot: SensorAttributionSnapshot) {
        let mic = snapshot.micBundleIDs.sorted().joined(separator: ",")
        let camera = snapshot.cameraBundleIDs.sorted().joined(separator: ",")
        if mic.isEmpty && camera.isEmpty {
            Self.logger.notice("sensor_attributions_cleared")
        } else {
            Self.logger.notice("sensor_attributions mic=\(mic, privacy: .public) camera=\(camera, privacy: .public)")
        }
    }

    static func parseSnapshot(from line: String, now: Date = Date()) -> SensorAttributionSnapshot? {
        guard let range = line.range(of: "Active activity attributions changed to [") else {
            return nil
        }

        let tail = line[range.upperBound...]
        guard let closingBracket = tail.firstIndex(of: "]") else { return nil }
        let payload = tail[..<closingBracket]

        var micBundleIDs = Set<String>()
        var cameraBundleIDs = Set<String>()
        guard let regex = attributionRegex else { return nil }
        let nsPayload = NSString(string: String(payload))
        let matches = regex.matches(
            in: String(payload),
            range: NSRange(location: 0, length: nsPayload.length)
        )

        for match in matches where match.numberOfRanges == 3 {
            let kind = nsPayload.substring(with: match.range(at: 1))
            let bundleID = nsPayload.substring(with: match.range(at: 2))
            if kind == "mic" {
                micBundleIDs.insert(bundleID)
            } else if kind == "cam" {
                cameraBundleIDs.insert(bundleID)
            }
        }

        return SensorAttributionSnapshot(
            micBundleIDs: micBundleIDs,
            cameraBundleIDs: cameraBundleIDs,
            observedAt: now
        )
    }
}
