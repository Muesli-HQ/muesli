import Foundation
@testable import MuesliCore
import Testing

@Suite("WBCS analysis cache")
struct WordsBeforeCodeSwitchCacheTests {
    private let databaseURL = URL(fileURLWithPath: "/tmp/wbcs-cache-test.db")

    @Test("Repeated records reuse analysis and same-length edits invalidate it")
    func contentInvalidation() {
        let cache = WordsBeforeCodeSwitchCache()
        var calls = 0
        func analyze(_ text: String) -> [Int] {
            calls += 1
            return text == "hello नमस्ते" ? [1] : []
        }
        #expect(cache.runLengths(databaseURL: databaseURL, recordID: 1, text: "hello नमस्ते", analyze: analyze) == [1])
        #expect(cache.runLengths(databaseURL: databaseURL, recordID: 1, text: "hello नमस्ते", analyze: analyze) == [1])
        #expect(calls == 1)
        #expect(cache.runLengths(databaseURL: databaseURL, recordID: 1, text: "hello world", analyze: analyze) == [])
        #expect(cache.runLengths(databaseURL: databaseURL, recordID: 1, text: "hello world", analyze: analyze) == [])
        #expect(calls == 2)
    }

    @Test("Filtered aggregates reuse individual runs and weight every stretch equally")
    func filterAggregation() {
        let cache = WordsBeforeCodeSwitchCache()
        var calls = 0
        func aggregate(_ records: [Int64]) -> Double? {
            let lengths = records.flatMap { id in
                cache.runLengths(databaseURL: databaseURL, recordID: id, text: "record \(id)") { _ in
                    calls += 1
                    return id == 1 ? [1, 3, 5] : [20]
                } ?? []
            }
            return WordsBeforeCodeSwitch.median(of: lengths)
        }
        #expect(aggregate([1, 2]) == 4)
        #expect(aggregate([2]) == 20)
        #expect(aggregate([1]) == 3)
        #expect(aggregate([]) == nil)
        #expect(calls == 2)
    }

    @Test("Record identities are scoped to each database")
    func databaseIsolation() {
        let cache = WordsBeforeCodeSwitchCache()
        var calls = 0
        for url in [databaseURL, URL(fileURLWithPath: "/tmp/another-wbcs-cache-test.db")] {
            _ = cache.runLengths(databaseURL: url, recordID: 1, text: "same text") { _ in
                calls += 1
                return [calls]
            }
        }
        #expect(calls == 2)
    }

    @Test("Cancelled analysis is never retained")
    func cancellation() {
        let cache = WordsBeforeCodeSwitchCache()
        var cancelled = false
        let result = cache.runLengths(
            databaseURL: databaseURL, recordID: 1, text: "sample",
            isCancelled: { cancelled }, analyze: { _ in
                cancelled = true
                return [1]
            }
        )
        #expect(result == nil)
        #expect(cache.runLengths(databaseURL: databaseURL, recordID: 1, text: "sample", analyze: { _ in [7] }) == [7])
    }

    @Test("Entry and retained-run limits preserve admitted analyses")
    func boundedStorage() {
        for cache in [
            WordsBeforeCodeSwitchCache(maximumEntries: 1),
            WordsBeforeCodeSwitchCache(maximumLengths: 2),
        ] {
            var calls = 0
            for id in [Int64(1), 2, 1] {
                _ = cache.runLengths(databaseURL: databaseURL, recordID: id, text: "sample") { _ in
                    calls += 1
                    return [1, 2]
                }
            }
            #expect(calls == 2)
        }
    }

    @Test("Repeated scans larger than capacity still reuse admitted records")
    func overCapacityScan() {
        let cache = WordsBeforeCodeSwitchCache(maximumEntries: 2)
        var calls = 0
        for _ in 0..<2 {
            for id in Int64(1)...5 {
                _ = cache.runLengths(databaseURL: databaseURL, recordID: id, text: "sample") { _ in
                    calls += 1
                    return [1]
                }
            }
        }
        #expect(calls == 8)
    }

    @Test("Oversized content changes remove stale entries and remain uncached")
    func oversizedReplacement() {
        let cache = WordsBeforeCodeSwitchCache(maximumEntries: 1, maximumLengths: 1)
        _ = cache.runLengths(databaseURL: databaseURL, recordID: 1, text: "original", analyze: { _ in [1] })
        #expect(cache.runLengths(databaseURL: databaseURL, recordID: 1, text: "changed", analyze: { _ in [1, 2] }) == [1, 2])
        var calls = 0
        // A different record can occupy the slot vacated by the stale entry.
        for _ in 0..<2 {
            _ = cache.runLengths(databaseURL: databaseURL, recordID: 2, text: "another") { _ in
                calls += 1
                return [3]
            }
        }
        #expect(calls == 1)
        #expect(cache.runLengths(databaseURL: databaseURL, recordID: 1, text: "original", analyze: { _ in [4] }) == [4])
    }
}
