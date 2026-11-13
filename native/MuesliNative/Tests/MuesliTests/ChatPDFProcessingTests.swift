import AppKit
import CoreText
import PDFKit
import Testing
@testable import MuesliCore
@testable import MuesliNativeApp

@Suite("On-demand attachment tools")
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
        context.closePDF(); try (data as Data).write(to: url)
    }
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("document-tools-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private var config: AppConfig {
        var c = AppConfig(); c.meetingSummaryBackend = "openai"; c.openAIModel = "gpt-6.1-sol"; return c
    }
    private var evidence: MeetingChatEvidence {
        .init(scope: .init(selection: .meetings([])), passages: [], dependencies: [],
            coverage: .init(eligibleMeetingCount: 0, evidenceMeetingCount: 0, isPartialRecap: false))
    }
    private func object(_ result: ChatDocumentResult) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Any])
    }

    @Test func documentToolsReportOnlyRequestedSourceKindsOncePerAttempt() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let urls = ["previous.txt", "unused.md"].map { root.appendingPathComponent($0) }
        for url in urls { try Data("Synthetic content".utf8).write(to: url) }
        let refs = try ChatFileReader.references(urls: urls, existing: [])
        let file = try #require(refs.first { $0.kind == .text })
        let recorder = ProductAnalyticsTests.Recorder()
        let emitter = ProductAnalyticsEmitter(consent: { recorder.token() }) { event, _ in recorder.record(event) }
        let attempt = AnalyticsAttempt(.chat, emitter: emitter)
        let tools = ChatDocumentTools(files: refs, supportsVision: false, analytics: attempt)
        _ = try await tools.execute(.inspect("unknown"))
        _ = try await tools.execute(.inspect(file.id))
        _ = try await tools.execute(.read(file.id, 1, 0))
        emitter.drain()
        #expect(recorder.events.filter { $0.kind == .source_used }.map(\.parameters) == [
            ["product.schema": "1", "source": "text"]
        ])
    }

    @Test func metadataPreparationMakesNoModelCallsOrStoredExtractionsEvenFor289Pages() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("large.pdf"); try Self.pdf(at: url, pages: 289, linesPerPage: 30)
        let refs = try ChatFileReader.references(urls: [url], existing: [])
        let probe = DocumentLoopProbe(native: false, id: refs[0].id)
        let prepared = try await ChatPDFProcessing.prepare(refs, config: config, question: "Summarize",
            budget: .init(config: config, contextWindowTokens: 8_192), generator: probe)
        #expect(prepared.documents == refs)
        #expect(!prepared.context.contains("PAGE_1"))
        #expect(prepared.context.contains("metadata only"))
        #expect(prepared.documentCoverage.isEmpty)
        #expect(await probe.textRequests.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["large.pdf"])
        let tools = ChatDocumentTools(files: refs, supportsVision: true)
        let metadata = try object(await tools.execute(.inspect(refs[0].id)))
        #expect(metadata["total_pages"] as? Int == 289)
        let last = try object(await tools.execute(.read(refs[0].id, 289, 0)))
        #expect((last["text"] as? String)?.contains("PAGE_289_LINE_0") == true)
    }

    @Test func searchReportsScannedRangesAndContinuesPastEmptyBatches() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("long.pdf"); try Self.pdf(at: url, pages: 140)
        let refs = try ChatFileReader.references(urls: [url], existing: [])
        let tools = ChatDocumentTools(files: refs, supportsVision: false)
        let first = try object(await tools.execute(.search(refs[0].id, "PAGE_140_LINE", 1)))
        #expect((first["matches"] as? [[String: Any]])?.isEmpty == true)
        #expect(first["scanned_through_page"] as? Int == 64)
        #expect(first["next_page"] as? Int == 65)
        let last = try object(await tools.execute(.search(refs[0].id, "PAGE_140_LINE", 129)))
        #expect((last["matches"] as? [[String: Any]])?.first?["page"] as? Int == 140)
        #expect(last["next_page"] is NSNull)
        #expect(last["partial_coverage"] as? Bool == true)
    }

    @Test func longUnicodeTextCanBeReadWithoutDroppingScalarsOrTruncatingSilently() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("notes.md")
        let content = String(repeating: "Café ✅ document\n", count: 600)
        try Data(content.utf8).write(to: url)
        let refs = try ChatFileReader.references(urls: [url], existing: [])
        let tools = ChatDocumentTools(files: refs, supportsVision: false, maximumTextBytes: 700)
        var offset = 0; var reconstructed = ""
        while true {
            let result = try object(await tools.execute(.read(refs[0].id, 1, offset)))
            let text = try #require(result["text"] as? String)
            #expect(text.utf8.count <= 700); reconstructed += text
            guard let next = result["next_offset"] as? Int else { break }
            #expect(next > offset); offset = next
        }
        #expect(reconstructed == content)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["notes.md"])
    }

    @Test func unknownIDsRangesMutationsAndCancellationCannotDiscloseOtherFiles() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("private.txt"); try Data("synthetic secret".utf8).write(to: url)
        let refs = try ChatFileReader.references(urls: [url], existing: [])
        let tools = ChatDocumentTools(files: refs, supportsVision: false)
        let unknown = try await tools.execute(.read(String(repeating: "0", count: 64), 1, 0))
        #expect(!unknown.output.contains("synthetic secret")); #expect(unknown.output.contains("unknown_document"))
        #expect(try await tools.execute(.read(refs[0].id, 2, 0)).output.contains("page_out_of_range"))
        #expect(try await tools.execute(.read(refs[0].id, 1, 999)).output.contains("offset_out_of_range"))
        let cancelled = Task { try await Task.sleep(for: .milliseconds(100)); return try await tools.execute(.inspect(refs[0].id)) }
        cancelled.cancel(); await #expect(throws: CancellationError.self) { try await cancelled.value }
        try Data("changed document".utf8).write(to: url)
        await #expect(throws: ChatFileError.changed) { try await tools.execute(.read(refs[0].id, 1, 0)) }
    }

    @Test func renderingIsVisionScopedBoundedAndNeverWrittenToDisk() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("diagram.pdf"); try Self.pdf(at: url, pages: 4)
        let refs = try ChatFileReader.references(urls: [url], existing: [])
        let textOnly = ChatDocumentTools(files: refs, supportsVision: false)
        #expect(try await textOnly.execute(.render(refs[0].id, 1)).output.contains("vision_unavailable"))
        let tools = ChatDocumentTools(files: refs, supportsVision: true)
        for page in 1...3 {
            let result = try await tools.execute(.render(refs[0].id, page))
            #expect(result.images.count == 1); #expect(result.images[0].data.count <= 1_024 * 1_024)
        }
        #expect(try await tools.execute(.render(refs[0].id, 4)).output.contains("render_budget_exhausted"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["diagram.pdf"])
    }

    @Test func oversizedPageImagesReturnToolErrorsAndLeaveTextReadsAvailable() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("diagram.pdf"); try Self.pdf(at: url, pages: 1, linesPerPage: 30)
        let refs = try ChatFileReader.references(urls: [url], existing: [])
        let tools = ChatDocumentTools(files: refs, supportsVision: true, maximumImageBytes: 1)
        // A failed render does not consume the successful-render budget.
        for _ in 1...4 {
            let result = try await tools.execute(.render(refs[0].id, 1))
            #expect(try object(result)["error"] as? String == "render_too_large")
            #expect(result.images.isEmpty)
        }
        let read = try object(await tools.execute(.read(refs[0].id, 1, 0)))
        #expect((read["text"] as? String)?.contains("PAGE_1_LINE_0") == true)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await tools.execute(.render(refs[0].id, 1))
        }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["diagram.pdf"])
    }

    @Test(arguments: [true, false]) @MainActor
    func fileOnlyChatInvokesDocumentToolsAndReplaysResults(_ native: Bool) async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("notes.txt"); try Data("The verification phrase is cobalt lantern.".utf8).write(to: url)
        let refs = try ChatFileReader.references(urls: [url], existing: [])
        let reader = ChatDocumentTools(files: refs, supportsVision: false)
        let probe = DocumentLoopProbe(native: native, id: refs[0].id)
        let prepared = try await ChatPDFProcessing.prepare(refs, config: config, question: "Read the phrase",
            budget: .init(config: config), generator: probe)
        let (answer, _) = try await MeetingChatClient.run(question: "Read the phrase", evidence: evidence,
            history: [], config: config, sessionID: UUID(), generator: probe, execute: { call, current in
                guard case .document(let request) = call else { Issue.record("Unexpected meeting tool"); return .init(evidence: current) }
                let result = try await reader.execute(request)
                return .init(evidence: current, documentOutput: result.output, images: result.images)
            }, activity: { _, _ in }, attachments: prepared)
        #expect(answer.markdown.contains("cobalt lantern"))
        if native {
            let requests = await probe.nativeRequests
            #expect(requests.count == 2 && requests[0].allowTools)
            let first = String(decoding: requests[0].inputItems, as: UTF8.self)
            #expect(!first.contains("cobalt lantern"))
            #expect(String(decoding: requests[0].tools, as: UTF8.self).contains("read_document"))
            #expect(!String(decoding: requests[0].tools, as: UTF8.self).contains("search_history"))
            #expect(String(decoding: requests[1].inputItems, as: UTF8.self).contains("cobalt lantern"))
        } else {
            let requests = await probe.textRequests
            #expect(requests.count == 2)
            #expect(!requests[0].user.contains("cobalt lantern"))
            #expect(requests[1].user.contains("cobalt lantern"))
        }
    }

    @Test @MainActor func followupsRetainOriginalDocumentCapabilitiesWithAnEmptyComposer() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("notes.md"); try Data("# Original\nLaunch Friday".utf8).write(to: url)
        let refs = try ChatFileReader.references(urls: [url], existing: [])
        let database = root.appendingPathComponent("test.sqlite")
        let store = DictationStore(databaseURL: database); try store.migrateIfNeeded()
        let worker = MeetingChatWorker(databaseURL: database)
        let session = try await worker.createChat(scope: .init(selection: .meetings([])))
        let first = try await worker.beginTurn(sessionID: session.id, question: "Discuss file", scope: session.scope, config: config, attemptID: UUID(), files: refs)
        _ = try await worker.store.finishTurn(turnID: first.id, answer: "Synthetic answer", citations: [], dependencies: [], attemptID: first.attemptID)
        let next = try await worker.beginTurn(sessionID: session.id, question: "Read more", scope: session.scope, config: config, attemptID: UUID())
        let inherited = try await worker.inheritedDocuments(.empty, turn: next)
        #expect(inherited.documents == refs); #expect(next.fileAttachments == nil)
        #expect(inherited.context.contains(refs[0].id))
    }

    @Test func requestedPageRangesResumeWithoutDroppingPagesOrExceedingOutputBudget() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("ranges.pdf"); try Self.pdf(at: url, pages: 12, linesPerPage: 30)
        let refs = try ChatFileReader.references(urls: [url], existing: [])
        let tools = ChatDocumentTools(files: refs, supportsVision: false, maximumTextBytes: 8_000)
        var page = 3; var offset = 0; var text = ""; var calls = 0
        while true {
            let output = try object(await tools.execute(.read(refs[0].id, page, offset, endPage: 10)))
            let fragment = try #require(output["text"] as? String)
            #expect(fragment.utf8.count <= 8_000); text += fragment; calls += 1
            if output["requested_range_complete"] as? Bool == true { break }
            let nextPage = try #require(output["next_page"] as? Int)
            let nextOffset = try #require(output["next_offset"] as? Int)
            #expect(nextPage > page || nextOffset > offset)
            page = nextPage; offset = nextOffset
            #expect(calls < 20)
        }
        for page in 3...10 { #expect(text.contains("PAGE_\(page)_LINE_29")) }
        #expect(!text.contains("PAGE_2_LINE") && !text.contains("PAGE_11_LINE"))
        #expect(calls < 8)
    }

    @Test(arguments: [true, false]) @MainActor
    func pageImagesAreLabeledAndReplayedInsideTheExistingProviderLoop(_ native: Bool) async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("chart.pdf"); try Self.pdf(at: url, pages: 1)
        let refs = try ChatFileReader.references(urls: [url], existing: [])
        let reader = ChatDocumentTools(files: refs, supportsVision: true)
        let probe = DocumentLoopProbe(native: native, id: refs[0].id, render: true)
        let prepared = try await ChatPDFProcessing.prepare(refs, config: config, question: "Look at page 1",
            budget: .init(config: config), generator: probe)
        _ = try await MeetingChatClient.run(question: "Look at page 1", evidence: evidence,
            history: [], config: config, sessionID: UUID(), generator: probe, execute: { call, current in
                guard case .document(let request) = call else { return .init(evidence: current) }
                let result = try await reader.execute(request)
                return .init(evidence: current, documentOutput: result.output, images: result.images)
            }, activity: { _, _ in }, attachments: prepared)
        if native {
            let requests = await probe.nativeRequests
            let body = try MeetingNativeToolTransport.requestBody(requests[1], stream: false)
            let serialized = String(decoding: try JSONSerialization.data(withJSONObject: body), as: UTF8.self)
            #expect(serialized.contains("input_image") && serialized.contains("chart.pdf"))
            #expect(serialized.contains("function_call_output"))
        } else {
            let requests = await probe.textRequests
            #expect(requests[0].images.isEmpty)
            #expect(requests[1].images.count == 1)
            #expect(requests[1].images[0].name.contains("chart.pdf"))
        }
    }

    @Test(arguments: [true, false]) @MainActor
    func oversizedDocumentResultsFinalizeWithoutSilentlyDroppingEarlierContext(_ native: Bool) async throws {
        let id = String(repeating: "b", count: 64)
        let file = ChatFileReference(id: id, name: "budget.pdf", kind: .pdf, bookmark: Data(), byteCount: 100)
        let prepared = PreparedChatFiles(context: try ChatDocumentTools.manifest([file]), documents: [file])
        let probe = DocumentLoopProbe(native: native, id: id)
        _ = try await MeetingChatClient.run(question: "Read", evidence: evidence,
            history: [], config: config, sessionID: UUID(), generator: probe,
            execute: { _, current in .init(evidence: current, documentOutput: String(repeating: "x", count: 150_000)) },
            activity: { _, _ in }, contextBudget: .init(config: config, contextWindowTokens: 32_768), attachments: prepared)
        if native {
            let requests = await probe.nativeRequests
            #expect(requests.count == 2 && !requests[1].allowTools)
            #expect(String(decoding: requests[1].inputItems, as: UTF8.self).contains("budget_exhausted"))
        } else {
            let requests = await probe.textRequests
            #expect(requests.count == 2)
            #expect(requests[1].system.contains("Retrieval tools are unavailable"))
            #expect(requests[1].user.contains("budget_exhausted"))
        }
    }

    @Test func documentArgumentsRejectPathsExtraFieldsBooleansAndFractionalPages() throws {
        let id = String(repeating: "a", count: 64)
        for args in ["{\"document_id\":\"/etc/passwd\",\"page\":1,\"offset\":0}",
                     "{\"document_id\":\"\(id)\",\"page\":true,\"offset\":0}",
                     "{\"document_id\":\"\(id)\",\"page\":1.5,\"offset\":0}",
                     "{\"document_id\":\"\(id)\",\"page\":1,\"offset\":0,\"path\":\"x\"}"] {
            #expect(throws: (any Error).self) { try MeetingChatNativeHarness.call(name: "read_document", arguments: args) }
        }
        #expect(try MeetingChatNativeHarness.call(name: "read_document", arguments: "{\"document_id\":\"\(id)\",\"page\":289,\"offset\":0}") == .document(.read(id, 289, 0)))
    }
}

private actor DocumentLoopProbe: MeetingTextGenerating {
    let native: Bool; let id: String; let render: Bool
    private(set) var textRequests: [MeetingTextGenerationRequest] = []
    private(set) var nativeRequests: [MeetingNativeToolRequest] = []
    init(native: Bool, id: String, render: Bool = false) { self.native = native; self.id = id; self.render = render }
    private var name: String { render ? "render_document_page" : "read_document" }
    private var arguments: String { render ? "{\"document_id\":\"\(id)\",\"page\":1}" : "{\"document_id\":\"\(id)\",\"page\":1,\"offset\":0,\"end_page\":null}" }
    nonisolated func supportsNativeTools(config: AppConfig) -> Bool { native }
    func generate(_ request: MeetingTextGenerationRequest) async throws -> String {
        textRequests.append(request)
        if textRequests.count == 1 {
            var payload = try #require(JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? [String: Any]); payload["tool"] = name
            return String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
        }
        return #"{"status":"conversation","markdown":"The phrase is cobalt lantern (notes.txt, page 1)."}"#
    }
    func generateNative(_ request: MeetingNativeToolRequest) async throws -> MeetingNativeToolResponse {
        nativeRequests.append(request)
        if nativeRequests.count == 1 {
            let args = arguments
            let output: [[String: Any]] = [["type": "function_call", "name": name, "call_id": "doc-1", "arguments": args]]
            return .init(outputItems: try JSONSerialization.data(withJSONObject: output), calls: [.init(id: "doc-1", name: name, arguments: args)], text: "")
        }
        return .init(outputItems: Data("[]".utf8), calls: [], text: #"{"status":"conversation","markdown":"The phrase is cobalt lantern (notes.txt, page 1)."}"#)
    }
}
