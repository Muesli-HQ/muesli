import CryptoKit
import Foundation

/// Shares completed per-record analyses across dashboard refreshes and store instances.
/// Only content digests and run lengths are retained; transcript text is never cached.
final class WordsBeforeCodeSwitchCache: @unchecked Sendable {
    static let shared = WordsBeforeCodeSwitchCache()

    private struct Key: Hashable {
        let database: String
        let recordID: Int64
    }

    private struct Entry {
        let digest: SHA256.Digest
        let lengths: [Int]
    }

    private let lock = NSLock()
    private let maximumEntries: Int
    private let maximumLengths: Int
    private var entries: [Key: Entry] = [:]
    private var retainedLengths = 0
    private var oldestRecordID: Int64?

    init(maximumEntries: Int = 2_048, maximumLengths: Int = 65_536) {
        self.maximumEntries = max(0, maximumEntries)
        self.maximumLengths = max(0, maximumLengths)
    }

    func runLengths(
        databaseURL: URL,
        recordID: Int64,
        text: String,
        isCancelled: () -> Bool = { Task<Never, Never>.isCancelled },
        analyze: (String) -> [Int] = WordsBeforeCodeSwitch.runLengths(in:)
    ) -> [Int]? {
        guard !isCancelled() else { return nil }
        let key = Key(database: databaseURL.standardizedFileURL.path, recordID: recordID)
        let digest = SHA256.hash(data: Data(text.utf8))
        let cached: [Int]? = lock.withLock {
            guard let entry = entries[key], entry.digest == digest else { return nil }
            return entry.lengths
        }
        if let cached { return isCancelled() ? nil : cached }

        // Different records may be analyzed concurrently without holding the cache lock.
        let lengths = analyze(text)
        guard !isCancelled() else { return nil }
        lock.withLock {
            if let previous = entries.removeValue(forKey: key) {
                retainedLengths -= previous.lengths.count
                oldestRecordID = entries.keys.map(\.recordID).min()
            }
            guard maximumEntries > 0, lengths.count <= maximumLengths else { return }
            if entries.count >= maximumEntries || lengths.count > maximumLengths - retainedLengths {
                // SQLite record IDs rise with new dictations. Retain the newest
                // records so a full-history scan cannot churn the cache, while
                // newly recorded dictations can displace older analyses.
                guard let oldestRecordID, recordID > oldestRecordID else { return }
                let candidates = entries.keys
                    .filter { $0.recordID < recordID }
                    .sorted { lhs, rhs in
                        lhs.recordID == rhs.recordID
                            ? lhs.database < rhs.database
                            : lhs.recordID < rhs.recordID
                    }
                var victims: [Key] = []
                var availableEntries = maximumEntries - entries.count
                var availableLengths = maximumLengths - retainedLengths
                for candidate in candidates {
                    if availableEntries > 0 && availableLengths >= lengths.count { break }
                    victims.append(candidate)
                    availableEntries += 1
                    availableLengths += entries[candidate]?.lengths.count ?? 0
                }
                guard availableEntries > 0, availableLengths >= lengths.count else { return }
                for victim in victims {
                    if let removed = entries.removeValue(forKey: victim) {
                        retainedLengths -= removed.lengths.count
                    }
                }
            }
            entries[key] = Entry(digest: digest, lengths: lengths)
            retainedLengths += lengths.count
            oldestRecordID = entries.keys.map(\.recordID).min()
        }
        return lengths
    }
}
