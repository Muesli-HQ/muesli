import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("Chatwoot scoped adapter")
struct ChatwootCallDetectionAdapterTests {
    @Test func connectedCustomOriginUsesScopedProviderEvidence() async throws {
        var fixture = ChatwootCallDetectionFixture()
        fixture.url = "https://chatwoot.selfhosted.com:8443/support/app?synthetic=1"
        fixture.origin = "https://chatwoot.selfhosted.com:8443"
        let provider = ChatwootCallDetectionFixtureProvider(fixture.result)
        let adapter = ChatwootCallDetectionAdapter(provider: provider, now: { ChatwootCallDetectionFixture.now })
        let observation = try ChatwootCallDetectionFixture.observation(await adapter.observe())
        #expect(observation.service == .chatwoot)
        #expect(observation.phase == .connected)
        #expect(observation.source.origin == "https://chatwoot.selfhosted.com:8443")
        #expect(observation.evidence == [.scopedCallControls, .connectedState, .verifiedBrowserOrigin])
        #expect(observation.observedAt == ChatwootCallDetectionFixture.now)
        #expect(UUID(uuidString: observation.callToken) != nil)
        #expect(await provider.readCount == 1)
        #expect(await provider.receivedLiveDeadline)
    }

    @Test func domainTitleAndGenericControlsDoNotProveProduct() async {
        var fixture = ChatwootCallDetectionFixture()
        fixture.product = .unverified
        #expect(await detect(fixture) == .unavailable(.unsupported))
        fixture.product = .scopedChatwootProfile
        fixture.profile = .unverified
        #expect(await detect(fixture) == .unavailable(.unsupported))
    }

    @Test func configuredOriginIsExactAndStillRequiresScopedProfile() async throws {
        var fixture = ChatwootCallDetectionFixture()
        fixture.product = .configuredOrigin
        let configured: Set<String> = ["https://chatwoot.selfhosted.com/base"]
        let provider = ChatwootCallDetectionFixtureProvider(fixture.result)
        let adapter = ChatwootCallDetectionAdapter(provider: provider, configuredOrigins: configured,
                                                  now: { ChatwootCallDetectionFixture.now })
        let connected = try ChatwootCallDetectionFixture.observation(await adapter.observe())
        #expect(connected.phase == .connected)
        for (url, origin) in [("https://chatwoot.selfhosted.com.evil.test", "https://chatwoot.selfhosted.com.evil.test:443"),
                              ("http://chatwoot.selfhosted.com", "http://chatwoot.selfhosted.com:80"),
                              ("https://chatwoot.selfhosted.com:8443", "https://chatwoot.selfhosted.com:8443")] {
            fixture.url = url
            fixture.origin = origin
            await provider.set(fixture.result)
            #expect(await adapter.observe() == .unavailable(.unsupported))
        }
        fixture = ChatwootCallDetectionFixture()
        fixture.product = .configuredOrigin
        fixture.profile = .unverified
        await provider.set(fixture.result)
        #expect(await adapter.observe() == .unavailable(.unsupported))
    }

    @Test func idleVoiceNotesHistoryAndDeviceTestsCannotBeConnected() async {
        var fixture = ChatwootCallDetectionFixture()
        fixture.surfaces = []
        #expect(await detect(fixture) == .unavailable(.noSource))
        for kind in [ChatwootCallDetectionSurfaceKind.voiceNote, .history, .deviceTest] {
            fixture = ChatwootCallDetectionFixture()
            fixture.kind = kind
            #expect(await detect(fixture) == .unavailable(.unsupported))
        }
    }

    @Test func ringingConnectingEndedAndUnknownNeverCarryConnectedEvidence() async throws {
        for phase in [CallDetectionPhase.ringing, .connecting, .ended, .unknown] {
            var fixture = ChatwootCallDetectionFixture()
            fixture.phase = phase
            let observation = try ChatwootCallDetectionFixture.observation(await detect(fixture))
            #expect(observation.phase == phase)
            #expect(observation.evidence.isEmpty)
        }
    }

    @Test func localConferenceJoinedWhileRemoteRingsIsNotConnected() async {
        var fixture = ChatwootCallDetectionFixture()
        fixture.transport = .localOnly
        #expect(await detect(fixture) == .unavailable(.unsupported))
        fixture.transport = .unknown
        #expect(await detect(fixture) == .unavailable(.unsupported))
        fixture.transport = .disconnected
        #expect(await detect(fixture) == .unavailable(.unsupported))
    }

    @Test func connectedNeedsBothScopedEndAndMuteControls() async {
        var fixture = ChatwootCallDetectionFixture()
        fixture.end = false
        #expect(await detect(fixture) == .unavailable(.unsupported))
        fixture.end = true
        fixture.mute = false
        #expect(await detect(fixture) == .unavailable(.unsupported))
    }

    @Test func permissionAndUnavailableNeverReturnCachedPositive() async throws {
        let provider = ChatwootCallDetectionFixtureProvider(ChatwootCallDetectionFixture().result)
        let adapter = ChatwootCallDetectionAdapter(provider: provider, now: { ChatwootCallDetectionFixture.now })
        let first = try ChatwootCallDetectionFixture.observation(await adapter.observe())
        for reason in [CallDetectionUnavailableReason.permissionRequired, .noSource, .unsupported, .ambiguous, .timedOut] {
            await provider.set(.unavailable(reason))
            #expect(await adapter.observe() == .unavailable(reason))
        }
        await provider.set(ChatwootCallDetectionFixture().result)
        let recovered = try ChatwootCallDetectionFixture.observation(await adapter.observe())
        #expect(recovered.callToken == first.callToken)
    }

    @Test func freshnessUsesReadTimeIncludingExactBoundaryAndFuture() async throws {
        var fixture = ChatwootCallDetectionFixture()
        fixture.observedAt = ChatwootCallDetectionFixture.now.addingTimeInterval(-5)
        let atBoundary = try ChatwootCallDetectionFixture.observation(await detect(fixture))
        #expect(atBoundary.observedAt == ChatwootCallDetectionFixture.now.addingTimeInterval(-5))
        for age in [-0.001, 5.001, Double.infinity, Double.nan] {
            fixture.observedAt = ChatwootCallDetectionFixture.now.addingTimeInterval(-age)
            #expect(await detect(fixture) == .unavailable(.stale))
        }
    }

    @Test func mismatchedSourceAndMidReadNavigationFailClosed() async {
        for change in 0..<7 {
            var fixture = ChatwootCallDetectionFixture()
            let source = fixture.source
            fixture.after = CallDetectionSource(
                bundleID: change == 0 ? "com.apple.Safari" : source.bundleID,
                processID: change == 1 ? 43 : source.processID,
                processLaunchID: change == 2 ? UUID().uuidString : source.processLaunchID,
                surfaceID: change == 3 ? UUID().uuidString : source.surfaceID,
                origin: change == 4 ? "https://other.example.test:443" : source.origin)
            if change == 5 { fixture.urlAfter = fixture.url + "/same-origin-route" }
            if change == 6 { fixture.urlAfter = "https://other.example.test/redirect" }
            #expect(await detect(fixture) == .unavailable(.sourceMismatch))
        }
    }

    @Test func malformedOriginOrMissingOpaqueSourceIdentityIsRejected() async {
        for url in ["https://user@chatwoot.selfhosted.com", "file:///app", "https://a.test/%ZZ"] {
            var fixture = ChatwootCallDetectionFixture()
            fixture.url = url
            #expect(await detect(fixture) == .unavailable(.sourceMismatch))
        }
        var fixture = ChatwootCallDetectionFixture()
        fixture.launch = "raw-process-label"
        #expect(await detect(fixture) == .unavailable(.sourceMismatch))
        fixture = ChatwootCallDetectionFixture()
        fixture.document = ""
        #expect(await detect(fixture) == .unavailable(.sourceMismatch))
        fixture = ChatwootCallDetectionFixture()
        fixture.origin = "https://other.example.test:443"
        #expect(await detect(fixture) == .unavailable(.sourceMismatch))
    }

    @Test func multipleCallSurfacesAreAmbiguousEvenWithOneRinging() async {
        var fixture = ChatwootCallDetectionFixture()
        fixture.surfaces = [fixture.call, fixture.call]
        #expect(await detect(fixture) == .unavailable(.ambiguous))
        fixture.phase = .ringing
        fixture.surfaces = [ChatwootCallDetectionFixture().call, fixture.call]
        #expect(await detect(fixture) == .unavailable(.ambiguous))
    }

    @Test func tokenStableWithinCallAndRotatesForEachNewScopeOrReconnect() async throws {
        let provider = ChatwootCallDetectionFixtureProvider(ChatwootCallDetectionFixture().result)
        let adapter = ChatwootCallDetectionAdapter(provider: provider, now: { ChatwootCallDetectionFixture.now })
        var previous = try ChatwootCallDetectionFixture.observation(await adapter.observe())
        let same = try ChatwootCallDetectionFixture.observation(await adapter.observe())
        #expect(same.callToken == previous.callToken)
        for change in 0..<6 {
            var fixture = ChatwootCallDetectionFixture()
            switch change {
            case 0: fixture.session = UUID()
            case 1: fixture.launch = UUID().uuidString
            case 2: fixture.document = UUID().uuidString // same-origin navigation
            case 3: fixture.bundle = "com.apple.Safari" // tab/browser replacement
            case 4: fixture.url = "https://other.example.test:8443/base"; fixture.origin = "https://other.example.test:8443"
            default: fixture.pid = 43
            }
            await provider.set(fixture.result)
            let next = try ChatwootCallDetectionFixture.observation(await adapter.observe())
            #expect(next.callToken != previous.callToken)
            previous = next
        }
    }

    @Test func routeChangeWithoutNewDocumentGenerationFailsClosed() async throws {
        var fixture = ChatwootCallDetectionFixture()
        let provider = ChatwootCallDetectionFixtureProvider(fixture.result)
        let adapter = ChatwootCallDetectionAdapter(provider: provider, now: { ChatwootCallDetectionFixture.now })
        let initial = try ChatwootCallDetectionFixture.observation(await adapter.observe())
        fixture.url += "/new-route"
        await provider.set(fixture.result)
        #expect(await adapter.observe() == .unavailable(.sourceMismatch))
        fixture.document = UUID().uuidString
        await provider.set(fixture.result)
        let newDocument = try ChatwootCallDetectionFixture.observation(await adapter.observe())
        #expect(newDocument.callToken != initial.callToken)
    }

    @Test func participantIdentifiersRotateForReconnectedCall() async throws {
        var fixture = ChatwootCallDetectionFixture()
        fixture.roster = .complete([ChatwootCallDetectionFixture.member])
        let provider = ChatwootCallDetectionFixtureProvider(fixture.result)
        let adapter = ChatwootCallDetectionAdapter(provider: provider, now: { ChatwootCallDetectionFixture.now })
        let initial = try ChatwootCallDetectionFixture.observation(await adapter.observe())
        fixture.session = UUID()
        await provider.set(fixture.result)
        let next = try ChatwootCallDetectionFixture.observation(await adapter.observe())
        #expect(next.roster != initial.roster)
        #expect(next.callToken != initial.callToken)
    }

    @Test func endedThenConnectedCannotReusePriorToken() async throws {
        var fixture = ChatwootCallDetectionFixture()
        let provider = ChatwootCallDetectionFixtureProvider(fixture.result)
        let adapter = ChatwootCallDetectionAdapter(provider: provider, now: { ChatwootCallDetectionFixture.now })
        let first = try ChatwootCallDetectionFixture.observation(await adapter.observe())
        fixture.phase = .ended
        await provider.set(fixture.result)
        _ = await adapter.observe()
        fixture.phase = .connected
        await provider.set(fixture.result)
        let next = try ChatwootCallDetectionFixture.observation(await adapter.observe())
        #expect(next.callToken != first.callToken)
    }

    @Test func rosterKnowledgeRemainsUnknownPartialOrCompleteWithoutInferredDepartures() async throws {
        var fixture = ChatwootCallDetectionFixture()
        let provider = ChatwootCallDetectionFixtureProvider(fixture.result)
        let adapter = ChatwootCallDetectionAdapter(provider: provider, now: { ChatwootCallDetectionFixture.now })
        let unknown = try ChatwootCallDetectionFixture.observation(await adapter.observe())
        #expect(unknown.roster == .unknown)
        fixture.roster = .complete([ChatwootCallDetectionFixture.member])
        await provider.set(fixture.result)
        let complete = try ChatwootCallDetectionFixture.observation(await adapter.observe())
        guard case .complete(let members) = complete.roster else { Issue.record("Expected complete"); return }
        #expect(members.count == 1)
        #expect(members.allSatisfy { UUID(uuidString: $0) != nil })
        fixture.roster = .partial([])
        await provider.set(fixture.result)
        let partial = try ChatwootCallDetectionFixture.observation(await adapter.observe())
        #expect(partial.roster == .partial([]))
        #expect(partial.callToken == complete.callToken)
        fixture.roster = .partial([ChatwootCallDetectionFixture.member])
        await provider.set(fixture.result)
        let recovered = try ChatwootCallDetectionFixture.observation(await adapter.observe())
        #expect(recovered.roster == .partial(members))
        fixture.roster = .unknown
        await provider.set(fixture.result)
        let lost = try ChatwootCallDetectionFixture.observation(await adapter.observe())
        #expect(lost.roster == .unknown)
    }

    @Test func oversizedRosterIsRejectedWithoutChangingIdentity() async throws {
        var fixture = ChatwootCallDetectionFixture()
        let provider = ChatwootCallDetectionFixtureProvider(fixture.result)
        let adapter = ChatwootCallDetectionAdapter(provider: provider, now: { ChatwootCallDetectionFixture.now })
        let first = try ChatwootCallDetectionFixture.observation(await adapter.observe())
        fixture.roster = .complete(Set((0..<257).map { _ in UUID() }))
        await provider.set(fixture.result)
        #expect(await adapter.observe() == .unavailable(.unsupported))
        fixture.roster = .unknown
        await provider.set(fixture.result)
        let restored = try ChatwootCallDetectionFixture.observation(await adapter.observe())
        #expect(restored.callToken == first.callToken)
    }

    @Test func cumulativeRosterChurnCannotGrowRetainedMembersWithoutBound() async throws {
        var fixture = ChatwootCallDetectionFixture()
        let originalMembers = Set((0..<256).map { _ in UUID() })
        fixture.roster = .complete(originalMembers)
        let provider = ChatwootCallDetectionFixtureProvider(fixture.result)
        let adapter = ChatwootCallDetectionAdapter(provider: provider, now: { ChatwootCallDetectionFixture.now })
        let first = try ChatwootCallDetectionFixture.observation(await adapter.observe())
        guard case .complete(let opaque) = first.roster else { Issue.record("Expected complete"); return }
        #expect(opaque.count == 256)
        fixture.roster = .partial([ChatwootCallDetectionFixture.member])
        await provider.set(fixture.result)
        #expect(await adapter.observe() == .unavailable(.unsupported))
        fixture.roster = .complete(originalMembers)
        await provider.set(fixture.result)
        let restored = try ChatwootCallDetectionFixture.observation(await adapter.observe())
        #expect(restored.callToken == first.callToken)
        #expect(restored.roster == first.roster)
    }

    private func detect(_ fixture: ChatwootCallDetectionFixture) async -> CallDetectionResult {
        await ChatwootCallDetectionAdapter(provider: ChatwootCallDetectionFixtureProvider(fixture.result),
                                           now: { ChatwootCallDetectionFixture.now }).observe()
    }
}

// Compiled synthetic values. They are a contract projection, never captured browser/AX data.
struct ChatwootCallDetectionFixture {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let member = UUID(uuidString: "00000000-0000-4000-8000-000000000011")!
    var bundle = "com.google.Chrome"
    var pid: Int32 = 42
    var launch = "00000000-0000-4000-8000-000000000001"
    var document = "00000000-0000-4000-8000-000000000002"
    var origin = "https://chatwoot.selfhosted.com:443"
    var url = "https://chatwoot.selfhosted.com/base/app"
    var after: CallDetectionSource?
    var urlAfter: String?
    var observedAt = Self.now
    var profile: ChatwootCallDetectionProfile = .syntheticScopedV1
    var product: ChatwootCallDetectionProductProof = .scopedChatwootProfile
    var session = UUID(uuidString: "00000000-0000-4000-8000-000000000003")!
    var kind: ChatwootCallDetectionSurfaceKind = .activeCall
    var phase: CallDetectionPhase = .connected
    var transport: ChatwootCallDetectionTransport = .remoteConnected
    var end = true
    var mute = true
    var roster: ChatwootCallDetectionRosterSnapshot = .unknown
    var surfaces: [ChatwootCallDetectionSurface]?
    var source: CallDetectionSource {
        CallDetectionSource(bundleID: bundle, processID: pid, processLaunchID: launch,
                            surfaceID: document, origin: origin)
    }
    var call: ChatwootCallDetectionSurface {
        ChatwootCallDetectionSurface(sessionID: session, kind: kind, phase: phase, transport: transport,
                                     hasEndControl: end, hasMuteControl: mute, roster: roster)
    }
    var result: ChatwootCallDetectionSnapshotResult {
        .snapshot(ChatwootCallDetectionSnapshot(sourceBefore: source, sourceAfter: after ?? source,
                                               urlBefore: url, urlAfter: urlAfter ?? url, observedAt: observedAt,
                                               profile: profile, product: product, surfaces: surfaces ?? [call]))
    }
    static func observation(_ result: CallDetectionResult) throws -> CallDetectionObservation {
        guard case .observation(let observation) = result else {
            Issue.record("Expected observation, received \(result)")
            throw FixtureError.missingObservation
        }
        return observation
    }
    enum FixtureError: Error { case missingObservation }
}

actor ChatwootCallDetectionFixtureProvider: ChatwootCallDetectionSnapshotProviding {
    private var result: ChatwootCallDetectionSnapshotResult
    private(set) var readCount = 0
    private(set) var receivedLiveDeadline = false
    init(_ result: ChatwootCallDetectionSnapshotResult) { self.result = result }
    func set(_ result: ChatwootCallDetectionSnapshotResult) { self.result = result }
    func snapshot(deadline: ContinuousClock.Instant) async -> ChatwootCallDetectionSnapshotResult {
        readCount += 1
        receivedLiveDeadline = ContinuousClock().now < deadline
        return result
    }
}
