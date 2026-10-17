import AppKit
import ApplicationServices
import Foundation
import MuesliCore

struct MeetingSpeakerAuthorizationCache {
    static let refreshInterval: TimeInterval = 2

    private(set) var generation = UUID()
    private var enabled: Bool?
    private var trusted: Bool?
    private var checkedAt: Double?

    mutating func authorization(
        enabled nextEnabled: Bool,
        now: Double,
        forceRefresh: Bool = false,
        isTrusted: () -> Bool
    ) -> UUID? {
        if enabled != nextEnabled {
            enabled = nextEnabled
            generation = UUID()
            checkedAt = nil
        }
        if nextEnabled, forceRefresh || checkedAt == nil || now < (checkedAt ?? 0)
            || now - (checkedAt ?? 0) >= Self.refreshInterval {
            let nextTrusted = isTrusted()
            if trusted != nextTrusted { generation = UUID() }
            trusted = nextTrusted
            checkedAt = now
        }
        return nextEnabled && trusted == true ? generation : nil
    }
}

/// Coordinates asynchronous monitor startup with capture shutdown. Every await
/// is followed by an activity check, and a resource acquired during shutdown is
/// rolled back before startup returns.
enum MeetingSpeakerAccessibilityStartup {
    static func startIfActive(
        isActive: () -> Bool,
        requestAuthorization: () async -> UUID?,
        didAuthorize: (UUID) -> Bool,
        acquireOwner: (UUID) async -> Void,
        startMonitor: (UUID) async -> Void,
        release: () async -> Void
    ) async -> UUID? {
        guard isActive(), let authorization = await requestAuthorization(),
              isActive(), didAuthorize(authorization) else { return nil }

        await acquireOwner(authorization)
        guard isActive() else {
            await release()
            return nil
        }

        await startMonitor(authorization)
        guard isActive() else {
            await release()
            return nil
        }
        return authorization
    }
}

final class MeetingSpeakerAccessibilityStartupGate: @unchecked Sendable {
    private let lock = NSLock()
    private var ended = false
    private var authorization: UUID?

    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !ended
    }

    func authorize(_ authorization: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !ended else { return false }
        self.authorization = authorization
        return true
    }

    func end() -> UUID? {
        lock.lock()
        defer { lock.unlock() }
        ended = true
        return authorization
    }
}

/// Tracks sample time for audio already written to the system recording. It is
/// independent of the live chunk queue, which can reject the short tail while
/// a native recorder is applying a pause.
final class MeetingSpeakerAudioTimelineClock: @unchecked Sendable {
    private static let sampleRate = 16_000.0
    private static let maximumSampleAge = 1.5

    private let lock = NSLock()
    private var sampleCount: Int64 = 0
    private var lastSampleUptime: Double?

    func start() {
        lock.withLock {
            sampleCount = 0
            lastSampleUptime = nil
        }
    }

    func recordRecordedSamples(_ count: Int, uptime: Double) {
        guard count > 0, uptime.isFinite else { return }
        lock.withLock {
            sampleCount += Int64(count)
            lastSampleUptime = uptime
        }
    }

    func breakContinuity() {
        lock.withLock { lastSampleUptime = nil }
    }

    func elapsedTimeSeconds(isCapturing: Bool, now: Double) -> Double? {
        guard isCapturing, now.isFinite else { return nil }
        return lock.withLock {
            guard let lastSampleUptime, now >= lastSampleUptime,
                  now - lastSampleUptime <= Self.maximumSampleAge else { return nil }
            return Double(sampleCount) / Self.sampleRate
        }
    }
}

/// One bounded scan at a time on this actor, never on the UI executor. Diagnostics contain counts only.
actor MeetingSpeakerAccessibilityMonitor {
    typealias Reader = @Sendable () async -> MeetingSpeakerFrame

    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var continuity = UUID()
    private var authorizationRevoked = false
    private var observations: MeetingSpeakerObservationRing
    private var diagnosticCounts: [MeetingSpeakerAccessibilityDiagnosticReason: Int] = [:]
    private let observationLimit: Int
    private let reader: Reader

    init(
        observationLimit: Int = MeetingSpeakerAccessibilitySamplingPolicy.maximumObservations,
        reader: @escaping Reader = { await MeetingSpeakerAXReader.read() }
    ) {
        self.observationLimit = max(1, observationLimit)
        self.observations = MeetingSpeakerObservationRing(capacity: max(1, observationLimit))
        self.reader = reader
    }

    func start(authorization: UUID, token: @escaping () async -> UUID?, clock: @escaping () -> Double?) {
        task?.cancel()
        generation = UUID()
        continuity = UUID()
        authorizationRevoked = false
        observations = MeetingSpeakerObservationRing(capacity: observationLimit)
        diagnosticCounts = [:]
        let generation = generation
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.poll(generation: generation, authorization: authorization, token: token, clock: clock)
                let intervalMilliseconds = Int64(MeetingSpeakerAccessibilitySamplingPolicy.pollInterval * 1_000)
                try? await Task.sleep(for: .milliseconds(intervalMilliseconds))
            }
        }
    }

    func breakContinuity() {
        continuity = UUID()
        note(.continuityBreak)
    }

    /// Single-poll entry point used by deterministic monitor tests.
    func recordPoll(authorization: UUID, token: @escaping () async -> UUID?, clock: @escaping () -> Double?) async {
        await poll(generation: generation, authorization: authorization, token: token, clock: clock)
    }

    func stop() -> MeetingSpeakerTimeline {
        task?.cancel()
        task = nil
        generation = UUID()
        return .init(observations: observations.elements, diagnosticCounts: diagnosticCounts)
    }

    private func poll(
        generation: UUID,
        authorization: UUID,
        token: @escaping () async -> UUID?,
        clock: @escaping () -> Double?
    ) async {
        guard self.generation == generation else { return }
        guard !authorizationRevoked else { return }
        guard await token() == authorization else {
            revokeAuthorization()
            return
        }
        guard let start = clock(), start.isFinite, start >= 0 else {
            note(.noSystemAudio)
            breakContinuity()
            return
        }

        let frame = await reader()

        guard self.generation == generation, !Task.isCancelled else { return }
        guard await token() == authorization else {
            revokeAuthorization()
            return
        }
        guard let end = clock(), end.isFinite, end >= start else {
            note(.clockInvalid)
            breakContinuity()
            return
        }
        guard end - start <= MeetingSpeakerAccessibilitySamplingPolicy.maximumReadDuration else {
            note(.readOverBudget)
            breakContinuity()
            return
        }

        recordFrameReasons(frame)
        if let previous = observations.elements.last,
           previous.frame.app == frame.app, previous.frame.scope != frame.scope {
            note(.scopeChanged)
        }
        observations.append(.init(time: end, continuity: continuity.uuidString, frame: frame))
    }

    private func recordFrameReasons(_ frame: MeetingSpeakerFrame) {
        var reasons = frame.diagnosticReasons
        if frame.reason != .clear, frame.reason != .unrecognized, !reasons.contains(frame.reason) {
            reasons.append(frame.reason)
        }
        if reasons.isEmpty, frame.reason != .clear { reasons.append(frame.reason) }
        if reasons.isEmpty { return }
        for reason in Set(reasons) {
            switch reason {
            case .clear: break
            case .rosterOnly: note(.rosterOnly)
            case .unrecognized: note(.unrecognizedLayout)
            case .truncated: note(.truncatedRead)
            case .ambiguous: note(.ambiguousLayout)
            case .multipleHosts: note(.multipleHosts)
            case .multipleWindows: note(.multipleWindows)
            case .unavailable: note(.unavailable)
            case .windowLimit: note(.windowLimit)
            }
        }
    }

    private func note(_ reason: MeetingSpeakerAccessibilityDiagnosticReason) {
        diagnosticCounts[reason, default: 0] += 1
    }

    private func revokeAuthorization() {
        guard !authorizationRevoked else { return }
        authorizationRevoked = true
        task?.cancel()
        task = nil
        note(.authorizationChanged)
        breakContinuity()
    }
}

private struct MeetingSpeakerObservationRing {
    private var slots: [MeetingSpeakerObservation?]
    private var nextIndex = 0
    private var count = 0

    init(capacity: Int) {
        slots = Array(repeating: nil, count: max(1, capacity))
    }

    mutating func append(_ observation: MeetingSpeakerObservation) {
        slots[nextIndex] = observation
        nextIndex = (nextIndex + 1) % slots.count
        count = min(count + 1, slots.count)
    }

    var elements: [MeetingSpeakerObservation] {
        guard count > 0 else { return [] }
        let startIndex = count == slots.count ? nextIndex : 0
        return (0..<count).compactMap { offset in slots[(startIndex + offset) % slots.count] }
    }
}

private enum MeetingSpeakerAXReader {
    static func kind(_ id: String) -> MeetingSpeakerApp? {
        switch id {
        case "us.zoom.xos": .zoom
        case "com.microsoft.teams", "com.microsoft.teams2": .teams
        case "com.tinyspeck.slackmacgap": .slack
        case "com.google.Chrome", "com.microsoft.edgemac", "org.mozilla.firefox": .meet
        default: nil
        }
    }

    static func read() async -> MeetingSpeakerFrame {
        guard AXIsProcessTrusted() else { return .init(scope: "", app: .zoom, reason: .unavailable) }
        let deadline = ProcessInfo.processInfo.systemUptime + MeetingSpeakerAccessibilitySamplingPolicy.totalReadDuration
        let runningApps = MeetingSpeakerRunningAppsSnapshotStore.shared.snapshot()
        return read(runningApps, deadline: deadline)
    }

    private static func read(_ runningApps: [RunningAppSnapshot], deadline: Double) -> MeetingSpeakerFrame {
        var frames: [MeetingSpeakerFrame] = []

        for app in runningApps where kind(app.bundleID) != nil {
            guard ProcessInfo.processInfo.systemUptime < deadline, let kind = kind(app.bundleID) else {
                frames.append(.init(scope: "", app: .zoom, reason: .truncated))
                break
            }
            let element = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(element, 0.05)
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value) == .success,
                  let windows = value as? [AXUIElement] else {
                frames.append(.init(scope: "", app: kind, reason: .unavailable,
                    diagnosticReasons: [.unavailable]))
                continue
            }

            if kind == .meet {
                readMeetWindows(windows, app: app, kind: kind, deadline: deadline, into: &frames)
                continue
            }
            guard windows.count <= MeetingSpeakerAccessibilitySamplingPolicy.maximumWindowsPerApp else {
                frames.append(.init(scope: "", app: kind, reason: .unavailable))
                continue
            }
            for window in windows {
                readWindow(window, app: app, kind: kind, documentURL: nil, deadline: deadline, into: &frames)
            }
        }
        return MeetingSpeakerSources.combine(frames)
    }

    private static func readMeetWindows(
        _ windows: [AXUIElement],
        app: RunningAppSnapshot,
        kind: MeetingSpeakerApp,
        deadline: Double,
        into frames: inout [MeetingSpeakerFrame]
    ) {
        let scanLimit = MeetingSpeakerAccessibilitySamplingPolicy.maximumBrowserWindowsScanned
        guard windows.count <= scanLimit else {
            frames.append(MeetingSpeakerSources.incompleteMeetScan())
            return
        }

        var documents: [String?] = []
        var documentReadFailed = false
        for window in windows {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                documentReadFailed = true
                break
            }
            AXUIElementSetMessagingTimeout(window, 0.05)
            var reader = Reader(deadline: min(deadline, ProcessInfo.processInfo.systemUptime + 0.05))
            documents.append(reader.text(window, kAXDocumentAttribute))
            if reader.failed { documentReadFailed = true }
        }
        guard !documentReadFailed else {
            frames.append(MeetingSpeakerSources.incompleteMeetScan())
            return
        }
        guard let meetURLs = MeetingSpeakerSources.meetDocumentURLs(
            documents,
            maximumRelevantWindows: MeetingSpeakerAccessibilitySamplingPolicy.maximumWindowsPerApp
        ) else {
            frames.append(.init(scope: "", app: kind, reason: .windowLimit, diagnosticReasons: [.windowLimit]))
            return
        }
        guard !meetURLs.isEmpty else { return }

        let candidates = zip(windows, documents).compactMap { pair -> (AXUIElement, String)? in
            let (window, document) = pair
            guard let document,
                  MeetingSpeakerSources.meetDocumentURLs([document], maximumRelevantWindows: 1)?.first != nil else { return nil }
            return (window, document)
        }
        for (window, documentURL) in candidates {
            readWindow(window, app: app, kind: kind, documentURL: documentURL, deadline: deadline, into: &frames)
        }
    }

    private static func readWindow(
        _ window: AXUIElement,
        app: RunningAppSnapshot,
        kind: MeetingSpeakerApp,
        documentURL: String?,
        deadline: Double,
        into frames: inout [MeetingSpeakerFrame]
    ) {
        let windowDeadline = min(deadline, ProcessInfo.processInfo.systemUptime + MeetingSpeakerAccessibilitySamplingPolicy.perWindowReadDuration)
        var reader = Reader(deadline: windowDeadline)
        let root = reader.node(window, depth: 0)
        var hasher = Hasher()
        hasher.combine(rootFingerprint(root))
        let scope = "\(app.processIdentifier)/\(CFHash(window))/\(hasher.finalize())"
        frames.append(MeetingSpeakerSources.decode(.init(scope: scope, app: kind,
            documentURL: documentURL, root: root, truncated: reader.failed)))
    }

    private static func rootFingerprint(_ node: MeetingSpeakerAXNode) -> [String] {
        // Ignore activity status and order; changed participant/name layouts break continuity.
        ([node.id + node.detail + (node.detail.lowercased().contains("name") ? (node.value ?? "") : "")]
            + node.children.flatMap(rootFingerprint)).sorted()
    }

    private struct Reader {
        let deadline: Double
        var remaining = 600
        var visited: Set<CFHashCode> = []
        var failed = false

        mutating func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
            guard ProcessInfo.processInfo.systemUptime < deadline else { failed = true; return nil }
            var value: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(element, key as CFString, &value)
            if error != .success, error != .attributeUnsupported, error != .noValue { failed = true }
            return value
        }

        mutating func text(_ element: AXUIElement, _ key: String) -> String? {
            guard let value = attribute(element, key) else { return nil }
            let text: String?
            if CFGetTypeID(value) == CFBooleanGetTypeID(), let boolean = value as? NSNumber {
                text = boolean.boolValue ? "true" : "false"
            } else {
                text = (value as? String) ?? (value as? NSNumber)?.stringValue
            }
            if let text, text.count > 500 { failed = true; return nil }
            return text
        }

        mutating func node(_ element: AXUIElement, depth: Int) -> MeetingSpeakerAXNode {
            let id = String(CFHash(element))
            let hash = CFHash(element)
            switch MeetingSpeakerAXTraversalDecision.evaluate(
                remaining: remaining,
                depth: depth,
                alreadyVisited: visited.contains(hash),
                withinDeadline: ProcessInfo.processInfo.systemUptime < deadline
            ) {
            case .skipDuplicate:
                return .init(id: id, role: "", detail: "")
            case .truncated:
                failed = true
                return .init(id: id, role: "", detail: "")
            case .visit:
                visited.insert(hash)
            }
            remaining -= 1
            AXUIElementSetMessagingTimeout(element, 0.05)
            let role = text(element, kAXRoleAttribute) ?? ""
            let detail = text(element, kAXDescriptionAttribute) ?? text(element, kAXRoleDescriptionAttribute) ?? ""
            let value = text(element, kAXValueAttribute)
            var children: [MeetingSpeakerAXNode] = []
            var count: CFIndex = 0
            let countError = AXUIElementGetAttributeValueCount(element, kAXChildrenAttribute as CFString, &count)
            if countError == .success, count > 0 {
                guard count <= 100, ProcessInfo.processInfo.systemUptime < deadline else {
                    failed = true
                    return .init(id: id, role: role, detail: detail, value: value)
                }
                var raw: CFArray?
                if AXUIElementCopyAttributeValues(element, kAXChildrenAttribute as CFString, 0, count, &raw) == .success,
                   let elements = raw as? [AXUIElement] {
                    for child in elements { children.append(node(child, depth: depth + 1)) }
                } else {
                    failed = true
                }
            } else if countError != .success, countError != .attributeUnsupported, countError != .noValue {
                failed = true
            }
            return .init(id: id, role: role, detail: detail, value: value, children: children)
        }
    }
}

enum MeetingSpeakerAXTraversalDecision: Equatable {
    case visit
    case skipDuplicate
    case truncated

    static func evaluate(remaining: Int, depth: Int, alreadyVisited: Bool, withinDeadline: Bool) -> Self {
        guard remaining > 0, depth <= 14, withinDeadline else { return .truncated }
        return alreadyVisited ? .skipDuplicate : .visit
    }
}
