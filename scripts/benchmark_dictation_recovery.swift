// Build from the repository root:
// swiftc -O -whole-module-optimization \
//   native/MuesliNative/Sources/MuesliNativeApp/DictationRecordingCleanup.swift \
//   scripts/benchmark_dictation_recovery.swift -o /tmp/benchmark-dictation-recovery
// /tmp/benchmark-dictation-recovery [iterations]
//
// Measures the only changed successful-path operation against the previous
// direct WAV deletion. This is a paired file-lifecycle benchmark, not an ASR,
// microphone, or stop-to-paste latency measurement. Fixture setup is not timed.
import Foundation

@main
struct DictationRecoveryBenchmark {
    @inline(never)
    static func baseline(_ audio: URL) {
        try? FileManager.default.removeItem(at: audio)
    }

    @inline(never)
    static func candidate(_ audio: URL) {
        DictationRecordingCleanup(wavURL: audio).finish()
    }

    static func elapsed(_ operation: () -> Void) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        operation()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000
    }

    static func percentile(_ values: [Double], _ fraction: Double) -> Double {
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * fraction))]
    }

    static func main() throws {
        let iterations = max(100, CommandLine.arguments.dropFirst().first.flatMap(Int.init) ?? 500)
        let files = FileManager.default
        let directory = files.temporaryDirectory.appendingPathComponent("dictation-recovery-benchmark-\(UUID().uuidString)")
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: directory) }
        let fixture = directory.appendingPathComponent("fixture.wav")
        // Same byte count as 60 seconds of the recorder's 16 kHz mono PCM16 WAV.
        try Data(repeating: 0, count: 44 + 60 * 16_000 * 2).write(to: fixture)
        let first = directory.appendingPathComponent("baseline.wav")
        let second = directory.appendingPathComponent("candidate.wav")
        var before: [Double] = []
        var after: [Double] = []
        for index in 0..<(iterations + 50) {
            try files.copyItem(at: fixture, to: first)
            try files.copyItem(at: fixture, to: second)
            let a: Double
            let b: Double
            if index.isMultiple(of: 2) {
                a = elapsed { baseline(first) }
                b = elapsed { candidate(second) }
            } else {
                b = elapsed { candidate(second) }
                a = elapsed { baseline(first) }
            }
            precondition(!files.fileExists(atPath: first.path) && !files.fileExists(atPath: second.path))
            if index >= 50 { before.append(a); after.append(b) }
        }
        let paired = zip(before, after).map { $1 - $0 }
        let result: [String: Any] = [
            "iterations": iterations,
            "baseline_median_us": percentile(before, 0.5),
            "candidate_median_us": percentile(after, 0.5),
            "baseline_p95_us": percentile(before, 0.95),
            "candidate_p95_us": percentile(after, 0.95),
            "paired_median_delta_us": percentile(paired, 0.5),
            "paired_p95_delta_us": percentile(paired, 0.95),
        ]
        print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
    }
}
