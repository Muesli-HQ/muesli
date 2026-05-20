import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("MeetingNeuralAec")
struct MeetingNeuralAecTests {

    @Test("bundle candidates prefer Contents/Resources in packaged apps")
    func candidateURLsPreferResourceDirectory() throws {
        let fixture = try makeTemporaryAppBundle()
        defer { fixture.cleanup() }
        let appBundle = fixture.bundle
        let candidates = MeetingAecModelBundle.candidateURLs(mainBundle: appBundle)

        #expect(candidates.count >= 2)
        #expect(candidates[0].path == appBundle.resourceURL?
            .appendingPathComponent(MeetingAecModelBundle.bundleName, isDirectory: true).path)
        #expect(candidates[1].path == appBundle.bundleURL
            .appendingPathComponent(MeetingAecModelBundle.bundleName, isDirectory: true).path)
    }

    @Test("resolver loads packaged app bundle from Contents/Resources")
    func resolverLoadsResourceBundle() throws {
        let fixture = try makeTemporaryAppBundle()
        defer { fixture.cleanup() }
        let appBundle = fixture.bundle
        let resourceBundleURL = try createResourceBundle(
            at: appBundle.resourceURL!.appendingPathComponent(MeetingAecModelBundle.bundleName, isDirectory: true)
        )

        let resolved = try MeetingAecModelBundle.resolve(mainBundle: appBundle)

        #expect(resolved.bundleURL.standardizedFileURL == resourceBundleURL.standardizedFileURL)
    }

    @Test("resolver falls back to app-root bundle when needed")
    func resolverFallsBackToBundleRoot() throws {
        let fixture = try makeTemporaryAppBundle()
        defer { fixture.cleanup() }
        let appBundle = fixture.bundle
        let rootBundleURL = try createResourceBundle(
            at: appBundle.bundleURL.appendingPathComponent(MeetingAecModelBundle.bundleName, isDirectory: true)
        )

        let resolved = try MeetingAecModelBundle.resolve(mainBundle: appBundle)

        #expect(resolved.bundleURL.standardizedFileURL == rootBundleURL.standardizedFileURL)
    }

    @Test("delay estimator finds delayed mic echo")
    func delayEstimatorFindsDelayedMicEcho() throws {
        let estimator = MeetingAecDelayEstimator()
        let delaySamples = 3_840 // 240ms at 16kHz
        let sampleCount = estimator.windowSamples + estimator.maxCandidateDelaySamples + 4_000
        var system = [Float](repeating: 0, count: sampleCount)
        var mic = [Float](repeating: 0, count: sampleCount)

        for start in stride(from: 4_000, to: estimator.windowSamples - 8_000, by: 12_000) {
            for offset in 0..<3_200 {
                let value = Float(sin(Double(offset) * 0.04)) * 0.25
                system[start + offset] = value
                mic[start + delaySamples + offset] += value * 0.55
            }
        }

        let result = try #require(estimator.estimate(
            micHistory: mic,
            micHistoryStartSample: 0,
            systemHistory: system,
            systemHistoryStartSample: 0,
            comparableEndSample: estimator.windowSamples
        ))

        #expect(result.delayMs == 240)
        #expect(result.score > 0.9)
    }

    @Test("delay estimator median smooths recent estimates")
    func delayEstimatorMedianSmoothsRecentEstimates() {
        #expect(MeetingAecDelayEstimator.recencyWeightedMedianDelay(from: [
            makeDelayResult(delayMs: 0),
            makeDelayResult(delayMs: 240),
            makeDelayResult(delayMs: 240),
        ]) == 3_840)
        #expect(MeetingAecDelayEstimator.recencyWeightedMedianDelay(from: [
            makeDelayResult(delayMs: 80),
            makeDelayResult(delayMs: 80),
            makeDelayResult(delayMs: 400),
        ]) == 6_400)
    }

    @Test("delay estimator exposes finer shared candidate grid")
    func delayEstimatorCandidateGridIncludesFineRange() {
        let candidates = MeetingAecDelayEstimator.defaultCandidateDelaysMs
        #expect(candidates.contains(360))
        #expect(candidates.contains(400))
        #expect(candidates.contains(440))
        #expect(candidates.contains(480))
        #expect(candidates.contains(520))
        #expect(candidates.contains(560))
        #expect(candidates.contains(600))
    }

    @Test("delay estimator reports missing mic candidate windows")
    func delayEstimatorReportsMissingMicCandidateWindows() throws {
        let estimator = MeetingAecDelayEstimator()
        let sampleCount = estimator.windowSamples + estimator.maxCandidateDelaySamples + 4_000
        var system = [Float](repeating: 0, count: sampleCount)
        let mic = [Float](repeating: 0, count: sampleCount)

        for offset in 0..<3_200 {
            system[4_000 + offset] = 0.25
        }

        let attempt = estimator.estimateAttempt(
            micHistory: Array(mic.suffix(1_000)),
            micHistoryStartSample: sampleCount - 1_000,
            systemHistory: system,
            systemHistoryStartSample: 0,
            comparableEndSample: estimator.windowSamples
        )

        guard case let .failure(failure) = attempt else {
            Issue.record("Expected missing mic candidate windows failure")
            return
        }
        #expect(failure.reason == "missingMicCandidateWindows")
        #expect(failure.missingCandidateCount == estimator.candidateDelaysMs.count)
    }

    private func makeTemporaryAppBundle() throws -> TemporaryAppBundle {
        let appURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-aec-\(UUID().uuidString)", isDirectory: true)
            .appendingPathExtension("app")
        let contentsURL = appURL.appendingPathComponent("Contents", isDirectory: true)
        let macOSURL = contentsURL.appendingPathComponent("MacOS", isDirectory: true)
        let resourcesURL = contentsURL.appendingPathComponent("Resources", isDirectory: true)

        try FileManager.default.createDirectory(at: macOSURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: resourcesURL, withIntermediateDirectories: true)
        try Data().write(to: macOSURL.appendingPathComponent("TestApp"))

        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>CFBundlePackageType</key>
          <string>APPL</string>
          <key>CFBundleExecutable</key>
          <string>TestApp</string>
          <key>CFBundleIdentifier</key>
          <string>com.muesli.tests.MeetingAec</string>
          <key>CFBundleName</key>
          <string>TestApp</string>
        </dict>
        </plist>
        """
        try plist.write(to: contentsURL.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)

        let bundle = try #require(Bundle(url: appURL))
        return TemporaryAppBundle(url: appURL, bundle: bundle)
    }

    private func createResourceBundle(at url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try "{}".write(to: url.appendingPathComponent("Manifest.json"), atomically: true, encoding: .utf8)
        return url
    }

    private func makeDelayResult(delayMs: Int) -> MeetingAecDelayEstimator.Result {
        let delaySamples = Int(round(Double(delayMs) * 16_000.0 / 1_000.0))
        return MeetingAecDelayEstimator.Result(
            delaySamples: delaySamples,
            delayMs: delayMs,
            score: 0.8,
            confidence: 0.01,
            comparedFrames: 100,
            candidateScores: [
                MeetingAecDelayCandidateScore(delayMs: delayMs, score: 0.8, comparedFrames: 100)
            ]
        )
    }
}

private struct TemporaryAppBundle {
    let url: URL
    let bundle: Bundle

    func cleanup() {
        try? FileManager.default.removeItem(at: url)
    }
}
