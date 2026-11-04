import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("Product analytics")
struct ProductAnalyticsTests {
    final class Recorder: @unchecked Sendable {
        let lock = NSLock()
        var events: [ProductAnalyticsEvent] = []
        var consent: String? = "initial"
        func record(_ event: ProductAnalyticsEvent) { lock.withLock { events.append(event) } }
        func token() -> String? { lock.withLock { consent } }
        func setConsent(_ value: String?) { lock.withLock { consent = value } }
    }
    @Test func concurrentFinishIsExactlyOnce() {
        let recorder = Recorder()
        let emitter = ProductAnalyticsEmitter(consent: { recorder.token() }) { event, _ in recorder.record(event) }
        let attempt = AnalyticsAttempt(.dictation, emitter: emitter)
        DispatchQueue.concurrentPerform(iterations: 100) { _ in attempt.finish(.success) }
        emitter.drain()
        #expect(recorder.events.map(\.name) == ["dictation.started", "dictation.finished"])
        #expect(recorder.events.last?.outcome == .success)
    }
    @Test func lateAttemptDoesNotLeakAcrossConsentTransitions() {
        let recorder = Recorder()
        let emitter = ProductAnalyticsEmitter(consent: { recorder.token() }) { event, _ in recorder.record(event) }
        let attempt = AnalyticsAttempt(.chat, emitter: emitter)
        emitter.drain()
        recorder.setConsent(nil)
        let disabledAttempt = AnalyticsAttempt(.quill, emitter: emitter)
        recorder.setConsent("new")
        attempt.finish(.success)
        disabledAttempt.finish(.success)
        emitter.drain()
        #expect(recorder.events.count == 1)
        #expect(recorder.events[0].name == "chat.started")
    }
    @Test func saturatedSinkDoesNotQueueUnboundedWorkOrReplayOldConsent() {
        let recorder = Recorder()
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let emitter = ProductAnalyticsEmitter(capacity: 2, consent: { recorder.token() }) { event, _ in
            entered.signal(); release.wait(); recorder.record(event)
        }
        emitter.emit(.init(feature: .search, kind: .session_finished), token: "initial")
        #expect(entered.wait(timeout: .now() + 5) == .success)
        for _ in 0..<1_000 { emitter.emit(.init(feature: .search, kind: .session_finished), token: "initial") }
        recorder.setConsent(nil)
        release.signal()
        emitter.drain()
        // One already-entered sink may finish; queued work is dropped after opt-out.
        #expect(recorder.events.count == 1)
    }
    @Test func abandonedAttemptAndNewAttemptStaySeparate() {
        let recorder = Recorder()
        let emitter = ProductAnalyticsEmitter(consent: { recorder.token() }) { event, _ in recorder.record(event) }
        do { let old = AnalyticsAttempt(.meeting, emitter: emitter); old.finish(.failed) }
        do { _ = AnalyticsAttempt(.meeting, emitter: emitter) }
        emitter.drain()
        #expect(recorder.events.filter { $0.kind == .finished }.map(\.outcome) == [.failed, .cancelled])
    }
    @Test func arbitraryModelNamesAreNeverTransmitted() {
        let secret = "https://private.example/team-project?key=secret"
        let model = AnalyticsModel(provider: secret, model: secret, providers: ["local"], models: ["public-model"])
        let event = ProductAnalyticsEvent(feature: .chat, kind: .finished, outcome: .success, model: model)
        #expect(event.parameters["provider"] == "custom")
        #expect(event.parameters["model"] == "custom")
        #expect(!event.parameters.values.contains(secret))
        #expect(Set(event.parameters.keys) == ["product.schema", "provider", "model", "outcome"])
    }
    @Test func legacySetupMigrationKeepsOnlyFiniteLifecycle() {
        let event = ProductAnalytics.migratedEvent("bridge_enable_failed")
        #expect(event?.name == "bridge.finished")
        #expect(event?.parameters == ["product.schema": "1", "outcome": "failed", "stage": "link"])
        #expect(ProductAnalytics.migratedEvent("icloud_sync_reset_completed")?.outcome == .success)
        #expect(ProductAnalytics.migratedEvent("bridge_enable_private-device-name") == nil)
    }
    @Test func fieldsAreFiniteAndCountsSaturate() {
        #expect(ProductAnalytics.bucket(0) == .zero)
        #expect(ProductAnalytics.bucket(1) == .one)
        #expect(ProductAnalytics.bucket(4) == .two_to_five)
        #expect(ProductAnalytics.bucket(17) == .six_to_twenty)
        #expect(ProductAnalytics.bucket(Int.max) == .over_twenty)
        let event = ProductAnalyticsEvent(feature: .dictation, kind: .finished, outcome: .partial,
                                          fields: [.delivery: .failed, .saved: .yes])
        #expect(event.parameters == ["product.schema": "1", "outcome": "partial", "delivery": "failed", "saved": "yes"])
    }
}
