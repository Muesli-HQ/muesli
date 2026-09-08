import AppKit
import MuesliCore

/// Actual app startup logic, called by the thin @main shell in the
/// MuesliNativeAppShell executable target. AppDelegate and the rest of the app
/// live in the MuesliNativeApp library so the executable can stay a minimal shell
/// that Xcode can wrap as a real Application product.
@MainActor
public enum MuesliAppEntry {
    public static func run() {
        // Exercise the actual actor preparation path, including scheduled warmup.
        if #available(macOS 15, *), ProcessInfo.processInfo.environment["MUESLI_BODHAN_PREPARE_BENCH"] == "1",
           let audio = ProcessInfo.processInfo.environment["MUESLI_BODHAN_BENCH_AUDIO"],
           let output = ProcessInfo.processInfo.environment["MUESLI_BODHAN_BENCH_OUTPUT"] {
            Task.detached {
                do {
                    let transcriber = IndicASRTranscriber()
                    let model = ProcessInfo.processInfo.environment["MUESLI_BODHAN_BENCH_MODEL"] ?? BodhanModel.flex.rawValue
                    let start = Date()
                    try await transcriber.prepare(modelID: model, progress: { _, status in
                        if let status { fputs("[bodhan-prepare-check] \(status)\n", stderr) }
                    })
                    var rows: [[String: Any]] = []
                    for _ in 0..<2 {
                        let call = Date()
                        let result = try await transcriber.transcribe(wavURL: URL(fileURLWithPath: audio), modelID: model, language: .automatic)
                        rows.append(["text": result.text, "processingSeconds": result.processingTime,
                                     "callSeconds": Date().timeIntervalSince(call)])
                    }
                    let report: [String: Any] = ["runs": rows, "prepareAndRunSeconds": Date().timeIntervalSince(start)]
                    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                        .write(to: URL(fileURLWithPath: output), options: .atomic)
                    await transcriber.shutdown()
                    exit(0)
                } catch {
                    fputs("Bodhan preparation benchmark failed: \(error)\n", stderr)
                    exit(1)
                }
            }
            dispatchMain()
        }
        if #available(macOS 15, *), let root = ProcessInfo.processInfo.environment["MUESLI_BODHAN_BENCH_ROOT"],
           let audio = ProcessInfo.processInfo.environment["MUESLI_BODHAN_BENCH_AUDIO"],
           let output = ProcessInfo.processInfo.environment["MUESLI_BODHAN_BENCH_OUTPUT"] {
            do {
                let runtime = try BodhanCoreML(root: URL(fileURLWithPath: root))
                let data = try Data(contentsOf: URL(fileURLWithPath: audio))
                guard data.count % 4 == 0 else { throw CocoaError(.fileReadCorruptFile) }
                let samples = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
                var results: [BodhanCoreML.Result] = []
                try runtime.warmupEncoderShapes()
                let lengths = ProcessInfo.processInfo.environment["MUESLI_BODHAN_BENCH_LENGTHS"]?
                    .split(separator: ",").compactMap { Double($0) } ?? []
                for index in 0..<(lengths.isEmpty ? 3 : lengths.count) {
                    let input = lengths.isEmpty ? samples : Array(samples.prefix(Int(lengths[index]*16000)))
                    results.append(try runtime.transcribe(samples: input, language: "hi",
                        mixedScript: ProcessInfo.processInfo.environment["MUESLI_BODHAN_BENCH_MIXED"] == "1"))
                }
                try JSONEncoder().encode(results).write(to: URL(fileURLWithPath: output), options: .atomic)
            } catch {
                fputs("Bodhan benchmark failed: \(error)\n", stderr)
                exit(1)
            }
            return
        }
        let application = NSApplication.shared
        let appDelegate = AppDelegate()
        application.delegate = appDelegate
        application.setActivationPolicy(.accessory)
        _ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
    }
}
