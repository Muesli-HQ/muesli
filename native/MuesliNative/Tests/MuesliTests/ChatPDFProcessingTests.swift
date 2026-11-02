import AppKit
import CoreText
import PDFKit
import Testing
@testable import MuesliCore
@testable import MuesliNativeApp

@Suite("Incremental PDF processing")
struct ChatPDFProcessingTests {
    static func pdf(at url: URL, pages: Int, linesPerPage: Int = 1, blankLastPage: Bool = false) throws {
        let data = NSMutableData()
        let consumer = try #require(CGDataConsumer(data: data))
        var box = CGRect(x: 0, y: 0, width: 600, height: 800)
        let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        for page in 1...pages {
            context.beginPDFPage(nil)
            for line in 0..<(blankLastPage && page == pages ? 0 : linesPerPage) {
                let content = "PAGE_\(page)_LINE_\(line) Synthetic café release document: launch Friday."
                let text = CTLineCreateWithAttributedString(NSAttributedString(string: content, attributes: [.font: NSFont(name: "Helvetica", size: 10)!]))
                context.textPosition = CGPoint(x: 20, y: 770 - line * 12); CTLineDraw(text, context)
            }
            context.endPDFPage()
        }
        context.closePDF()
        try (data as Data).write(to: url)
    }
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pdf-processing-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private var config: AppConfig {
        var config = AppConfig(); config.meetingSummaryBackend = "openai"; config.openAIModel = "gpt-6.1-sol"
        return config
    }

    @Test func reads289PagesIncludingTheLastWithoutCopyingOrUnneededModelCalls() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("long.pdf"); try Self.pdf(at: url, pages: 289)
        let files = try ChatFileReader.references(urls: [url], existing: [])
        let generator = PDFNotesProbe()
        let prepared = try await ChatPDFProcessing.prepare(files, config: config, question: "Summarize",
            budget: .init(config: config), generator: generator)
        #expect(prepared.context.contains("[Page 289]"))
        let lastPage = try #require(PDFDocument(url: url)?.page(at: 288)?.string).trimmingCharacters(in: .whitespacesAndNewlines)
        let containsLastPage = prepared.context.contains(lastPage)
        #expect(containsLastPage)
        #expect(prepared.documentCoverage == [.init(fileID: files[0].id, totalPages: 289, pagesWithoutText: 0, wasCondensed: false)])
        #expect(await generator.inputs.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["long.pdf"])
    }

    @Test func selectedContextControlsBatchesAndEveryPageIsProcessed() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("large.pdf"); try Self.pdf(at: url, pages: 95, linesPerPage: 30)
        let files = try ChatFileReader.references(urls: [url], existing: [])
        let smallBudget = MeetingChatContextBudget(config: config, contextWindowTokens: 32_768)
        let small = PDFNotesProbe()
        let result = try await ChatPDFProcessing.prepare(files, config: config, question: "Summarize release details",
            budget: smallBudget, generator: small)
        let inputs = await small.inputs
        #expect(inputs.count > 3)
        let allFragments = inputs.map { $0.user.components(separatedBy: "Next document fragment (quoted):\n").last ?? "" }.joined()
        let pdf = try #require(PDFDocument(url: url))
        let expectedText = try (0..<95).map { page in
            "\n[Page \(page + 1)]\n" + (try #require(pdf.page(at: page)?.string)).trimmingCharacters(in: .whitespacesAndNewlines)
        }.joined()
        let allTextDeliveredInOrder = allFragments == expectedText
        #expect(allTextDeliveredInOrder)
        #expect(inputs.allSatisfy { MeetingChatContextBudget.estimateTokens($0.system) + MeetingChatContextBudget.estimateTokens($0.user) <= smallBudget.documentRequestInputTokens })
        #expect(inputs.allSatisfy { $0.model == "gpt-6.1-sol" })
        #expect(result.documentCoverage.first?.wasCondensed == true)
        let outputBudget = try smallBudget.documentContextTokens(question: "Summarize release details", baseContext: "", imageCount: 0, historyReserve: 0)
        #expect(MeetingChatContextBudget.estimateTokens(result.context) <= outputBudget)
        let large = PDFNotesProbe()
        _ = try await ChatPDFProcessing.prepare(files, config: config, question: "Summarize release details", budget: .init(config: config), generator: large)
        #expect(await large.inputs.count < inputs.count)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["large.pdf"])
    }

    @Test func hugePageSplitsWithoutDroppingUnicodeScalars() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("page.pdf"); try Self.pdf(at: url, pages: 1, linesPerPage: 50)
        let file = try #require(ChatFileReader.references(urls: [url], existing: []).first)
        let reader = try ChatPDFPageReader(file: file)
        var text = ""; var fragments = 0
        while let fragment = try await reader.next(maximumTokens: 100) {
            #expect(MeetingChatContextBudget.estimateTokens(fragment.text) <= 100)
            text += fragment.text; fragments += 1
        }
        _ = try await reader.finish(); await reader.close()
        #expect(fragments > 10)
        #expect(text.contains("café"))
        let extracted = try #require(PDFDocument(url: url)?.page(at: 0)?.string).trimmingCharacters(in: .whitespacesAndNewlines)
        let completePage = text == "\n[Page 1]\n" + extracted
        #expect(completePage)
    }

    @Test func changedSourceDuringModelCallCannotPublishNotes() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("large.pdf"); try Self.pdf(at: url, pages: 95, linesPerPage: 30)
        let files = try ChatFileReader.references(urls: [url], existing: [])
        let probe = PDFNotesProbe(onGenerate: { var data = try Data(contentsOf: url); data.append(0); try data.write(to: url) })
        await #expect(throws: ChatFileError.changed) {
            try await ChatPDFProcessing.prepare(files, config: config, question: "Summarize", budget: .init(config: config), generator: probe)
        }
    }

    @Test func oversizedNotesHaveOneBoundedRetryAndNeverGetTruncated() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("large.pdf"); try Self.pdf(at: url, pages: 95, linesPerPage: 30)
        let files = try ChatFileReader.references(urls: [url], existing: [])
        let probe = PDFNotesProbe(reply: String(repeating: "x", count: 100_000))
        await #expect(throws: ChatPDFProcessingError.self) {
            try await ChatPDFProcessing.prepare(files, config: config, question: "Summarize", budget: .init(config: config), generator: probe)
        }
        #expect(await probe.inputs.count == 2)
    }

    @Test func cancellationBeforeReadNeverCallsModel() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("small.pdf"); try Self.pdf(at: url, pages: 1)
        let files = try ChatFileReader.references(urls: [url], existing: [])
        let probe = PDFNotesProbe(); let config = config
        let task = Task {
            try Task.checkCancellation()
            return try await ChatPDFProcessing.prepare(files, config: config, question: "Summarize", budget: .init(config: config), generator: probe)
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await probe.inputs.isEmpty)
    }

    @Test func textlessPageIsDisclosedWithoutClaimingItWasUnderstood() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("blank-page.pdf")
        try Self.pdf(at: url, pages: 2, blankLastPage: true)
        let files = try ChatFileReader.references(urls: [url], existing: [])
        let result = try await ChatPDFProcessing.prepare(files, config: config, question: "Summarize",
            budget: .init(config: config), generator: PDFNotesProbe())
        #expect(result.documentCoverage.first?.totalPages == 2)
        #expect(result.documentCoverage.first?.pagesWithoutText == 1)
        #expect(result.context.contains("1 pages had no recoverable text"))
    }

    @Test @MainActor func stopDuringPDFModelPreparationPreservesTheUnacceptedDraft() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("large.pdf"); try Self.pdf(at: url, pages: 95, linesPerPage: 30)
        let db = root.appendingPathComponent("fixture.db")
        let meetings = DictationStore(databaseURL: db); try meetings.migrateIfNeeded()
        let probe = PausedPDFNotesProbe()
        let chat = MeetingChatCoordinator(databaseURL: db, generator: probe)
        await chat.waitForIdle(); chat.startDraft(scope: .init(selection: .meetings([])))
        await chat.attachFiles([url]); chat.composerDraft = "Summarize the PDF"
        let undo = chat.composerUndoIdentity; let config = config
        let send = Task { await chat.send(question: chat.composerDraft, config: config) }
        await probe.waitForRequest()
        #expect(chat.isBusy)
        chat.stop()
        await probe.finish()
        await send.value
        #expect(!chat.isBusy && chat.selectedSessionID == nil)
        #expect(chat.composerDraft == "Summarize the PDF" && chat.composerUndoIdentity == undo)
        #expect(chat.composerFiles.count == 1)
        #expect(try chat.store.sessions().isEmpty)
        #expect(await probe.calls == 1)
    }

    @Test func catalogUsesTransportSpecificMetadataAndUnknownModelsRemainConservative() {
        #expect(MeetingChatContextBudget(config: config).documentRequestInputTokens == 922_000)
        var chatGPT = config; chatGPT.meetingSummaryBackend = "chatgpt"
        #expect(MeetingChatContextBudget(config: chatGPT).documentRequestInputTokens == 500_000 - 32_768)
        var unknown = config; unknown.meetingSummaryBackend = "custom_llm"; unknown.customLLMModel = "unknown"
        #expect(MeetingChatContextBudget(config: unknown).documentRequestInputTokens <= 32_768)
    }
}

private actor PDFNotesProbe: MeetingTextGenerating {
    struct Input: Sendable { let system: String; let user: String; let model: String }
    var inputs: [Input] = []
    let reply: String
    let onGenerate: @Sendable () throws -> Void
    init(reply: String = "Synthetic notes: release Friday; all supplied page fragments considered.", onGenerate: @escaping @Sendable () throws -> Void = {}) {
        self.reply = reply; self.onGenerate = onGenerate
    }
    func generate(_ request: MeetingTextGenerationRequest) async throws -> String {
        inputs.append(.init(system: request.system, user: request.user, model: MeetingTextGenerationClient.model(request.config)))
        try onGenerate()
        return reply
    }
}

private actor PausedPDFNotesProbe: MeetingTextGenerating {
    var calls = 0
    private var output: CheckedContinuation<String, Never>?
    private var waiter: CheckedContinuation<Void, Never>?
    func generate(_ request: MeetingTextGenerationRequest) async throws -> String {
        calls += 1
        return await withCheckedContinuation { continuation in
            output = continuation; waiter?.resume(); waiter = nil
        }
    }
    func waitForRequest() async {
        if output == nil { await withCheckedContinuation { waiter = $0 } }
    }
    func finish() { output?.resume(returning: "Late notes"); output = nil }
}
