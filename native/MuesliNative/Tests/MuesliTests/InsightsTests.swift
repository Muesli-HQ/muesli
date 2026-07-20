import AppKit
import Foundation
@testable import MuesliCore
@testable import MuesliNativeApp
import SQLite3
import Testing

@Suite("Local Insights", .serialized)
struct InsightsTests {
    private func makeStore() throws -> DictationStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-insights-test-\(UUID().uuidString).db")
        let store = DictationStore(databaseURL: url)
        try store.migrateIfNeeded()
        return store
    }

    @Test("empty history returns a complete zero-filled range")
    func emptyHistory() throws {
        let store = try makeStore()
        let now = Date(timeIntervalSince1970: 1_784_092_800) // 2026-07-15T00:00:00Z
        let snapshot = try store.insightsSnapshot(range: .thirtyDays, now: now)

        #expect(snapshot.selected.totalWords == 0)
        #expect(snapshot.dailyActivity.count == 30)
        #expect(snapshot.activeDaysInRange == 0)
        #expect(snapshot.dictationWords.isEmpty)
        #expect(snapshot.meetingWords.isEmpty)
    }

    @Test("range aggregates dictations and only finished meeting states")
    func rangeAggregation() throws {
        let store = try makeStore()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_784_092_800)
        let recent = calendar.date(byAdding: .day, value: -2, to: now)!
        let old = calendar.date(byAdding: .day, value: -45, to: now)!

        try store.insertDictation(text: "Nordic signal signal", durationSeconds: 60, startedAt: recent.addingTimeInterval(-60), endedAt: recent)
        try store.insertDictation(text: "old archive", durationSeconds: 60, startedAt: old.addingTimeInterval(-60), endedAt: old)
        try store.insertMeeting(
            title: "Finished", calendarEventID: nil, startTime: recent,
            endTime: recent.addingTimeInterval(60), rawTranscript: "product rhythm rhythm",
            formattedNotes: "", micAudioPath: nil, systemAudioPath: nil
        )
        let live = try store.createLiveMeeting(title: "Still live", calendarEventID: nil, startTime: recent)
        try store.updateMeetingManualNotes(id: live, manualNotes: "should stay private from insights")

        let snapshot = try store.insightsSnapshot(range: .thirtyDays, now: now, calendar: calendar)
        #expect(snapshot.lifetime.dictationWords == 5)
        #expect(snapshot.selected.dictationWords == 3)
        #expect(snapshot.selected.meetings == 1)
        #expect(snapshot.selected.meetingWords == 3)
        #expect(snapshot.dailyActivity.reduce(0) { $0 + $1.meetings } == 1)
        #expect(snapshot.dictationWords.first?.word == "signal")
        #expect(snapshot.meetingWords.first?.word == "rhythm")
    }

    @Test("deleted history is absent from totals, activity, and vocabulary")
    func deletedHistory() throws {
        let store = try makeStore()
        let now = Date(timeIntervalSince1970: 1_784_092_800)
        let id = try store.insertDictation(
            text: "vanishing vocabulary", durationSeconds: 10,
            startedAt: now.addingTimeInterval(-10), endedAt: now
        )
        let beforeDeletion = try store.insightsSnapshot(range: .allTime, now: now)
        #expect(beforeDeletion.lifetime.totalWords == 2)
        #expect(beforeDeletion.dictationWords.contains { $0.word == "vocabulary" })

        try store.deleteDictation(id: id)

        let snapshot = try store.insightsSnapshot(range: .allTime, now: now)
        #expect(snapshot.lifetime.totalWords == 0)
        #expect(snapshot.activeDaysInRange == 0)
        #expect(snapshot.dictationWords.isEmpty)
    }

    @Test("incremental cache adds newly completed records without rebuilding prior contributions")
    func incrementalAddition() throws {
        let store = try makeStore()
        let now = Date(timeIntervalSince1970: 1_784_092_800)
        try store.insertDictation(text: "alpha alpha", durationSeconds: 10, startedAt: now.addingTimeInterval(-10), endedAt: now)
        let first = try store.insightsSnapshot(range: .allTime, now: now)
        #expect(first.lifetime.totalWords == 2)

        let meetingID = try store.createLiveMeeting(title: "Notes", calendarEventID: nil, startTime: now)
        _ = try store.insightsSnapshot(range: .allTime, now: now)
        try store.updateMeetingManualNotes(id: meetingID, manualNotes: "bravo bravo bravo")
        try store.updateMeetingStatus(id: meetingID, status: .noteOnly)

        let updated = try store.insightsSnapshot(range: .allTime, now: now)
        #expect(updated.lifetime.totalWords == 5)
        #expect(updated.lifetime.meetings == 1)
        #expect(updated.meetingWords.first == InsightsWordFrequency(word: "bravo", count: 3))
    }

    @Test("lossless contribution codec round trips sorted token counts")
    func contributionCodecRoundTrip() {
        let pairs = (1...2_000).map {
            InsightsContributionCodec.Pair(tokenID: Int64($0 * 3), count: ($0 % 17) + 1)
        }
        let encoded = InsightsContributionCodec.encode(pairs)
        let decoded = InsightsContributionCodec.decode(encoded)

        #expect(decoded == pairs)
        #expect(encoded.count < pairs.count * MemoryLayout<InsightsContributionCodec.Pair>.stride)
    }

    @Test("contribution codec rejects oversized and malformed frames without allocating")
    func contributionCodecRejectsInvalidFrames() {
        let oversized = Data([1]) + encodedVarint(UInt64(InsightsContributionCodec.maximumDecodedBytes + 1))
        let exceedsInt = Data([1]) + encodedVarint(UInt64(Int.max) + 1) + Data([0x01])
        let truncatedRaw = Data([0]) + encodedVarint(8) + Data([0x01, 0x01])
        let unknownMarker = Data([2, 0])

        #expect(InsightsContributionCodec.decode(oversized).isEmpty)
        #expect(InsightsContributionCodec.decode(exceedsInt).isEmpty)
        #expect(InsightsContributionCodec.decode(truncatedRaw).isEmpty)
        #expect(InsightsContributionCodec.decode(unknownMarker).isEmpty)
    }

    @Test("initial cache construction crosses bounded reconciliation batches")
    func initialCacheConstructionIsBatched() throws {
        let store = try makeStore()
        let now = Date(timeIntervalSince1970: 1_784_092_800)
        for index in 0..<130 {
            let end = now.addingTimeInterval(Double(-index))
            try store.insertDictation(
                text: "batchword batchword",
                durationSeconds: 1,
                startedAt: end.addingTimeInterval(-1),
                endedAt: end
            )
        }

        let snapshot = try store.insightsSnapshot(range: .allTime, now: now)
        let footprint = try cacheFootprint(store)

        #expect(snapshot.lifetime.dictationWords == 260)
        #expect(snapshot.dictationWords.first == InsightsWordFrequency(word: "batchword", count: 260))
        #expect(footprint.records == 130)
    }

    @Test("changing calendar timezone rebuilds the cache without changing lifetime totals")
    func timezoneCacheSignatureRebuild() throws {
        let store = try makeStore()
        let now = Date(timeIntervalSince1970: 1_784_092_800)
        try store.insertDictation(
            text: "timezone boundary",
            durationSeconds: 5,
            startedAt: now.addingTimeInterval(-5),
            endedAt: now
        )
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        var losAngeles = Calendar(identifier: .gregorian)
        losAngeles.timeZone = TimeZone(identifier: "America/Los_Angeles")!

        let first = try store.insightsSnapshot(range: .allTime, now: now, calendar: utc)
        let rebuilt = try store.insightsSnapshot(range: .allTime, now: now, calendar: losAngeles)

        #expect(first.lifetime == rebuilt.lifetime)
        #expect(try cacheFootprint(store).records == 1)
    }

    @Test("unchanged snapshots reuse the same record cache")
    func unchangedSnapshotReusesCache() throws {
        let store = try makeStore()
        let now = Date(timeIntervalSince1970: 1_784_092_800)
        try store.insertDictation(text: "cache efficiency efficiency", durationSeconds: 15, startedAt: now.addingTimeInterval(-15), endedAt: now)
        let first = try store.insightsSnapshot(range: .allTime, now: now)
        let before = try cacheFootprint(store)
        let second = try store.insightsSnapshot(range: .allTime, now: now)
        let after = try cacheFootprint(store)

        #expect(second == first)
        #expect(after.records == before.records)
        #expect(after.blobBytes == before.blobBytes)
    }

    @MainActor
    @Test("share card renders as a fixed-size PNG")
    func shareCardRendering() throws {
        let store = try makeStore()
        let now = Date(timeIntervalSince1970: 1_784_092_800)
        try store.insertDictation(
            text: "shareable local activity", durationSeconds: 12,
            startedAt: now.addingTimeInterval(-12), endedAt: now
        )
        let snapshot = try store.insightsSnapshot(range: .twelveMonths, now: now)

        let image = try #require(InsightsShareRenderer.render(snapshot: snapshot, rangeLabel: "12 months"))
        let png = try #require(InsightsShareRenderer.pngData(for: image))
        let template = try #require(InsightsShareRenderer.renderTemplate())
        let templatePNG = try #require(InsightsShareRenderer.pngData(for: template))

        #expect(image.size == InsightsShareRenderer.size)
        #expect(Array(png.prefix(8)) == [137, 80, 78, 71, 13, 10, 26, 10])
        #expect(template.size == InsightsShareRenderer.size)
        #expect(Array(templatePNG.prefix(8)) == [137, 80, 78, 71, 13, 10, 26, 10])
    }

    @Test("share image write failures return inline feedback")
    func shareImageWriteFailure() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-share-write-failure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let result = InsightsShareFileWriter.write(Data([0x89, 0x50, 0x4E, 0x47]), to: directory)

        guard case .failed(let message) = result else {
            Issue.record("Writing image data to a directory should fail")
            return
        }
        #expect(!message.isEmpty)
    }

    @Test("calendar range remains day-correct across daylight saving changes")
    func daylightSavingRange() throws {
        let store = try makeStore()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 3, day: 20, hour: 12))!

        let snapshot = try store.insightsSnapshot(range: .thirtyDays, now: now, calendar: calendar)
        #expect(snapshot.dailyActivity.count == 30)
        #expect(calendar.isDate(snapshot.dailyActivity.first!.date, inSameDayAs: calendar.date(byAdding: .day, value: -29, to: now)!))
        #expect(calendar.isDate(snapshot.dailyActivity.last!.date, inSameDayAs: now))
    }

    @Test("word analysis removes stop words and ranks ties alphabetically")
    func wordAnalysis() {
        let words = InsightsWordAnalyzer.frequencies(
            in: "The aurora aurora and fjord fjord beacon",
            limit: 10
        )
        #expect(!words.contains { $0.word == "the" || $0.word == "and" })
        #expect(words.map(\.word).prefix(2) == ["aurora", "fjord"])
        #expect(words.first?.count == 2)
    }

    @Test("word analysis accepts Unicode and rejects numeric noise")
    func unicodeWordAnalysis() {
        let words = InsightsWordAnalyzer.frequencies(in: "नमस्ते नमस्ते 1234 x café café", limit: 10)
        #expect(words.contains { $0.word == "नमस्ते" && $0.count == 2 })
        #expect(words.contains { $0.word == "café" && $0.count == 2 })
        #expect(!words.contains { $0.word == "1234" || $0.word == "x" })
    }

    @Test("meeting word analysis removes diarization labels and transcript annotations")
    func meetingLabelsAreRemoved() {
        let transcript = """
        [00:01:04] Speaker 1: Roadmap roadmap planning
        [00:01:08] You: Product launch
        [00:01:12] Others: [MUSIC PLAYING] Product review
        """
        let words = InsightsWordAnalyzer.meetingFrequencies(in: transcript, limit: 20)

        #expect(!words.contains { ["speaker", "you", "others", "music", "playing"].contains($0.word) })
        #expect(words.first?.word == "product")
        #expect(words.first?.count == 2)
        #expect(words.contains { $0.word == "roadmap" && $0.count == 2 })
    }

    @Test("word analysis is deterministically capped for large input")
    func largeInputIsCapped() {
        let text = (0..<200).map { "term" + String(repeating: "a", count: $0 + 2) }.joined(separator: " ")
        let words = InsightsWordAnalyzer.frequencies(in: text, limit: 48)
        #expect(words.count == 48)
        #expect(words == words.sorted { $0.count == $1.count ? $0.word < $1.word : $0.count > $1.count })
    }

    @Test("insights entry section scroll happens only after the first successful load")
    func initialSectionScrollIsOneShot() {
        var gate = InsightsInitialScrollGate()
        let beforeSnapshot = gate.consume(hasSnapshot: false)
        let firstSnapshot = gate.consume(hasSnapshot: true)
        let refreshedSnapshot = gate.consume(hasSnapshot: true)

        #expect(!beforeSnapshot)
        #expect(firstSnapshot)
        #expect(!refreshedSnapshot)
    }

    @Test("word cloud sizing uses only the words that are displayed")
    func wordCloudSizingUsesDisplayedWords() {
        let allWords = (1...48).map {
            InsightsWordFrequency(word: "word\($0)", count: 49 - $0)
        }
        let displayed = Array(allWords.prefix(32))

        let largest = InsightsWordCloudSizing.fontSize(for: displayed[0], displayedWords: displayed)
        let smallest = InsightsWordCloudSizing.fontSize(for: displayed[31], displayedWords: displayed)

        #expect(largest == 33)
        #expect(smallest == 13)
    }

    @Test("loading copy explains local processing without overpromising")
    func loadingCopyExplainsPrivacy() {
        #expect(InsightsLoadingCopy.messages.count == 4)
        #expect(Set(InsightsLoadingCopy.messages).count == 4)
        #expect(InsightsLoadingCopy.messages.contains { $0.contains("computed on this Mac") })
        #expect(InsightsLoadingCopy.messages.contains { $0.contains("choose what stays local") })
    }

    @Test("activity heatmap marks the visible starting month and later month boundaries")
    func activityHeatmapMonthMarkers() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = calendar.date(from: DateComponents(year: 2026, month: 6, day: 20))!
        let activity = (0..<45).map { offset in
            InsightsDailyActivity(
                date: calendar.date(byAdding: .day, value: offset, to: start)!,
                words: 0,
                meetings: 0
            )
        }

        let weeks = ActivityHeatmapCalendarLayout.weeks(from: activity, calendar: calendar)
        let markerMonths = weeks.enumerated().compactMap { index, week in
            ActivityHeatmapCalendarLayout.monthMarker(
                for: week,
                at: index,
                calendar: calendar
            ).map { calendar.component(.month, from: $0) }
        }

        #expect(markerMonths == [6, 7, 8])
    }

    @Test("activity heatmap keeps Sunday through Saturday in one column across locales")
    func activityHeatmapUsesSundayFirstColumns() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.firstWeekday = 2
        let sunday = calendar.date(from: DateComponents(year: 2026, month: 6, day: 28))!
        let activity = (0..<7).map { offset in
            InsightsDailyActivity(
                date: calendar.date(byAdding: .day, value: offset, to: sunday)!,
                words: 0,
                meetings: 0
            )
        }

        let weeks = ActivityHeatmapCalendarLayout.weeks(from: activity, calendar: calendar)

        #expect(weeks.count == 1)
        #expect(weeks[0].map { calendar.component(.weekday, from: $0.date) } == Array(1...7))
    }

    @Test("word flow layout wraps after the available width and uses the tallest row item")
    func wordFlowLayoutWrapsAndTracksRowHeight() {
        let result = WordFlowLayout(spacing: 10).layout(
            sizes: [
                CGSize(width: 100, height: 20),
                CGSize(width: 80, height: 30),
                CGSize(width: 60, height: 10),
            ],
            width: 190
        )

        #expect(result.size == CGSize(width: 190, height: 50))
        #expect(result.points == [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 110, y: 0),
            CGPoint(x: 0, y: 40),
        ])
    }

    @Test("word flow layout keeps an item on a row when it exactly fits")
    func wordFlowLayoutAcceptsExactFit() {
        let result = WordFlowLayout(spacing: 10).layout(
            sizes: [
                CGSize(width: 70, height: 12),
                CGSize(width: 70, height: 30),
            ],
            width: 150
        )

        #expect(result.size == CGSize(width: 150, height: 30))
        #expect(result.points == [CGPoint(x: 0, y: 0), CGPoint(x: 80, y: 0)])
    }

    private func encodedVarint(_ value: UInt64) -> Data {
        var remaining = value
        var result = Data()
        repeat {
            var byte = UInt8(remaining & 0x7f)
            remaining >>= 7
            if remaining != 0 { byte |= 0x80 }
            result.append(byte)
        } while remaining != 0
        return result
    }

    private func cacheFootprint(_ store: DictationStore) throws -> (records: Int, blobBytes: Int) {
        var db: OpaquePointer?
        guard sqlite3_open(store.databasePath().path, &db) == SQLITE_OK else {
            throw NSError(domain: "InsightsTests", code: 1)
        }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*), COALESCE(SUM(length(token_blob)),0) FROM insights_record_cache", -1, &statement, nil) == SQLITE_OK else {
            throw NSError(domain: "InsightsTests", code: 2)
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw NSError(domain: "InsightsTests", code: 3) }
        return (Int(sqlite3_column_int(statement, 0)), Int(sqlite3_column_int(statement, 1)))
    }
}
