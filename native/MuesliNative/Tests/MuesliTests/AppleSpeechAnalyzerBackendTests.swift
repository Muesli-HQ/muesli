import Foundation
import os
import Testing
@testable import MuesliNativeApp

@Suite("Apple SpeechAnalyzer backend")
struct AppleSpeechAnalyzerBackendTests {
    @Test("releasing one source keeps the shared language leased by other consumers")
    func sharedReservationLeases() {
        var leases = AppleSpeechReservationLeases()
        let mic = leases.retain(Locale(identifier: "en-IN"))
        let system = leases.retain(Locale(identifier: "en-IN"))
        let dictation = leases.retain(Locale(identifier: "fr-FR"))
        leases.release(mic)
        leases.release(mic) // Duplicate shutdown must not retire another source.
        #expect(leases.identifiers == ["en-IN", "fr-FR"])
        leases.release(system)
        #expect(leases.identifiers == ["fr-FR"])
        leases.release(dictation)
        #expect(leases.identifiers.isEmpty)
    }

    @Test("transient asset readiness failures retry and can recover")
    func transientPreparationRetries() async throws {
        let attempts = AppleSpeechTestCounter()
        try await AppleSpeechPreparationRetry.run(sleep: { _ in }) {
            await attempts.increment()
            if await attempts.value < 3 { throw AppleSpeechAnalyzerError.assetUnavailable("en-IN") }
        }
        #expect(await attempts.value == 3)
    }

    @Test("readiness retries are bounded when Apple assets remain unavailable")
    func readinessRetryBudget() async {
        let attempts = AppleSpeechTestCounter()
        do {
            try await AppleSpeechPreparationRetry.run(sleep: { _ in }) {
                await attempts.increment()
                throw AppleSpeechAnalyzerError.assetUnavailable("en-IN")
            }
            Issue.record("Expected the final readiness error")
        } catch {
            #expect(AppleSpeechPreparationRetry.isTransient(error))
        }
        #expect(await attempts.value == 3)
    }

    @Test("permanent errors and cancellation do not trigger download retries")
    func permanentPreparationDoesNotRetry() async {
        let errors: [Error] = [CancellationError(), AppleSpeechAnalyzerError.unavailable,
            AppleSpeechAnalyzerError.unsupportedLocale("zz"),
            AppleSpeechAnalyzerError.reservationUnavailable(2), AppleSpeechTestError.preparationFailed]
        for error in errors {
            let attempts = AppleSpeechTestCounter()
            do {
                try await AppleSpeechPreparationRetry.run(sleep: { _ in }) {
                    await attempts.increment()
                    throw error
                }
                Issue.record("Expected preparation to fail")
            } catch {}
            #expect(await attempts.value == 1)
        }
    }

    @Test("cancellation during backoff prevents another preparation attempt")
    func cancelledBackoffDoesNotRetry() async {
        let attempts = AppleSpeechTestCounter()
        do {
            try await AppleSpeechPreparationRetry.run(sleep: { _ in throw CancellationError() }) {
                await attempts.increment()
                throw AppleSpeechAnalyzerError.assetUnavailable("en-IN")
            }
            Issue.record("Expected cancellation")
        } catch { #expect(error is CancellationError) }
        #expect(await attempts.value == 1)
    }

    @Test("only known transient Apple and network errors retry")
    func preparationRetryClassification() {
        #expect(AppleSpeechPreparationRetry.isTransient(NSError(domain: "SFSpeechErrorDomain", code: 1)))
        #expect(AppleSpeechPreparationRetry.isTransient(NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)))
        #expect(!AppleSpeechPreparationRetry.isTransient(NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)))
        #expect(!AppleSpeechPreparationRetry.isTransient(NSError(domain: "SFSpeechErrorDomain", code: 99)))
    }

    @Test("preparation of different languages serializes reservation changes")
    func differentLanguagesPrepareSerially() async throws {
        let cache = AppleSpeechPreparationTaskCache(serializesOperations: true)
        let order = AppleSpeechPreparationOrder()
        async let first = cache.value(for: "en-IN") {
            await order.begin()
            try await Task.sleep(for: .milliseconds(30))
            await order.end()
            return Locale(identifier: "en-IN")
        }
        async let second = cache.value(for: "fr-FR") {
            await order.begin()
            try await Task.sleep(for: .milliseconds(30))
            await order.end()
            return Locale(identifier: "fr-FR")
        }
        _ = try await (first, second)
        #expect(await order.peak == 1)
    }

    @Test("a stalled language preparation does not block another language")
    func differentLanguagesPrepareIndependently() async throws {
        let cache = AppleSpeechPreparationTaskCache()
        let started = OSAllocatedUnfairLock(initialState: false)
        let released = OSAllocatedUnfairLock(initialState: false)
        let signal = MeetingStreamingSignal()
        let first = Task {
            try await cache.value(for: "en-IN") {
                started.withLock { $0 = true }
                signal.notify()
                #expect(await signal.wait(timeoutNanoseconds: 2_000_000_000) { released.withLock { $0 } })
                return Locale(identifier: "en-IN")
            }
        }
        #expect(await signal.wait(timeoutNanoseconds: 1_000_000_000) { started.withLock { $0 } })
        let second = try await cache.value(for: "fr-FR") {
            #expect(!released.withLock { $0 })
            released.withLock { $0 = true }
            signal.notify()
            return Locale(identifier: "fr-FR")
        }
        #expect(second.identifier == "fr-FR")
        _ = try await first.value
    }

    @Test("reservation reclamation protects live and dictation users plus the selected language")
    func reservationCleanupProtectsActiveUsers() {
        let releases = AppleSpeechInitialReservationPolicy.localesToRelease(
            ["en-IN", "en-US", "fr-FR", "de-DE"].map { Locale(identifier: $0) },
            keeping: Locale(identifier: "de-DE"), activeIdentifiers: ["en-IN", "fr-FR"])
        #expect(releases.map { $0.identifier(.bcp47) } == ["en-US"])
    }

    @Test("volatile results do not duplicate finalized text")
    func accumulatorIgnoresVolatileResults() {
        var accumulator = AppleSpeechTranscriptAccumulator()
        accumulator.receive(text: "draft", isFinal: false, start: 0, end: 0.5)
        accumulator.receive(text: "Final words", isFinal: true, start: 0, end: 1.25)

        #expect(accumulator.text == "Final words")
        #expect(accumulator.segments.count == 1)
        #expect(accumulator.segments[0].start == 0)
        #expect(accumulator.segments[0].end == 1.25)
    }

    @Test("progressive results replace and revoke the current live phrase")
    func accumulatorTracksProgressiveResults() {
        var accumulator = AppleSpeechTranscriptAccumulator()
        accumulator.receive(text: "今天天气", isFinal: false, start: 0, end: 0.8)
        #expect(accumulator.text == "今天天气")

        accumulator.receive(text: "今天天气很好", isFinal: false, start: 0, end: 1.2)
        #expect(accumulator.text == "今天天气很好")

        accumulator.receive(text: "", isFinal: false, start: 0, end: 1.2)
        #expect(accumulator.text.isEmpty)
    }

    @Test("progressive tail revisions preserve finalized text")
    func accumulatorPreservesFinalizedPrefix() {
        var accumulator = AppleSpeechTranscriptAccumulator()
        accumulator.receive(text: "会议开始。", isFinal: true, start: 0, end: 1)
        accumulator.receive(text: "今天讨论", isFinal: false, start: 1, end: 2)
        accumulator.receive(text: "今天讨论苹果语音。", isFinal: false, start: 1, end: 3)

        #expect(accumulator.text == "会议开始。今天讨论苹果语音。")
        #expect(accumulator.segments.map(\.text) == ["会议开始。"])
    }

    @Test("final segments are normalized and joined")
    func accumulatorBuildsTimestampedTranscript() {
        var accumulator = AppleSpeechTranscriptAccumulator()
        accumulator.receive(text: "  First segment ", isFinal: true, start: -1, end: 1)
        accumulator.receive(text: "Second segment  ", isFinal: true, start: 1, end: .infinity)

        #expect(accumulator.text == "First segment Second segment")
        #expect(accumulator.segments.map(\.text) == ["First segment", "Second segment"])
        #expect(accumulator.segments[0].start == 0)
        #expect(accumulator.segments[1].end == 1)
    }

    @Test("final results preserve Apple punctuation and line breaks")
    func accumulatorPreservesResultFormatting() {
        var accumulator = AppleSpeechTranscriptAccumulator()
        accumulator.receive(text: "Hello", isFinal: true, start: 0, end: 0.5)
        accumulator.receive(text: ",", isFinal: true, start: 0.5, end: 0.6)
        accumulator.receive(text: "\nNext line", isFinal: true, start: 0.6, end: 1.5)

        #expect(accumulator.text == "Hello,\nNext line")
        #expect(accumulator.segments.map(\.text) == ["Hello", ",", "Next line"])
    }

    @Test("live accumulation preserves final text while replacing progressive ranges")
    func liveAccumulatorReplacesProgressiveRanges() {
        var accumulator = AppleSpeechLiveTranscriptAccumulator()
        accumulator.receive(text: "会议开始。", isFinal: true, start: 0, end: 1)
        accumulator.receive(text: "今天讨论", isFinal: false, start: 1, end: 2)
        accumulator.receive(text: "今天讨论苹果语音。", isFinal: false, start: 1, end: 3)

        #expect(accumulator.text == "会议开始。今天讨论苹果语音。")
        #expect(accumulator.finalizedText == "会议开始。")
    }

    @Test("live accumulation bounds non-overlapping progressive results")
    func liveAccumulatorBoundsProgressiveResults() {
        var accumulator = AppleSpeechLiveTranscriptAccumulator()
        for index in 0..<(AppleSpeechLiveTranscriptAccumulator.maxProgressiveResults + 2) {
            accumulator.receive(
                text: "\(index)",
                isFinal: false,
                start: Double(index),
                end: Double(index) + 0.5
            )
        }

        #expect(accumulator.text == "23456789")
    }

    @Test("locale resolver uses exact or language-equivalent supported locale")
    func localeResolverUsesSupportedEquivalent() async throws {
        let exactResolver = AppleSpeechLocaleResolver { locale in
            locale.identifier(.bcp47) == "en-IN" ? locale : nil
        }
        let exact = try await exactResolver.resolve(Locale(identifier: "en-IN"))
        #expect(exact.identifier(.bcp47) == "en-IN")

        let languageResolver = AppleSpeechLocaleResolver { locale in
            locale.language.languageCode?.identifier == "en" && locale.region == nil
                ? Locale(identifier: "en-US")
                : nil
        }
        let languageEquivalent = try await languageResolver.resolve(Locale(identifier: "en-IN"))
        #expect(languageEquivalent.identifier(.bcp47) == "en-US")
    }

    @Test("locale resolver rejects unsupported languages")
    func localeResolverRejectsUnsupportedLanguage() async {
        let resolver = AppleSpeechLocaleResolver { _ in nil }

        do {
            _ = try await resolver.resolve(Locale(identifier: "zz-ZZ"))
            Issue.record("Expected an unsupported-locale error")
        } catch AppleSpeechAnalyzerError.unsupportedLocale(let identifier) {
            #expect(identifier == "zz-ZZ")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("concurrent preparation requests share one operation")
    func preparationRequestsAreCoalesced() async throws {
        let cache = AppleSpeechPreparationTaskCache()
        let counter = AppleSpeechTestCounter()

        async let first = cache.value(for: "en-US") {
            await counter.increment()
            try await Task.sleep(for: .milliseconds(100))
            return Locale(identifier: "en-US")
        }
        async let second = cache.value(for: "en-US") {
            await counter.increment()
            try await Task.sleep(for: .milliseconds(100))
            return Locale(identifier: "en-US")
        }

        let locales = try await [first, second]
        #expect(locales.allSatisfy { $0.identifier(.bcp47) == "en-US" })
        #expect(await counter.value == 1)
    }

    @Test("failed preparation is removed so a later attempt can retry")
    func failedPreparationCanRetry() async throws {
        let cache = AppleSpeechPreparationTaskCache()
        let counter = AppleSpeechTestCounter()

        do {
            _ = try await cache.value(for: "en-US") {
                await counter.increment()
                throw AppleSpeechTestError.preparationFailed
            }
            Issue.record("Expected the first preparation to fail")
        } catch AppleSpeechTestError.preparationFailed {
            // Expected path.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        let locale = try await cache.value(for: "en-US") {
            await counter.increment()
            return Locale(identifier: "en-US")
        }

        #expect(locale.identifier(.bcp47) == "en-US")
        #expect(await counter.value == 2)
    }

    @Test("language preference defaults to the system locale")
    func languagePreferenceDefaultsToSystemLocale() {
        #expect(AppleSpeechLanguageOption.normalize(nil) == AppleSpeechLanguageOption.systemIdentifier)
        #expect(AppleSpeechLanguageOption.normalize("  ") == AppleSpeechLanguageOption.systemIdentifier)
        #expect(
            AppleSpeechLanguageOption.requestedLocale(for: AppleSpeechLanguageOption.systemIdentifier)
                .identifier(.bcp47) == Locale.current.identifier(.bcp47)
        )
    }

    @Test("language preference preserves an explicit locale")
    func languagePreferencePreservesExplicitLocale() {
        #expect(AppleSpeechLanguageOption.normalize(" en-US ") == "en-US")
        #expect(
            AppleSpeechLanguageOption.requestedLocale(for: "en-US").identifier(.bcp47) == "en-US"
        )
    }

    @Test("initial reservation cleanup keeps only the selected locale")
    func initialReservationCleanupKeepsSelectedLocale() {
        let releases = AppleSpeechInitialReservationPolicy.localesToRelease(
            [Locale(identifier: "en-US"), Locale(identifier: "fr-FR"), Locale(identifier: "de-DE")],
            keeping: Locale(identifier: "fr-FR")
        )

        #expect(releases.map { $0.identifier(.bcp47) } == ["en-US", "de-DE"])
    }

    @Test("backend is system managed and only catalogued when supported")
    func backendMetadata() {
        let option = BackendOption.appleSpeechAnalyzer

        #expect(option.backend == "apple-speech")
        #expect(option.isSystemManaged)
        #expect(option.supportsMeetingTranscription)
        #expect(MeetingLiveCaptionBackend(rawValue: option.backend)?.settingsLabel == "Apple Speech (live + final)")
        #expect(MeetingLiveCaptionBackend.appleSpeech.producesFinalTranscript)
        #expect(MeetingLiveCaptionBackend.nemotron35.producesFinalTranscript)
        #expect(!MeetingLiveCaptionBackend.parakeetRealtimeEOU.producesFinalTranscript)
        #expect(!BackendOption.experimental.contains(option))
        if #available(macOS 26.0, *), AppleSpeechAnalyzerTranscriber.isSupportedOnCurrentSystem {
            #expect(BackendOption.systemManaged.contains(option))
            #expect(BackendOption.all.contains(option))
            // Parakeet Unified is the preferred onboarding model; Apple Speech
            // stays available in the catalog but is not the default.
            #expect(BackendOption.onboardingDefault == .parakeetUnified)
            #expect(!BackendOption.onboarding.contains(option))
        } else {
            #expect(!BackendOption.systemManaged.contains(option))
            #expect(!BackendOption.all.contains(option))
            #expect(BackendOption.onboardingDefault == .parakeetUnified)
            #expect(!BackendOption.onboarding.contains(option))
        }
    }

    @Test("supported catalogue keeps Apple Speech available without making it the default")
    func supportedCatalogue() {
        let catalog = BackendOption.catalog(appleSpeechAvailable: true)

        #expect(catalog.systemManaged == [.appleSpeechAnalyzer])
        #expect(catalog.all.contains(.appleSpeechAnalyzer))
        #expect(catalog.onboardingDefault == .parakeetUnified)
        #expect(catalog.onboarding.first == .parakeetUnified)
        #expect(!catalog.onboarding.contains(.appleSpeechAnalyzer))
    }

    @Test("unsupported catalogue falls back to Parakeet")
    func unsupportedCatalogue() {
        let catalog = BackendOption.catalog(appleSpeechAvailable: false)

        #expect(catalog.systemManaged.isEmpty)
        #expect(!catalog.all.contains(.appleSpeechAnalyzer))
        #expect(catalog.onboardingDefault == .parakeetUnified)
        #expect(!catalog.onboarding.contains(.appleSpeechAnalyzer))
    }
}

private actor AppleSpeechTestCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

private actor AppleSpeechPreparationOrder {
    private var active = 0
    private(set) var peak = 0
    func begin() { active += 1; peak = max(peak, active) }
    func end() { active -= 1 }
}

private enum AppleSpeechTestError: Error {
    case preparationFailed
}
