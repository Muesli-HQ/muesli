// Standalone synthetic IO/routing for benchmark_dictation_pipeline.sh. Production
// manager, AppScoped recorder, and RouteAware recorder are compiled unmodified.
import CoreAudio
import Foundation

enum AudioOutputRouteKind { case speakerLike, headphoneLike, unknown }
protocol AudioDuckingManaging: AnyObject {
    func beginDictationDucking(enabled: Bool)
    func ensureCurrentDefaultDucked()
    func restoreDictationDucking(completion: (() -> Void)?)
}
extension AudioDuckingManaging { func restoreDictationDucking() { restoreDictationDucking(completion: nil) } }
protocol MediaPlaybackManaging: AnyObject {
    func beginDictationMediaPause(enabled: Bool, routeKind: AudioOutputRouteKind)
    func restoreDictationMediaPause()
}
final class MediaPlaybackController: MediaPlaybackManaging, AudioDuckingManaging {
    func beginDictationMediaPause(enabled: Bool, routeKind: AudioOutputRouteKind) {}
    func restoreDictationMediaPause() {}
    func beginDictationDucking(enabled: Bool) {}
    func ensureCurrentDefaultDucked() {}
    func restoreDictationDucking(completion: (() -> Void)?) { completion?() }
}
protocol DictationAudioRouting: AnyObject {
    func preferredInputDeviceIDForDictation() -> AudioObjectID?
    func cachedPreferredInputDeviceIDForDictation() -> AudioObjectID?
    func currentOutputRouteKindForDebug() -> AudioOutputRouteKind
    func currentRouteDebugDescription() -> String
    func systemDefaultInputIsBuiltInForDictation() -> Bool
    func refreshRouteAfterDictationSession()
    func refreshRouteCache()
}
final class BenchmarkRouting: DictationAudioRouting {
    func preferredInputDeviceIDForDictation() -> AudioObjectID? { nil }
    func cachedPreferredInputDeviceIDForDictation() -> AudioObjectID? { nil }
    func currentOutputRouteKindForDebug() -> AudioOutputRouteKind { .speakerLike }
    func currentRouteDebugDescription() -> String { "synthetic" }
    func systemDefaultInputIsBuiltInForDictation() -> Bool { true }
    func refreshRouteAfterDictationSession() {}
    func refreshRouteCache() {}
}
protocol StreamingDictationRecording: AnyObject {
    var onAudioBuffer: (([Float]) -> Void)? { get set }
    var onRecordingFailed: ((Error) -> Void)? { get set }
    var preferredInputDeviceID: AudioObjectID? { get set }
    func prepare() throws
    func start() throws
    func stop() -> URL?
    func cancel()
    func currentPower() -> Float
}
protocol StreamingDictationLatencyReporting: AnyObject { var onLatencyEvent: ((String, Date) -> Void)? { get set } }
class BenchmarkInput: StreamingDictationRecording {
    var onAudioBuffer: (([Float]) -> Void)?
    var onRecordingFailed: ((Error) -> Void)?
    var preferredInputDeviceID: AudioObjectID?
    let samples = Array(repeating: Float(0.1), count: 512)
    func prepare() throws {}
    func start() throws { emit() }
    func stop() -> URL? { emit(); return nil }
    func cancel() {}
    func currentPower() -> Float { -20 }
    func emit() { onAudioBuffer?(samples) }
}
// Resolve unused production default argument constructors without opening hardware.
final class AudioQueueInputRecorder: BenchmarkInput { init(directoryName: String) { super.init() } }
final class StreamingMicRecorder: BenchmarkInput { init(directoryName: String) { super.init() } }
final class FallbackStreamingDictationRecorder: BenchmarkInput {
    init(primary: StreamingDictationRecording, fallback: StreamingDictationRecording) { super.init() }
}
final class MicrophoneRecorder {
    var preferredInputDeviceID: AudioObjectID?
    var keepsAudioGraphWarm = false
    var onFirstCapturedAudioBuffer: ((Date) -> Void)?
    var onFirstSpeechDetected: ((Date) -> Void)?
    var onNoAudioTimeout: ((Date) -> Void)?
    var onRecordingFailed: ((Error, UUID) -> Void)?
    var onLatencyEvent: ((String, Date) -> Void)?
    func prepare() throws {}
    func beginExplicitWarmup(preferredInputDeviceID: AudioObjectID?) {}
    func warmUp(preferredInputDeviceID: AudioObjectID?) throws {}
    func activateWarmEngine(preferredInputDeviceID: AudioObjectID?) throws {}
    func coolDown() {}
    func start() throws -> UUID { UUID() }
    func stop() -> URL? { nil }
    func cancel() {}
    func currentPower() -> Float { -20 }
}

private final class BenchmarkMeasurements: @unchecked Sendable {
    private let lock = NSLock()
    var start: UInt64 = 0
    var stop: UInt64 = 0
    private var first = true
    private(set) var startupUS: [Double] = []
    private(set) var stopUS: [Double] = []
    private var receivedSamples = 0
    let ready = DispatchSemaphore(value: 0)
    let stopped = DispatchSemaphore(value: 0)
    func arm() { lock.withLock { first = true; start = DispatchTime.now().uptimeNanoseconds } }
    func receive(_ samples: [Float]) {
        lock.withLock {
            receivedSamples += samples.count
            if first {
                first = false
                startupUS.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000)
                ready.signal()
            }
        }
    }
    func event(_ event: DictationAudioSessionEvent) {
        if case .stopped = event {
            lock.withLock { stopUS.append(Double(DispatchTime.now().uptimeNanoseconds - stop) / 1_000) }
            stopped.signal()
        }
        if case .failed = event { fatalError("Synthetic microphone unexpectedly failed") }
    }
    func assertSampleCount(_ expected: Int) { precondition(lock.withLock { receivedSamples == expected }) }
}

#if WATCHDOG_CANDIDATE
private final class BenchmarkTelemetry: @unchecked Sendable {
    private let lock = NSLock()
    private let arrived = DispatchSemaphore(value: 0)
    private var checksum = 0
    // Consume all formatted values so optimization cannot erase the formatter.
    @inline(never) func consume(_ parameters: [String: String]) {
        precondition(parameters.count >= 8)
        let size = parameters.reduce(0) { $0 + $1.key.utf8.count + $1.value.utf8.count }
        lock.withLock { checksum += size }
        arrived.signal()
    }
    func drain(_ count: Int) {
        for _ in 0..<count { precondition(arrived.wait(timeout: .now() + 5) == .success) }
        precondition(lock.withLock { checksum > 0 })
    }
}
#endif

@main
struct DictationPipelineBenchmark {
    static func distribution(_ values: [Double]) -> [String: Double] {
        let sorted = values.sorted()
        func p(_ fraction: Double) -> Double { sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * fraction))] }
        return ["median_us": p(0.5), "p95_us": p(0.95), "p99_us": p(0.99)]
    }
    static func main() throws {
        let iterations = max(100, CommandLine.arguments.dropFirst().first.flatMap(Int.init) ?? 1_000)
        let warmups = 100, batch = 32
        let input = BenchmarkInput()
        let recorder = RouteAwareDictationRecorder(systemDefaultRecorder: AppScopedDictationRecorder(recorder: input),
            appScopedRecorder: AppScopedDictationRecorder(recorder: BenchmarkInput()))
        let controls = MediaPlaybackController()
        let events = DispatchQueue(label: "benchmark.events")
        let measurements = BenchmarkMeasurements()
        #if WATCHDOG_CANDIDATE
        let telemetry = BenchmarkTelemetry()
        #if CAPTURE_HEALTH_CANDIDATE
        let healthQueue = DispatchQueue(label: "benchmark.input-health")
        var native = CoreAudioDictationInputObserver.NativeOperations()
        native.read = { _, selector in selector == kAudioHardwarePropertyDefaultInputDevice ? 42 : 1 }
        native.add = { _, _, _, _ in true }
        native.remove = { _, _, _, _ in }
        let health = CoreAudioDictationInputObserver(queue: healthQueue, native: native)
        #endif
        #if CAPTURE_HEALTH_CANDIDATE
        let manager = DictationAudioSessionManager(recorder: recorder, duckingController: controls,
            mediaPlaybackController: controls, routingController: BenchmarkRouting(), eventQueue: events,
            inputObserver: health,
            startupTelemetry: { report in telemetry.consume(report.telemetryParameters) })
        #else
        let manager = DictationAudioSessionManager(recorder: recorder, duckingController: controls,
            mediaPlaybackController: controls, routingController: BenchmarkRouting(), eventQueue: events,
            startupTelemetry: { report in telemetry.consume(report.telemetryParameters) })
        #endif
        #else
        let manager = DictationAudioSessionManager(recorder: recorder, duckingController: controls,
            mediaPlaybackController: controls, routingController: BenchmarkRouting(), eventQueue: events)
        #endif
        manager.onAudioBuffer = { measurements.receive($0) }
        manager.onEvent = { measurements.event($0) }
        var buffers: [Double] = []
        for index in 0..<(iterations + warmups) {
            measurements.arm()
            manager.beginRecording(mode: "benchmark", duckingEnabled: false, mediaPauseEnabled: false)
            precondition(measurements.ready.wait(timeout: .now() + 5) == .success)
            // First-buffer acknowledgment does not wait for decoder/model work.
            let start = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<batch { input.emit() }
            let duration = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000 / Double(batch)
            if index >= warmups { buffers.append(duration) }
            measurements.stop = DispatchTime.now().uptimeNanoseconds
            manager.stop()
            precondition(measurements.stopped.wait(timeout: .now() + 5) == .success)
        }
        events.sync {}
        #if CAPTURE_HEALTH_CANDIDATE
        healthQueue.sync {}
        #endif
        #if WATCHDOG_CANDIDATE
        telemetry.drain(iterations + warmups)
        #endif
        measurements.assertSampleCount((iterations + warmups) * (batch + 2) * 512)
        let result: [String: Any] = ["iterations": iterations,
            "scope": "synthetic microphone; real recorder layers; no ASR/network/editor",
            "request_to_first_audio": distribution(Array(measurements.startupUS.dropFirst(warmups))),
            "per_512_sample_buffer": distribution(buffers),
            "stop_to_event": distribution(Array(measurements.stopUS.dropFirst(warmups)))]
        print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
    }
}
