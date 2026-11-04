// Compile the actual production ProductAnalytics.swift with this file using
// swiftc -O -whole-module-optimization. The SDK symbol stand-in below is unused:
// every measured emitter has an injected sink. No app data/network/audio is used.
// Measures caller overhead, including ownership, queue admission and consent;
// not physical microphone, model inference, networking or an external editor.
import Foundation

enum MuesliTelemetry {
    struct Gate { var consentToken: String? { nil } }
    static let privacy = Gate()
    static func sendProductEvent(_ event: ProductAnalyticsEvent, token: String) { fatalError("Use injected sink") }
}

@main struct ProductAnalyticsBenchmark {
    final class Counter: @unchecked Sendable {
        let lock = NSLock()
        var value = 0
        func consume(_ event: ProductAnalyticsEvent) { lock.withLock { value += event.parameters.count } }
    }
    final class Consent: @unchecked Sendable {
        let lock = NSLock()
        var value: String?
        init(_ value: String?) { self.value = value }
        func read() -> String? { lock.withLock { value } }
    }
    static func percentile(_ samples: [Double], _ fraction: Double) -> Double {
        let sorted = samples.sorted()
        return sorted[Int(Double(sorted.count - 1) * fraction)]
    }
    static func main() throws {
        let iterations = Int(CommandLine.arguments.dropFirst().first ?? "5000") ?? 5000
        var rows: [[String: Any]] = []
        for round in 1...3 {
            let modes = round == 2 ? ["backlog", "enabled", "disabled", "baseline"] : ["baseline", "disabled", "enabled", "backlog"]
            for mode in modes {
                let counter = Counter()
                let release = DispatchSemaphore(value: 0), entered = DispatchSemaphore(value: 0)
                let consent = Consent(mode == "disabled" ? nil : "allowed")
                let emitter = ProductAnalyticsEmitter(consent: { consent.read() }) { event, _ in
                    if mode == "backlog", event.feature == .search { entered.signal(); release.wait() }
                    counter.consume(event)
                }
                if mode == "backlog" {
                    emitter.emit(.init(feature: .search, kind: .session_finished), token: "allowed")
                    precondition(entered.wait(timeout: .now() + 5) == .success)
                }
                var startSamples: [Double] = [], finishSamples: [Double] = []
                for index in 0..<(iterations + 100) {
                    let start = DispatchTime.now().uptimeNanoseconds
                    let attempt = mode == "baseline" ? nil : AnalyticsAttempt(.dictation,
                        fields: [.mode: .hold, .cleanup: .no], emitter: emitter)
                    let ready = DispatchTime.now().uptimeNanoseconds
                    attempt?.finish(.success, fields: [.delivery: .success, .saved: .yes])
                    let done = DispatchTime.now().uptimeNanoseconds
                    if index >= 100 {
                        startSamples.append(Double(ready - start) / 1_000)
                        finishSamples.append(Double(done - ready) / 1_000)
                    }
                    // Outside measurement: keep normal mode representative of human
                    // operation rates, and deliberately leave offline backlog saturated.
                    if mode != "backlog" { emitter.drain() }
                }
                if mode == "backlog" { release.signal() }
                emitter.drain()
                rows.append(["round": round, "mode": mode, "iterations": iterations,
                    "start_median_us": percentile(startSamples, 0.5), "start_p95_us": percentile(startSamples, 0.95),
                    "finish_median_us": percentile(finishSamples, 0.5), "finish_p95_us": percentile(finishSamples, 0.95),
                    "sink_field_count": counter.value])
            }
        }
        let data = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
