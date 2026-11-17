// swiftc -O -whole-module-optimization \
//   native/MuesliNative/Sources/MuesliNativeApp/DictationStartupWatchdog.swift \
//   scripts/benchmark_dictation_startup.swift -o /tmp/benchmark-dictation-startup
// /tmp/benchmark-dictation-startup [iterations]
//
// Measures the production watchdog's successful-start bookkeeping with real
// one-shot scheduling and off-thread telemetry formatting. Does not measure
// physical microphone startup, ASR, network delivery, or stop-to-paste latency.
import Foundation

@main
struct DictationStartupBenchmark {
    static func percentile(_ values: [Double], _ fraction: Double) -> Double {
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * fraction))]
    }

    static func main() throws {
        let iterations = max(100, CommandLine.arguments.dropFirst().first.flatMap(Int.init) ?? 5_000)
        let telemetry = DispatchQueue(label: "benchmark.startup.telemetry", qos: .utility)
        let watchdog = DictationStartupWatchdog()
        var sent = 0
        watchdog.onReport = { report in
            telemetry.async {
                precondition(report.telemetryParameters.count == 9)
                sent += 1
            }
        }
        var elapsed: [Double] = []
        for index in 0..<(iterations + 100) {
            let id = UUID() // Same session creation as before; excluded from timing.
            let start = DispatchTime.now().uptimeNanoseconds
            watchdog.begin(id)
            watchdog.phase(.selectingInput, session: id)
            watchdog.phase(.audioControls, session: id, context: .init(route: .speaker, input: .automatic))
            watchdog.phase(.configuringRecorder, session: id)
            watchdog.phase(.preparingRecorder, session: id)
            watchdog.phase(.startingRecorder, session: id)
            watchdog.startReturned(id)
            watchdog.firstBuffer(id)
            let duration = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000
            watchdog.finish(id, outcome: .stopped)
            if index >= 100 { elapsed.append(duration) }
        }
        telemetry.sync { precondition(sent == iterations + 100) }
        let output: [String: Any] = [
            "iterations": iterations,
            "scope": "added successful-start watchdog bookkeeping; microseconds",
            "median_us": percentile(elapsed, 0.5), "p95_us": percentile(elapsed, 0.95),
            "p99_us": percentile(elapsed, 0.99)
        ]
        print(String(decoding: try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
    }
}
