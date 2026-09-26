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
            }
            // Keep a stable admitted subset. Evicting on every miss would make a
            // sequential history scan larger than capacity miss again on every refresh.
            guard entries.count < maximumEntries,
                  lengths.count <= maximumLengths - retainedLengths else { return }
            entries[key] = Entry(digest: digest, lengths: lengths)
            retainedLengths += lengths.count
        }
        return lengths
    }
}
