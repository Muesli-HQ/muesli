import Foundation
import XCTest
@testable import MuesliCoreABI

/// Exercises the C ABI surface directly (the C# host exercises the real
/// dynamic-library boundary).
final class BridgeTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-core-abi-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func databasePath() -> String {
        directory.appendingPathComponent("muesli-core.db").path
    }

    private func withUTF8<T>(_ value: String, _ body: (UnsafePointer<UInt8>?, Int32) -> T) -> T {
        let bytes = Array(value.utf8)
        return bytes.withUnsafeBufferPointer { body($0.baseAddress, Int32($0.count)) }
    }

    private func openStore(path: String? = nil) -> OpaquePointer? {
        var handle: OpaquePointer?
        let result = withUTF8(path ?? databasePath()) { pointer, length in
            muesli_core_bridge_open(pointer, length, &handle)
        }
        XCTAssertEqual(result, MuesliBridgeCode.ok.rawValue)
        return handle
    }

    private func insert(_ handle: OpaquePointer?, _ json: String) -> (Int32, Int64) {
        var id: Int64 = 0
        let code = withUTF8(json) { pointer, length in
            muesli_core_bridge_insert_dictation(handle, pointer, length, &id)
        }
        return (code, id)
    }

    private func recent(_ handle: OpaquePointer?, limit: Int32) -> (code: Int32, records: [BridgeRecord]) {
        var required: Int32 = 0
        let discovery = muesli_core_bridge_recent_dictations(handle, limit, nil, 0, &required)
        // A capacity probe returns bufferTooSmall with the required size; any
        // other code is a real error (invalid handle/limit) and is surfaced.
        if discovery != MuesliBridgeCode.bufferTooSmall.rawValue {
            return (discovery, [])
        }
        XCTAssertGreaterThan(required, 0)
        var buffer = [UInt8](repeating: 0, count: Int(required))
        var written: Int32 = 0
        let code = muesli_core_bridge_recent_dictations(handle, limit, &buffer, Int32(buffer.count), &written)
        guard code == MuesliBridgeCode.ok.rawValue else { return (code, []) }
        let data = Data(buffer[0..<Int(written)])
        let response = try! JSONDecoder().decode(BridgeRecentResponse.self, from: data)
        return (code, response.records)
    }

    func testABIVersionIsExposed() {
        XCTAssertEqual(muesli_core_bridge_abi_version(), 1)
    }

    func testOpenRejectsNullAndInvalidInputs() {
        XCTAssertEqual(muesli_core_bridge_open(nil, 0, nil), MuesliBridgeCode.invalidArgument.rawValue)
        var handle: OpaquePointer?
        XCTAssertEqual(muesli_core_bridge_open(nil, 0, &handle), MuesliBridgeCode.invalidUTF8.rawValue)

        // Invalid UTF-8 path bytes.
        var invalid: [UInt8] = [0xFF, 0xFE]
        let code = invalid.withUnsafeMutableBufferPointer { buffer in
            muesli_core_bridge_open(buffer.baseAddress, 2, &handle)
        }
        XCTAssertEqual(code, MuesliBridgeCode.invalidUTF8.rawValue)
    }

    func testInvalidHandleAndMalformedJSON() {
        XCTAssertEqual(insert(nil, "{}").0, MuesliBridgeCode.invalidHandle.rawValue)
        XCTAssertEqual(recent(nil, limit: 1).code, MuesliBridgeCode.invalidHandle.rawValue)

        let handle = openStore()
        defer { muesli_core_bridge_close(handle) }
        XCTAssertEqual(insert(handle, "not json").0, MuesliBridgeCode.invalidJSON.rawValue)
        XCTAssertEqual(insert(handle, "{}").0, MuesliBridgeCode.invalidJSON.rawValue)
    }

    func testInvalidLimits() {
        let handle = openStore()
        defer { muesli_core_bridge_close(handle) }
        XCTAssertEqual(recent(handle, limit: 0).code, MuesliBridgeCode.invalidArgument.rawValue)
        XCTAssertEqual(recent(handle, limit: -1).code, MuesliBridgeCode.invalidArgument.rawValue)
        XCTAssertEqual(recent(handle, limit: 1001).code, MuesliBridgeCode.invalidArgument.rawValue)
    }

    func testExplicitInvalidTimestampDoesNotInsert() {
        let handle = openStore()
        defer { muesli_core_bridge_close(handle) }
        XCTAssertEqual(insert(handle, #"{"text":"invalid","durationSeconds":1,"startedAt":"yesterday"}"#).0,
                       MuesliBridgeCode.invalidJSON.rawValue)
        XCTAssertEqual(insert(handle, #"{"text":"invalid","durationSeconds":1,"endedAt":"tomorrow"}"#).0,
                       MuesliBridgeCode.invalidJSON.rawValue)
        XCTAssertEqual(recent(handle, limit: 10).records.count, 0)
        XCTAssertEqual(insert(handle, #"{"text":"valid","durationSeconds":1,"startedAt":""}"#).0,
                       MuesliBridgeCode.ok.rawValue)
    }

    func testInsertThenRecentRoundTripPreservesFields() {
        let handle = openStore()
        defer { muesli_core_bridge_close(handle) }

        let json = """
        {"text":"Hello Zürich café 東京 — punctuation!","durationSeconds":3.5,
         "appContext":"com.example.editor","source":"dictation",
         "targetAppName":"Editor","targetAppBundleId":"com.example.editor",
         "startedAt":"2026-09-18T10:00:00Z","endedAt":"2026-09-18T10:00:03Z"}
        """
        let (code, id) = insert(handle, json)
        XCTAssertEqual(code, MuesliBridgeCode.ok.rawValue)
        XCTAssertGreaterThan(id, 0)

        let (readCode, records) = recent(handle, limit: 10)
        XCTAssertEqual(readCode, MuesliBridgeCode.ok.rawValue)
        XCTAssertEqual(records.count, 1)
        let record = records[0]
        XCTAssertEqual(record.id, id)
        XCTAssertEqual(record.rawText, "Hello Zürich café 東京 — punctuation!")
        XCTAssertEqual(record.appContext, "com.example.editor")
        XCTAssertEqual(record.source, "dictation")
        XCTAssertEqual(record.targetAppName, "Editor")
        XCTAssertEqual(record.targetAppBundleId, "com.example.editor")
        XCTAssertEqual(record.durationSeconds ?? 0, 3.5, accuracy: 0.0001)
        XCTAssertGreaterThan(record.wordCount, 0)
        XCTAssertEqual(record.timestamp, "2026-09-18T10:00:03Z")
    }

    func testOrderingAndLimit() {
        let handle = openStore()
        defer { muesli_core_bridge_close(handle) }

        for index in 0..<5 {
            let day = 10 + index
            let json = """
            {"text":"item \(index)","durationSeconds":1.0,
             "startedAt":"2026-09-\(day)T10:00:00Z","endedAt":"2026-09-\(day)T10:00:01Z"}
            """
            XCTAssertEqual(insert(handle, json).0, MuesliBridgeCode.ok.rawValue)
        }

        let (_, all) = recent(handle, limit: 10)
        XCTAssertEqual(all.count, 5)
        XCTAssertEqual(all.map(\.rawText), ["item 4", "item 3", "item 2", "item 1", "item 0"])

        let (_, limited) = recent(handle, limit: 2)
        XCTAssertEqual(limited.map(\.rawText), ["item 4", "item 3"])
    }

    func testEmptyAndLargeTranscripts() {
        let handle = openStore()
        defer { muesli_core_bridge_close(handle) }

        XCTAssertEqual(insert(handle, #"{"text":"","durationSeconds":0.1}"#).0, MuesliBridgeCode.ok.rawValue)
        let large = String(repeating: "word ", count: 20_000) // ~100 KB
        let payload = try! JSONSerialization.data(withJSONObject: [
            "text": large, "durationSeconds": 12.0,
        ])
        let json = String(decoding: payload, as: UTF8.self)
        XCTAssertEqual(insert(handle, json).0, MuesliBridgeCode.ok.rawValue)

        let (_, records) = recent(handle, limit: 10)
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[0].rawText.count, large.count)
    }

    func testUndersizedBufferReportsRequiredCapacity() {
        let handle = openStore()
        defer { muesli_core_bridge_close(handle) }
        XCTAssertEqual(insert(handle, #"{"text":"capacity discovery","durationSeconds":1.0}"#).0, MuesliBridgeCode.ok.rawValue)

        var required: Int32 = 0
        let discovery = muesli_core_bridge_recent_dictations(handle, 10, nil, 0, &required)
        XCTAssertEqual(discovery, MuesliBridgeCode.bufferTooSmall.rawValue)
        XCTAssertGreaterThan(required, 0)

        var tiny = [UInt8](repeating: 0, count: Int(required) - 1)
        var written: Int32 = 0
        let code = muesli_core_bridge_recent_dictations(handle, 10, &tiny, Int32(tiny.count), &written)
        XCTAssertEqual(code, MuesliBridgeCode.bufferTooSmall.rawValue)
        XCTAssertEqual(written, required)
    }

    func testRepeatedOpenInsertReadCloseDoesNotLeak() {
        for index in 0..<25 {
            let handle = openStore()
            XCTAssertEqual(insert(handle, #"{"text":"cycle","durationSeconds":0.5}"#).0, MuesliBridgeCode.ok.rawValue)
            XCTAssertEqual(recent(handle, limit: 5).code, MuesliBridgeCode.ok.rawValue)
            XCTAssertEqual(recent(handle, limit: 100).records.count, index + 1)
            muesli_core_bridge_close(handle)
        }
    }

    func testLastErrorIsStructuredJSON() {
        _ = insert(nil, "{}")
        var required: Int32 = 0
        XCTAssertEqual(muesli_core_bridge_last_error(nil, 0, &required), MuesliBridgeCode.bufferTooSmall.rawValue)
        var buffer = [UInt8](repeating: 0, count: Int(required))
        var written: Int32 = 0
        XCTAssertEqual(muesli_core_bridge_last_error(&buffer, Int32(buffer.count), &written), MuesliBridgeCode.ok.rawValue)
        let object = try! JSONSerialization.jsonObject(with: Data(buffer[0..<Int(written)])) as! [String: Any]
        XCTAssertEqual(object["code"] as? Int, Int(MuesliBridgeCode.invalidHandle.rawValue))
        XCTAssertNotNil(object["message"] as? String)
    }

    func testLastErrorBelongsToCallingThread() {
        let firstReady = DispatchSemaphore(value: 0)
        let secondDone = DispatchSemaphore(value: 0)
        let group = DispatchGroup()
        var firstCode: Int?
        var secondCode: Int?
        let lock = NSLock()
        func readCode() -> Int? {
            var required: Int32 = 0
            _ = muesli_core_bridge_last_error(nil, 0, &required)
            var buffer = [UInt8](repeating: 0, count: Int(required))
            _ = muesli_core_bridge_last_error(&buffer, required, &required)
            guard let value = try? JSONSerialization.jsonObject(with: Data(buffer)) as? [String: Any] else {
                return nil
            }
            return value["code"] as? Int
        }
        DispatchQueue.global().async(group: group) {
            _ = self.insert(nil, "{}")
            firstReady.signal()
            _ = secondDone.wait(timeout: .now() + 10)
            lock.lock()
            firstCode = readCode()
            lock.unlock()
        }
        DispatchQueue.global().async(group: group) {
            _ = firstReady.wait(timeout: .now() + 10)
            var invalid: [UInt8] = [0xFF]
            _ = invalid.withUnsafeMutableBufferPointer { bytes in
                muesli_core_bridge_word_count(bytes.baseAddress, 1)
            }
            lock.lock()
            secondCode = readCode()
            lock.unlock()
            secondDone.signal()
        }
        XCTAssertEqual(group.wait(timeout: .now() + 20), .success)
        XCTAssertEqual(firstCode, Int(MuesliBridgeCode.invalidHandle.rawValue))
        XCTAssertEqual(secondCode, Int(MuesliBridgeCode.invalidUTF8.rawValue))
    }

    // MARK: - Stateless text processing ABI

    private func normalizeViaABI(_ text: String?) -> (code: Int32, value: String?) {
        var required: Int32 = 0
        let probe: Int32
        if let text {
            probe = withUTF8(text) { pointer, length in
                muesli_core_bridge_normalize_transcript(pointer, length, nil, 0, &required)
            }
        } else {
            probe = muesli_core_bridge_normalize_transcript(nil, 0, nil, 0, &required)
        }
        if probe == MuesliBridgeCode.ok.rawValue {
            return (probe, "")
        }
        guard probe == MuesliBridgeCode.bufferTooSmall.rawValue else { return (probe, nil) }
        var buffer = [UInt8](repeating: 0, count: Int(required))
        var written: Int32 = 0
        let code: Int32
        if let text {
            code = withUTF8(text) { pointer, length in
                muesli_core_bridge_normalize_transcript(pointer, length, &buffer, Int32(buffer.count), &written)
            }
        } else {
            code = muesli_core_bridge_normalize_transcript(nil, 0, &buffer, Int32(buffer.count), &written)
        }
        guard code == MuesliBridgeCode.ok.rawValue else { return (code, nil) }
        return (code, String(decoding: buffer[0..<Int(written)], as: UTF8.self))
    }

    private func metricsViaABI(_ text: String) -> (code: Int32, json: [String: Any]?) {
        var required: Int32 = 0
        let probe = withUTF8(text) { pointer, length in
            muesli_core_bridge_text_metrics(pointer, length, nil, 0, &required)
        }
        guard probe == MuesliBridgeCode.bufferTooSmall.rawValue, required > 0 else { return (probe, nil) }
        var buffer = [UInt8](repeating: 0, count: Int(required))
        var written: Int32 = 0
        let code = withUTF8(text) { pointer, length in
            muesli_core_bridge_text_metrics(pointer, length, &buffer, Int32(buffer.count), &written)
        }
        guard code == MuesliBridgeCode.ok.rawValue else { return (code, nil) }
        let object = try? JSONSerialization.jsonObject(with: Data(buffer[0..<Int(written)])) as? [String: Any]
        return (code, object ?? nil)
    }

    func testCapabilitiesIncludePersistenceAndTextProcessing() {
        let capabilities = muesli_core_bridge_capabilities()
        XCTAssertNotEqual(capabilities & MuesliBridgeCapabilities.persistence, 0)
        XCTAssertNotEqual(capabilities & MuesliBridgeCapabilities.textProcessing, 0)
    }

    func testNormalizeTranscriptABI() {
        XCTAssertEqual(normalizeViaABI("  hello   world \n").value, "hello world")
        XCTAssertEqual(normalizeViaABI("first\n\nsecond").value, "first second")
        XCTAssertEqual(normalizeViaABI(nil).value, "")
        XCTAssertEqual(normalizeViaABI("").value, "")
    }

    func testNormalizeTranscriptInvalidUTF8IsRejected() {
        var invalid: [UInt8] = [0xFF, 0xFE]
        var required: Int32 = 0
        let code = invalid.withUnsafeMutableBufferPointer { buffer in
            muesli_core_bridge_normalize_transcript(buffer.baseAddress, 2, nil, 0, &required)
        }
        XCTAssertEqual(code, MuesliBridgeCode.invalidUTF8.rawValue)
    }

    func testNormalizeTranscriptUndersizedBufferReportsCapacity() {
        var required: Int32 = 0
        let probe = withUTF8("hello   world") { pointer, length in
            muesli_core_bridge_normalize_transcript(pointer, length, nil, 0, &required)
        }
        XCTAssertEqual(probe, MuesliBridgeCode.bufferTooSmall.rawValue)
        XCTAssertEqual(required, 11)

        var tiny = [UInt8](repeating: 0, count: Int(required) - 1)
        var written: Int32 = 0
        let code = withUTF8("hello   world") { pointer, length in
            muesli_core_bridge_normalize_transcript(pointer, length, &tiny, Int32(tiny.count), &written)
        }
        XCTAssertEqual(code, MuesliBridgeCode.bufferTooSmall.rawValue)
        XCTAssertEqual(written, required)
    }

    func testWordCountABI() {
        func count(_ text: String) -> Int32 {
            withUTF8(text) { pointer, length in
                muesli_core_bridge_word_count(pointer, length)
            }
        }
        XCTAssertEqual(count(""), 0)
        XCTAssertEqual(count("one two   three\nfour"), 4)
        XCTAssertEqual(count("— ..."), 2)
        XCTAssertEqual(count("3.14 42"), 2)
        XCTAssertEqual(count("東京 です"), 2)
        XCTAssertEqual(muesli_core_bridge_word_count(nil, 0), 0)

        var invalid: [UInt8] = [0xFF, 0xFE]
        let invalidCount = invalid.withUnsafeMutableBufferPointer { buffer in
            muesli_core_bridge_word_count(buffer.baseAddress, 2)
        }
        XCTAssertEqual(invalidCount, -1)
    }

    func testTextMetricsABI() {
        let (code, json) = metricsViaABI("one two   three\nfour")
        XCTAssertEqual(code, MuesliBridgeCode.ok.rawValue)
        XCTAssertEqual(json?["version"] as? Int, 1)
        XCTAssertEqual(json?["wordCount"] as? Int, 4)
    }

    func testStatelessCallsAreConcurrentAndDeterministic() {
        let group = DispatchGroup()
        var results = [String](repeating: "", count: 32)
        let lock = NSLock()
        for index in 0..<32 {
            DispatchQueue.global().async(group: group) {
                let value = self.normalizeViaABI("  thread \(index)   text ").value ?? ""
                lock.lock()
                results[index] = value
                lock.unlock()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 60), .success)
        XCTAssertEqual(results, (0..<32).map { "thread \($0) text" })
    }

    func testConcurrentReadsAndWrites() {
        let handle = openStore()
        defer { muesli_core_bridge_close(handle) }

        let group = DispatchGroup()
        for index in 0..<20 {
            DispatchQueue.global().async(group: group) {
                _ = self.insert(handle, #"{"text":"thread \#(index)","durationSeconds":1.0}"#)
            }
            DispatchQueue.global().async(group: group) {
                _ = self.recent(handle, limit: 5)
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 60), .success)
        let (_, records) = recent(handle, limit: 100)
        XCTAssertEqual(records.count, 20)
    }
}
