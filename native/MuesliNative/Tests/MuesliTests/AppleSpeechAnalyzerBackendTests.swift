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

private enum AppleSpeechTestError: Error {
    case preparationFailed
}
