import Foundation
import MuesliCore

/// Version of the C ABI this bridge implements. Windows must reject an
/// incompatible bridge rather than risk corrupting data.
public let muesliCoreBridgeABIVersion: UInt32 = 1

/// Capability bits reported by `muesli_core_bridge_capabilities`. Consumers must
/// check these rather than assuming every bridge of the same filename exposes
/// the newer exports.
public enum MuesliBridgeCapabilities {
    /// `open`/`close`/`insert_dictation`/`recent_dictations`.
    public static let persistence: UInt32 = 1 << 0
    /// Stateless `normalize_transcript` and `text_metrics`.
    public static let textProcessing: UInt32 = 1 << 1
    public static let all: UInt32 = persistence | textProcessing
}

/// Deterministic status codes returned across the ABI. No Swift error crosses.
public enum MuesliBridgeCode: Int32 {
    case ok = 0
    case invalidArgument = 1
    case invalidHandle = 2
    case invalidUTF8 = 3
    case invalidJSON = 4
    case bufferTooSmall = 5
    case storeError = 6
    case ioError = 7
    case unsupportedVersion = 8
    case unknown = 255
}

/// Opaque store box. The pointer handed to C# is the unmanaged address of this
/// object; C# never interprets it and must return it via `close`.
private final class BridgeStore {
    let store: DictationStore
    let lock = NSLock()
    init(store: DictationStore) { self.store = store }
}

// MARK: - Last error (per calling thread)

private let bridgeLastErrorKey = "muesli.core.bridge.lastError"

private func recordLastError(_ code: MuesliBridgeCode, _ message: String) {
    Thread.current.threadDictionary[bridgeLastErrorKey] =
        "{\"code\":\(code.rawValue),\"message\":\(jsonEscape(message))}"
}

private func clearLastError() {
    Thread.current.threadDictionary.removeObject(forKey: bridgeLastErrorKey)
}

// MARK: - Buffer helpers (caller-owned buffers)

@inline(__always)
private func writeOutput(
    _ data: Data,
    to output: UnsafeMutablePointer<UInt8>?,
    capacity: Int32,
    written: UnsafeMutablePointer<Int32>?
) -> Int32 {
    written?.pointee = Int32(data.count)
    if data.isEmpty { return MuesliBridgeCode.ok.rawValue }
    guard let output, capacity >= Int32(data.count) else {
        return MuesliBridgeCode.bufferTooSmall.rawValue
    }
    data.withUnsafeBytes { source in
        guard let base = source.baseAddress else { return }
        output.update(from: base.assumingMemoryBound(to: UInt8.self), count: data.count)
    }
    return MuesliBridgeCode.ok.rawValue
}

private func decodeUTF8(_ pointer: UnsafePointer<UInt8>?, length: Int32) -> String? {
    guard let pointer, length >= 0 else { return nil }
    let buffer = UnsafeBufferPointer(start: pointer, count: Int(length))
    guard let string = String(bytes: buffer, encoding: .utf8) else { return nil }
    return string
}

/// Null pointer with zero length is the empty string; anything else must be
/// valid UTF-8. Used by the stateless text functions, where empty input is legal.
private func decodeUTF8OrEmpty(_ pointer: UnsafePointer<UInt8>?, length: Int32) -> String? {
    guard length >= 0 else { return nil }
    if pointer == nil { return length == 0 ? "" : nil }
    return decodeUTF8(pointer, length: length)
}

private let iso8601Formatter = ISO8601DateFormatter()
private let iso8601FormatterLock = NSLock()

private func parseISODate(_ value: String?) -> Date? {
    guard let value, !value.isEmpty else { return nil }
    iso8601FormatterLock.lock()
    defer { iso8601FormatterLock.unlock() }
    if let date = iso8601Formatter.date(from: value) { return date }
    iso8601Formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let date = iso8601Formatter.date(from: value)
    iso8601Formatter.formatOptions = [.withInternetDateTime]
    return date
}

// MARK: - ABI

@_cdecl("muesli_core_bridge_abi_version")
public func muesli_core_bridge_abi_version() -> UInt32 {
    muesliCoreBridgeABIVersion
}

/// Capability bitset for this bridge build.
@_cdecl("muesli_core_bridge_capabilities")
public func muesli_core_bridge_capabilities() -> UInt32 {
    MuesliBridgeCapabilities.all
}

/// Stateless transcript normalization. Caller owns the output buffer; on an
/// undersized buffer the function returns `bufferTooSmall` and reports the
/// required byte count through `written`.
@_cdecl("muesli_core_bridge_normalize_transcript")
public func muesli_core_bridge_normalize_transcript(
    _ input: UnsafePointer<UInt8>?,
    _ inputLength: Int32,
    _ output: UnsafeMutablePointer<UInt8>?,
    _ outputCapacity: Int32,
    _ written: UnsafeMutablePointer<Int32>?
) -> Int32 {
    clearLastError()
    guard let text = decodeUTF8OrEmpty(input, length: inputLength) else {
        recordLastError(.invalidUTF8, "transcript must be valid UTF-8")
        return MuesliBridgeCode.invalidUTF8.rawValue
    }
    let normalized = MuesliTextProcessing.normalizeTranscript(text)
    return writeOutput(Data(normalized.utf8), to: output, capacity: outputCapacity, written: written)
}

/// Stateless canonical word count. Returns the count (>= 0), or `-1` when the
/// input is not valid UTF-8. No buffers are involved, so this is the cheap path
/// for per-row metric reads.
@_cdecl("muesli_core_bridge_word_count")
public func muesli_core_bridge_word_count(
    _ input: UnsafePointer<UInt8>?,
    _ inputLength: Int32
) -> Int32 {
    clearLastError()
    guard let text = decodeUTF8OrEmpty(input, length: inputLength) else {
        recordLastError(.invalidUTF8, "transcript must be valid UTF-8")
        return -1
    }
    return Int32(min(MuesliTextProcessing.wordCount(in: text), Int(Int32.max)))
}

/// Stateless text metrics as versioned UTF-8 JSON. Caller owns the output buffer.
@_cdecl("muesli_core_bridge_text_metrics")
public func muesli_core_bridge_text_metrics(
    _ input: UnsafePointer<UInt8>?,
    _ inputLength: Int32,
    _ output: UnsafeMutablePointer<UInt8>?,
    _ outputCapacity: Int32,
    _ written: UnsafeMutablePointer<Int32>?
) -> Int32 {
    clearLastError()
    guard let text = decodeUTF8OrEmpty(input, length: inputLength) else {
        recordLastError(.invalidUTF8, "transcript must be valid UTF-8")
        return MuesliBridgeCode.invalidUTF8.rawValue
    }
    let metrics = BridgeTextMetrics(version: 1, wordCount: MuesliTextProcessing.wordCount(in: text))
    guard let data = try? JSONEncoder().encode(metrics) else {
        recordLastError(.unknown, "failed to encode text metrics")
        return MuesliBridgeCode.unknown.rawValue
    }
    return writeOutput(data, to: output, capacity: outputCapacity, written: written)
}

/// Opens (or creates) a Swift-schema dictation store at the caller-provided path.
/// The bridge never chooses a location. `outHandle` receives an opaque handle.
@_cdecl("muesli_core_bridge_open")
public func muesli_core_bridge_open(
    _ pathUtf8: UnsafePointer<UInt8>?,
    _ pathLength: Int32,
    _ outHandle: UnsafeMutablePointer<OpaquePointer?>?
) -> Int32 {
    clearLastError()
    guard let outHandle else {
        recordLastError(.invalidArgument, "outHandle must not be null")
        return MuesliBridgeCode.invalidArgument.rawValue
    }
    outHandle.pointee = nil
    guard let path = decodeUTF8(pathUtf8, length: pathLength), !path.isEmpty else {
        recordLastError(.invalidUTF8, "database path must be valid non-empty UTF-8")
        return MuesliBridgeCode.invalidUTF8.rawValue
    }
    do {
        let store = DictationStore(databaseURL: URL(fileURLWithPath: path))
        try store.migrateIfNeeded()
        let box = BridgeStore(store: store)
        outHandle.pointee = OpaquePointer(Unmanaged.passRetained(box).toOpaque())
        return MuesliBridgeCode.ok.rawValue
    } catch {
        recordLastError(.storeError, "failed to open store: \(error)")
        return MuesliBridgeCode.storeError.rawValue
    }
}

/// Releases a handle returned by `open`. Passing null is a safe no-op. The caller
/// must serialize close with every operation using the same handle; no call may
/// begin or remain in flight after close.
@_cdecl("muesli_core_bridge_close")
public func muesli_core_bridge_close(_ handle: OpaquePointer?) {
    guard let handle else { return }
    Unmanaged<BridgeStore>.fromOpaque(UnsafeRawPointer(handle)).release()
}

/// Inserts one dictation. Request is a versioned UTF-8 JSON object; `outId`
/// receives the new row id.
@_cdecl("muesli_core_bridge_insert_dictation")
public func muesli_core_bridge_insert_dictation(
    _ handle: OpaquePointer?,
    _ requestUtf8: UnsafePointer<UInt8>?,
    _ requestLength: Int32,
    _ outId: UnsafeMutablePointer<Int64>?
) -> Int32 {
    clearLastError()
    guard let handle else {
        recordLastError(.invalidHandle, "store handle is null")
        return MuesliBridgeCode.invalidHandle.rawValue
    }
    guard let json = decodeUTF8(requestUtf8, length: requestLength) else {
        recordLastError(.invalidUTF8, "request must be valid UTF-8")
        return MuesliBridgeCode.invalidUTF8.rawValue
    }
    let request: BridgeInsertRequest
    do {
        request = try JSONDecoder().decode(BridgeInsertRequest.self, from: Data(json.utf8))
    } catch {
        recordLastError(.invalidJSON, "request is not a valid insert payload: \(error)")
        return MuesliBridgeCode.invalidJSON.rawValue
    }
    let box = Unmanaged<BridgeStore>.fromOpaque(UnsafeRawPointer(handle)).takeUnretainedValue()
    box.lock.lock()
    defer { box.lock.unlock() }
    do {
        let parsedEnd = parseISODate(request.endedAt)
        let parsedStart = parseISODate(request.startedAt)
        if (request.endedAt?.isEmpty == false && parsedEnd == nil) ||
           (request.startedAt?.isEmpty == false && parsedStart == nil) {
            recordLastError(.invalidJSON, "timestamps must be valid ISO-8601 dates")
            return MuesliBridgeCode.invalidJSON.rawValue
        }
        let endedAt = parsedEnd ?? Date()
        let startedAt = parsedStart ?? endedAt
        let id = try box.store.insertDictation(
            text: request.text,
            durationSeconds: request.durationSeconds,
            appContext: request.appContext ?? "",
            source: request.source ?? "dictation",
            targetAppName: request.targetAppName,
            targetAppBundleID: request.targetAppBundleId,
            startedAt: startedAt,
            endedAt: endedAt
        )
        outId?.pointee = id
        return MuesliBridgeCode.ok.rawValue
    } catch {
        recordLastError(.storeError, "insert failed: \(error)")
        return MuesliBridgeCode.storeError.rawValue
    }
}

/// Reads recent dictations as a versioned UTF-8 JSON object. The caller owns
/// `output`; on `bufferTooSmall`, `written` reports the required capacity.
@_cdecl("muesli_core_bridge_recent_dictations")
public func muesli_core_bridge_recent_dictations(
    _ handle: OpaquePointer?,
    _ limit: Int32,
    _ output: UnsafeMutablePointer<UInt8>?,
    _ outputCapacity: Int32,
    _ written: UnsafeMutablePointer<Int32>?
) -> Int32 {
    clearLastError()
    guard let handle else {
        recordLastError(.invalidHandle, "store handle is null")
        return MuesliBridgeCode.invalidHandle.rawValue
    }
    guard limit >= 1 && limit <= 1000 else {
        recordLastError(.invalidArgument, "limit must be between 1 and 1000")
        return MuesliBridgeCode.invalidArgument.rawValue
    }
    let box = Unmanaged<BridgeStore>.fromOpaque(UnsafeRawPointer(handle)).takeUnretainedValue()
    box.lock.lock()
    defer { box.lock.unlock() }
    do {
        let records = try box.store.recentDictations(limit: Int(limit))
        let response = BridgeRecentResponse(records: records.map(BridgeRecord.init))
        let data = try JSONEncoder().encode(response)
        return writeOutput(data, to: output, capacity: outputCapacity, written: written)
    } catch {
        recordLastError(.storeError, "recent read failed: \(error)")
        return MuesliBridgeCode.storeError.rawValue
    }
}

/// Copies the last structured error as UTF-8 JSON. Caller owns the buffer.
@_cdecl("muesli_core_bridge_last_error")
public func muesli_core_bridge_last_error(
    _ output: UnsafeMutablePointer<UInt8>?,
    _ outputCapacity: Int32,
    _ written: UnsafeMutablePointer<Int32>?
) -> Int32 {
    let json = Thread.current.threadDictionary[bridgeLastErrorKey] as? String
        ?? "{\"code\":0,\"message\":\"\"}"
    let data = Data(json.utf8)
    return writeOutput(data, to: output, capacity: outputCapacity, written: written)
}

private func jsonEscape(_ value: String) -> String {
    let encoded = try? JSONEncoder().encode(value)
    guard let encoded, let string = String(data: encoded, encoding: .utf8) else { return "\"\"" }
    return string
}
