import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("Apple SpeechAnalyzer backend")
struct AppleSpeechAnalyzerBackendTests {
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

    @Test("reservation limit releases stale app reservations and retries once")
    func reservationLimitRecoversOnce() async throws {
        let state = AppleSpeechReservationRecoveryTestState(
            failuresBeforeSuccess: 1,
            reservations: [Locale(identifier: "en-US"), Locale(identifier: "fr-FR")]
        )

        try await AppleSpeechReservationRecovery.reserve(
            maximumReservations: 2,
            operation: { try await state.reserve() },
            reservations: { state.reservations },
            release: { await state.release($0) }
        )

        #expect(await state.reservationAttemptCount == 2)
        #expect(await state.releasedIdentifiers == ["en-US", "fr-FR"])
    }

    @Test("an existing reservation is successful without cleanup")
    func existingReservationDoesNotRecover() async throws {
        let state = AppleSpeechReservationRecoveryTestState(
            failuresBeforeSuccess: 0,
            reservations: [Locale(identifier: "en-US")],
            successfulReservationResult: false
        )

        try await AppleSpeechReservationRecovery.reserve(
            maximumReservations: 1,
            operation: { try await state.reserve() },
            reservations: { state.reservations },
            release: { await state.release($0) }
        )

        #expect(await state.reservationAttemptCount == 1)
        #expect(await state.releasedIdentifiers.isEmpty)
    }

    @Test("non-capacity failures preserve reservations and do not retry")
    func nonCapacityFailureDoesNotRecover() async {
        let state = AppleSpeechReservationRecoveryTestState(
            failuresBeforeSuccess: 1,
            reservations: [Locale(identifier: "en-US")]
        )

        do {
            try await AppleSpeechReservationRecovery.reserve(
                maximumReservations: 2,
                operation: { try await state.reserve() },
                reservations: { state.reservations },
                release: { await state.release($0) }
            )
            Issue.record("Expected preparation to fail")
        } catch AppleSpeechTestError.preparationFailed {
            #expect(await state.reservationAttemptCount == 1)
            #expect(await state.releasedIdentifiers.isEmpty)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("backend is system managed and only catalogued when supported")
    func backendMetadata() {
        let option = BackendOption.appleSpeechAnalyzer

        #expect(option.backend == "apple-speech")
        #expect(option.isSystemManaged)
        #expect(option.supportsMeetingTranscription)
        #expect(!BackendOption.experimental.contains(option))
        if #available(macOS 26.0, *), AppleSpeechAnalyzerTranscriber.isSupportedOnCurrentSystem {
            #expect(BackendOption.systemManaged.contains(option))
            #expect(BackendOption.all.contains(option))
            #expect(BackendOption.onboardingDefault == option)
            #expect(BackendOption.onboarding.contains(option))
        } else {
            #expect(!BackendOption.systemManaged.contains(option))
            #expect(!BackendOption.all.contains(option))
            #expect(BackendOption.onboardingDefault == .parakeetMultilingual)
            #expect(!BackendOption.onboarding.contains(option))
        }
    }

    @Test("supported catalogue makes Apple Speech the onboarding default")
    func supportedCatalogue() {
        let catalog = BackendOption.catalog(appleSpeechAvailable: true)

        #expect(catalog.systemManaged == [.appleSpeechAnalyzer])
        #expect(catalog.all.contains(.appleSpeechAnalyzer))
        #expect(catalog.onboardingDefault == .appleSpeechAnalyzer)
        #expect(catalog.onboarding.first == .appleSpeechAnalyzer)
    }

    @Test("unsupported catalogue falls back to Parakeet")
    func unsupportedCatalogue() {
        let catalog = BackendOption.catalog(appleSpeechAvailable: false)

        #expect(catalog.systemManaged.isEmpty)
        #expect(!catalog.all.contains(.appleSpeechAnalyzer))
        #expect(catalog.onboardingDefault == .parakeetMultilingual)
        #expect(!catalog.onboarding.contains(.appleSpeechAnalyzer))
    }
}

private actor AppleSpeechTestCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

private actor AppleSpeechReservationRecoveryTestState {
    private var remainingFailures: Int
    let reservations: [Locale]
    private let successfulReservationResult: Bool
    private(set) var reservationAttemptCount = 0
    private(set) var releasedIdentifiers: [String] = []

    init(
        failuresBeforeSuccess: Int,
        reservations: [Locale],
        successfulReservationResult: Bool = true
    ) {
        remainingFailures = failuresBeforeSuccess
        self.reservations = reservations
        self.successfulReservationResult = successfulReservationResult
    }

    func reserve() throws -> Bool {
        reservationAttemptCount += 1
        if remainingFailures > 0 {
            remainingFailures -= 1
            throw AppleSpeechTestError.preparationFailed
        }
        return successfulReservationResult
    }

    func release(_ locale: Locale) -> Bool {
        releasedIdentifiers.append(locale.identifier(.bcp47))
        return true
    }
}

private enum AppleSpeechTestError: Error {
    case preparationFailed
}
