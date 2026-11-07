import AppKit
import Darwin
import Foundation
import IOKit.pwr_mgt
import Network

/// Facts for one recording. An unavailable observation is never evidence of an end.
struct MeetingAutoStopFacts {
    enum Network: Equatable { case unknown, available, unavailable }
    enum Assertion: Equatable { case unknown, present, absent }
    enum Probe: Equatable { case unknown, reachable, unavailable }

    static let onlineGrace: TimeInterval = 15
    static let offlineGrace: TimeInterval = 8 * 60
    static let reconnectGrace: TimeInterval = 60

    var network: Network = .unknown
    var networkUnavailableSince: Date?
    var lastNetworkRecovery: Date?
    var assertionObserved = false
    var assertionLostAt: Date?
    var networkInterruptedDuringLoss = false
    var probe: Probe = .unknown
    var lastProbeRecovery: Date?

    mutating func observeProbe(_ value: Probe, now: Date) {
        if value == .reachable, probe == .unavailable { lastProbeRecovery = now }
        if value == .unavailable { networkInterruptedDuringLoss = true }
        probe = value
    }

    mutating func observeNetwork(_ value: Network, now: Date) {
        if value == .unavailable, networkUnavailableSince == nil { networkUnavailableSince = now }
        if value == .available, networkUnavailableSince != nil {
            lastNetworkRecovery = now
            networkUnavailableSince = nil
        }
        network = value
        if value == .unavailable, assertionLostAt != nil { networkInterruptedDuringLoss = true }
    }

    mutating func observeAssertion(_ value: Assertion, now: Date) {
        switch value {
        case .unknown:
            // A gap in observation cannot count toward continuous absence.
            assertionLostAt = nil
            networkInterruptedDuringLoss = false
            probe = .unknown
            lastProbeRecovery = nil
        case .present:
            assertionObserved = true
            assertionLostAt = nil
            networkInterruptedDuringLoss = false
            probe = .unknown
            lastProbeRecovery = nil
        case .absent:
            guard assertionObserved else { return }
            if assertionLostAt == nil {
                assertionLostAt = now
                networkInterruptedDuringLoss = network == .unavailable || lastNetworkRecovery.map {
                    now.timeIntervalSince($0) <= Self.reconnectGrace
                } == true
            }
        }
    }

    func shouldStop(now: Date) -> Bool {
        guard assertionObserved, let lostAt = assertionLostAt, network != .unknown else { return false }
        if network == .unavailable || probe == .unavailable {
            return now.timeIntervalSince(lostAt) >= Self.offlineGrace
        }
        guard probe == .reachable else { return false }
        if networkInterruptedDuringLoss {
            let recovered = [lastNetworkRecovery, lastProbeRecovery].compactMap { $0 }.max()
            guard let recovered, now.timeIntervalSince(recovered) >= Self.reconnectGrace else { return false }
        }
        return now.timeIntervalSince(lostAt) >= Self.onlineGrace
    }
}

enum MeetingAssertionTarget: Equatable, Sendable {
    case zoom, teams, webex
    case browser(bundleID: String)

    var bundleIDs: [String] {
        switch self {
        case .zoom: return ["us.zoom.xos"]
        case .teams: return ["com.microsoft.teams2", "com.microsoft.teams"]
        case .webex: return ["com.webex.meetingmanager", "com.cisco.webexmeetingsapp"]
        case .browser(let bundleID): return [bundleID]
        }
    }

    func matches(name: String, type: String, level: Int) -> Bool {
        guard level == kIOPMAssertionLevelOn else { return false }
        let name = name.lowercased()
        switch self {
        case .zoom:
            return ["NoDisplaySleepAssertion", "PreventUserIdleDisplaySleep"].contains(type)
        case .teams:
            return name.contains("call in progress")
        case .webex:
            return name.contains("on a call")
        case .browser:
            return name.contains("webrtc") && name.contains("peerconnection")
        }
    }
}

enum MeetingAssertionReader {
    /// Conservative calendar-start check. A failed snapshot is unknown, not idle.
    static func hasAnySupportedMeetingAssertion() -> Bool? {
        let targets: [MeetingAssertionTarget] = [.zoom, .teams, .webex]
            + MeetingCandidateResolver.browserApps.keys.map { .browser(bundleID: $0) }
        for target in targets {
            let roots = target.bundleIDs.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }
                .compactMap { app -> (pid_t, String)? in
                    guard let path = app.bundleURL?.path else { return nil }
                    return (app.processIdentifier, path)
                }
            guard !roots.isEmpty else { continue }
            guard let present = hasAssertion(target: target, roots: roots) else { return nil }
            if present { return true }
        }
        return false
    }

    /// Public IOKit snapshot. Call off the main actor; nil means the query failed.
    static func hasAssertion(target: MeetingAssertionTarget, roots: [(pid_t, String)]) -> Bool? {
        var unmanaged: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&unmanaged) == kIOReturnSuccess,
              let dictionary = unmanaged?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return nil }
        return dictionary.contains { pid, assertions in
            let processID = pid.int32Value
            var path = [CChar](repeating: 0, count: 4096)
            let length = proc_pidpath(processID, &path, UInt32(path.count))
            let executable = length > 0 ? String(cString: path) : ""
            guard roots.contains(where: { rootPID, rootPath in
                rootPID == processID || executable.hasPrefix(rootPath + "/Contents/")
            }) else { return false }
            return assertions.contains { assertion in
                guard let type = assertion["AssertType"] as? String,
                      let name = assertion["AssertName"] as? String,
                      let level = (assertion["AssertLevel"] as? NSNumber)?.intValue else { return false }
                return target.matches(name: name, type: type, level: level)
            }
        }
    }
}

enum MeetingConnectivityProbe {
    static let endpoint = URL(string: "https://connectivitycheck.gstatic.com/generate_204")!

    static func isReachable() async -> Bool {
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 5
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpShouldSetCookies = false
        config.urlCache = nil
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        do {
            let (_, response) = try await session.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 204 && response.url == endpoint
        } catch {
            return false
        }
    }
}

@MainActor
final class MeetingAutoStopObserver {
    typealias AssertionReader = @MainActor (MeetingAssertionTarget) async -> Bool?
    typealias ConnectivityProbe = @MainActor () async -> Bool
    typealias PollWait = @MainActor () async -> Void

    private let readAssertion: AssertionReader
    private let probeConnectivity: ConnectivityProbe
    private let now: @MainActor () -> Date
    private let waitForNextPoll: PollWait
    private let monitorNetwork: Bool
    private var networkMonitor: NWPathMonitor?
    private var pollTask: Task<Void, Never>?
    private var facts = MeetingAutoStopFacts()
    private var generation = UUID()
    private var observationGeneration = UUID()
    private var networkGeneration = UUID()
    private var wakeObserver: NSObjectProtocol?
    private var lastProbeAt: Date?
    var hasObservedAssertion: Bool { facts.assertionObserved }

    init(
        readAssertion: @escaping AssertionReader = { target in
            await Task.detached(priority: .utility) {
                let roots = target.bundleIDs.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }
                    .compactMap { app -> (pid_t, String)? in
                        guard let path = app.bundleURL?.path else { return nil }
                        return (app.processIdentifier, path)
                    }
                return MeetingAssertionReader.hasAssertion(target: target, roots: roots)
            }.value
        },
        probeConnectivity: @escaping ConnectivityProbe = { await MeetingConnectivityProbe.isReachable() },
        now: @escaping @MainActor () -> Date = { Date() },
        waitForNextPoll: @escaping PollWait = { try? await Task.sleep(nanoseconds: 3_000_000_000) },
        monitorNetwork: Bool = true
    ) {
        self.readAssertion = readAssertion
        self.probeConnectivity = probeConnectivity
        self.now = now
        self.waitForNextPoll = waitForNextPoll
        self.monitorNetwork = monitorNetwork
    }

    func start(target: MeetingAssertionTarget, isEligible: @escaping @MainActor () -> Bool, onStop: @escaping @MainActor () -> Bool) {
        stop()
        let owner = generation
        if monitorNetwork { startNetworkMonitor(owner: owner) }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == owner else { return }
                // Clock gaps across sleep are not continuous observation.
                self.resetObservation(preservingNetwork: false)
                if self.monitorNetwork { self.startNetworkMonitor(owner: owner) }
            }
        }
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.generation == owner else { return }
                let observationOwner = self.observationGeneration
                let result = await self.readAssertion(target)
                guard !Task.isCancelled, self.generation == owner else { return }
                guard self.observationGeneration == observationOwner else { continue }
                guard isEligible() else {
                    self.resetObservation(preservingNetwork: true)
                    await self.waitForNextPoll()
                    continue
                }
                self.facts.observeAssertion(result.map { $0 ? .present : .absent } ?? .unknown, now: self.now())
                if self.facts.assertionLostAt == nil { self.lastProbeAt = nil }
                if self.facts.assertionLostAt != nil, self.facts.network == .available,
                   self.lastProbeAt.map({ self.now().timeIntervalSince($0) >= 15 }) ?? true {
                    self.lastProbeAt = self.now()
                    let reachable = await self.probeConnectivity()
                    guard !Task.isCancelled, self.generation == owner else { return }
                    guard self.observationGeneration == observationOwner else { continue }
                    self.facts.observeProbe(reachable ? .reachable : .unavailable, now: self.now())
                    // Re-read the assertion after the asynchronous probe before stopping.
                    continue
                }
                if self.facts.shouldStop(now: self.now()) {
                    if onStop() { return }
                    // Retain the observed assertion but require a fresh loss grace
                    // if the controller declined this stop attempt.
                    self.facts.assertionLostAt = nil
                    self.facts.networkInterruptedDuringLoss = false
                }
                await self.waitForNextPoll()
            }
        }
    }

    /// Invalidates any in-flight snapshot/probe and requires a fresh assertion.
    func resetObservation(preservingNetwork: Bool = true) {
        observationGeneration = UUID()
        let network = preservingNetwork ? facts.network : .unknown
        facts = MeetingAutoStopFacts()
        facts.observeNetwork(network, now: now())
        lastProbeAt = nil
    }

    func observeNetwork(_ value: MeetingAutoStopFacts.Network) {
        facts.observeNetwork(value, now: now())
    }

    private func startNetworkMonitor(owner: UUID) {
        networkMonitor?.cancel()
        networkGeneration = UUID()
        let networkOwner = networkGeneration
        let monitor = NWPathMonitor()
        networkMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            let network: MeetingAutoStopFacts.Network
            switch path.status {
            case .satisfied: network = .available
            case .unsatisfied: network = .unavailable
            case .requiresConnection: network = .unknown
            @unknown default: network = .unknown
            }
            Task { @MainActor [weak self] in
                guard let self, self.generation == owner, self.networkGeneration == networkOwner else { return }
                self.observeNetwork(network)
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.muesli.meeting-network-monitor"))
    }

    func stop() {
        generation = UUID()
        observationGeneration = UUID()
        networkGeneration = UUID()
        pollTask?.cancel()
        pollTask = nil
        networkMonitor?.cancel()
        networkMonitor = nil
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        facts = MeetingAutoStopFacts()
        lastProbeAt = nil
    }
}
