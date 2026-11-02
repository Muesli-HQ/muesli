import AppKit
import Foundation
import CoreText
import PDFKit
import Testing
@testable import MuesliCore
@testable import MuesliNativeApp

@Suite("Chat file attachments")
struct ChatAttachmentTests {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chat-files-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func image(at url: URL) throws {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8,
                                   samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.setColor(.red, atX: 0, y: 0)
        try #require(rep.representation(using: .png, properties: [:])).write(to: url)
    }
    private func pdf(at url: URL, pages: Int = 1) throws {
        let data = NSMutableData()
        let consumer = try #require(CGDataConsumer(data: data))
        var box = CGRect(x: 0, y: 0, width: 300, height: 200)
        let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        for _ in 0..<pages {
        context.beginPDFPage(nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Synthetic document: launch Friday.", attributes: [.font: NSFont.systemFont(ofSize: 14)]))
        context.textPosition = CGPoint(x: 20, y: 100); CTLineDraw(line, context)
        context.endPDFPage()
        }
        context.closePDF()
        try (data as Data).write(to: url)
    }

    @Test func largePDFStillGetsABoundedPreview() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("large.pdf"); try pdf(at: original, pages: 51)
        let refs = try ChatFileReader.references(urls: [original], existing: [])
        var config = AppConfig(); config.meetingSummaryBackend = "openai"
        let worker = MeetingChatWorker(databaseURL: root.appendingPathComponent("unused.db"))
        let data = try #require(await worker.thumbnail(for: refs[0]))
        #expect(data.count <= ChatFileReader.maximumThumbnailBytes)
        let bitmap = try #require(NSBitmapImageRep(data: data))
        #expect(bitmap.pixelsWide <= 320 && bitmap.pixelsHigh <= 320)
        #expect(await worker.thumbnail(for: refs[0]) == data)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["large.pdf"])
        try FileManager.default.removeItem(at: original)
        #expect(await worker.thumbnail(for: refs[0]) == nil)
    }

    @Test @MainActor func missingOriginalPreservesDraftAndNeverCallsAI() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("large.pdf"); try pdf(at: original, pages: 51)
        let database = root.appendingPathComponent("fixture.db")
        let meetings = DictationStore(databaseURL: database); try meetings.migrateIfNeeded()
        let probe = AttachmentReplyProbe()
        let chat = MeetingChatCoordinator(databaseURL: database, generator: probe)
        await chat.waitForIdle(); chat.startDraft(scope: .init(selection: .meetings([])))
        await chat.attachFiles([original]); chat.composerDraft = "Summarize this document"
        try FileManager.default.removeItem(at: original)
        let undo = chat.composerUndoIdentity
        var config = AppConfig(); config.meetingSummaryBackend = "openai"
        await chat.send(question: chat.composerDraft, config: config)
        #expect(chat.errorMessage == ChatFileError.unavailable.localizedDescription)
        #expect(chat.errorMessage?.contains("connection") == false)
        #expect(chat.composerDraft == "Summarize this document")
        #expect(chat.composerUndoIdentity == undo)
        #expect(chat.composerFiles.count == 1)
        #expect(chat.selectedSessionID == nil && !chat.isBusy)
        #expect(try chat.store.sessions().isEmpty)
        #expect(await probe.imageCounts.isEmpty)
    }

    @Test func reattachedOriginalStartsWithCurrentFileDependencies() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("notes.pdf"); try pdf(at: original)
        let database = root.appendingPathComponent("fixture.db")
        let meetings = DictationStore(databaseURL: database); try meetings.migrateIfNeeded()
        let worker = MeetingChatWorker(databaseURL: database)
        let store = await worker.store
        let session = try store.createSession(scope: .init(selection: .meetings([])), title: "New chat")
        let oldFiles = try ChatFileReader.references(urls: [original], existing: [])
        var config = AppConfig(); config.meetingSummaryBackend = "openai"
        let old = try await worker.beginTurn(sessionID: session.id, question: "Old file", scope: session.scope, config: config, attemptID: UUID(), files: oldFiles)
        #expect(try store.finishTurn(turnID: old.id, answer: "Old version", citations: [], dependencies: []))
        var bytes = try Data(contentsOf: original); bytes.append(0); try bytes.write(to: original)
        let currentFiles = try ChatFileReader.references(urls: [original], existing: oldFiles)
        let current = try await worker.beginTurn(sessionID: session.id, question: "New file", scope: session.scope, config: config, attemptID: UUID(), files: currentFiles)
        #expect(try store.turns(sessionID: session.id).first?.state == .sourceDeleted)
        #expect(current.fileDependencies == currentFiles)
        _ = try await worker.evidence(for: current)
        #expect(try store.finishTurn(turnID: current.id, answer: "New version", citations: [], dependencies: []))
    }

    @Test @MainActor func attachmentFailuresKeepTheirActionableMessages() {
        for error in [ChatFileError.tooLarge, .unavailable, .changed, .unreadablePDF, .unreadableText, .unsupportedProvider] {
            #expect(MeetingChatCoordinator.failureMessage(error) == error.localizedDescription)
        }
    }

    @Test func deduplicatesBytesAndPersistsOnlyReferenceMetadata() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("image.png"); try image(at: original)
        let duplicate = root.appendingPathComponent("duplicate.png"); try FileManager.default.copyItem(at: original, to: duplicate)
        let refs = try ChatFileReader.references(urls: [original, duplicate, original], existing: [])
        #expect(refs.count == 1)
        let before = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        var config = AppConfig(); config.meetingSummaryBackend = "openai"
        let prepared = try ChatFileReader.prepareNonPDF(refs, config: config)
        #expect(prepared.images.count == 1)
        #expect(prepared.images[0].data.count <= 2 * 1_024 * 1_024)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() == before)
        let encoded = try JSONEncoder().encode(refs)
        let decoded = try JSONDecoder().decode([ChatFileReference].self, from: encoded)
        #expect(decoded == refs)
        let json = try #require(JSONSerialization.jsonObject(with: encoded) as? [[String: Any]])
        #expect(Set(json[0].keys) == ["id", "name", "kind", "bookmark", "byteCount"])
    }

    @Test(arguments: ["md", "markdown", "txt", "MD"])
    func textFilesStayReferencedAndWorkWithoutVision(_ suffix: String) throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("notes." + suffix)
        let content = "# Synthetic notes\n\nCafé ✅ launch Friday.\n![remote](https://example.invalid/image.png)"
        var bytes = Data([0xEF, 0xBB, 0xBF]); bytes.append(Data(content.utf8)); try bytes.write(to: original)
        let refs = try ChatFileReader.references(urls: [original, original], existing: [])
        #expect(refs.count == 1)
        #expect(refs[0].kind == (suffix.lowercased() == "txt" ? .text : .markdown))
        var config = AppConfig(); config.meetingSummaryBackend = "ollama"
        let prepared = try ChatFileReader.prepareNonPDF(refs, config: config)
        #expect(prepared.images.isEmpty)
        #expect(prepared.context.contains(content))
        #expect(!prepared.context.contains("\u{FEFF}"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == [original.lastPathComponent])
        let data = try JSONEncoder().encode(refs)
        #expect(try JSONDecoder().decode([ChatFileReference].self, from: data) == refs)
    }

    @Test func invalidOrOversizedTextFailsWithoutSilentlyReplacingBytes() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("notes.txt")
        var config = AppConfig(); config.meetingSummaryBackend = "ollama"
        for bytes in [Data([0xff]), Data("bad\0text".utf8), Data(" \n".utf8)] {
            try bytes.write(to: original)
            let refs = try ChatFileReader.references(urls: [original], existing: [])
            #expect(throws: ChatFileError.unreadableText) { try ChatFileReader.prepareNonPDF(refs, config: config) }
        }
        try Data(repeating: 65, count: ChatFileReader.maximumContextCharacters + 1).write(to: original)
        let refs = try ChatFileReader.references(urls: [original], existing: [])
        #expect(throws: ChatFileError.tooLarge) { try ChatFileReader.prepareNonPDF(refs, config: config) }
        try Data(repeating: 65, count: ChatFileReader.maximumTextBytes + 1).write(to: original)
        #expect(throws: ChatFileError.tooLarge) { try ChatFileReader.references(urls: [original], existing: []) }
    }

    @Test func originalBookmarksFollowRenamesAndReadLegacyScopedRecords() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("image.png"); try image(at: original)
        let file = try #require(ChatFileReader.references(urls: [original], existing: []).first)
        let legacy = ChatFileReference(id: file.id, name: file.name, kind: file.kind,
            bookmark: try original.bookmarkData(options: .withSecurityScope), byteCount: file.byteCount)
        try ChatFileReader.validate([legacy])
        let renamed = root.appendingPathComponent("renamed.png")
        try FileManager.default.moveItem(at: original, to: renamed)
        try ChatFileReader.validate([file])
        try ChatFileReader.validate([legacy])
        #expect(try ChatFileReader.resolve(file).standardizedFileURL == renamed.standardizedFileURL)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["renamed.png"])
    }

    @Test func changedOriginalRequiresReattachmentAndDoesNotDuplicateItsSlot() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("image.png"); try image(at: original)
        let refs = try ChatFileReader.references(urls: [original], existing: [])
        var bytes = try Data(contentsOf: original); bytes.append(0); try bytes.write(to: original)
        #expect(throws: ChatFileError.self) { try ChatFileReader.validate(refs) }
        let updated = try ChatFileReader.references(urls: [original], existing: refs)
        #expect(updated.count == 1 && updated[0].id != refs[0].id)
        try ChatFileReader.validate(updated)
        try FileManager.default.removeItem(at: original)
        #expect(throws: ChatFileError.unavailable) { try ChatFileReader.validate(updated) }
    }

    @Test func pdfTextWorksWithoutVisionAndNeverCreatesAStoredExtraction() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("notes.pdf"); try pdf(at: original)
        let refs = try ChatFileReader.references(urls: [original], existing: [])
        var config = AppConfig(); config.meetingSummaryBackend = "ollama"
        let prepared = try await ChatPDFProcessing.prepare(refs, config: config, question: "Summarize",
            budget: .init(config: config), generator: AttachmentReplyProbe())
        #expect(prepared.context.contains("launch Friday"))
        #expect(prepared.context.contains("text/OCR only"))
        #expect(prepared.images.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["notes.pdf"])
    }

    @Test func limitsAndProviderChecksRejectBeforeTransmission() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("image.png"); try image(at: original)
        let refs = try ChatFileReader.references(urls: [original], existing: [])
        var config = AppConfig(); config.meetingSummaryBackend = "ollama"
        #expect(throws: ChatFileError.unsupportedProvider) { try ChatFileReader.prepareNonPDF(refs, config: config) }
        #expect(throws: ChatFileError.tooMany) { try ChatFileReader.validateLimits(Array(repeating: refs[0], count: 4)) }
        let oversized = ChatFileReference(id: "fixture", name: "large.pdf", kind: .pdf, bookmark: Data(), byteCount: ChatFileReader.maximumFileBytes + 1)
        #expect(throws: ChatFileError.tooLarge) { try ChatFileReader.validateLimits([oversized]) }
    }

    @Test func providerPayloadsUseInlineImagesAndKeepTextOnlyCallsCompatible() throws {
        let image = ChatImageInput(name: "fixture.png", data: Data([1, 2, 3]))
        for backend in ["openai", "openrouter", "anthropic"] {
            var config = AppConfig(); config.meetingSummaryBackend = backend
            config.openAIModel = "gpt-4o"
            let request = MeetingTextGenerationRequest(system: "fixture", user: "describe", config: config, images: [image])
            let wire = try MeetingTextGenerationClient.makeRequest(request, credential: "synthetic")
            let body = String(decoding: try #require(wire.httpBody), as: UTF8.self)
            #expect(body.contains(image.data.base64EncodedString()))
            #expect(!body.contains("file_id"))
            if backend == "openai" { #expect(body.contains("input_image")) }
            if backend == "anthropic" {
                let bodyData = try #require(wire.httpBody)
                let json = try #require(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
                let messages = try #require(json["messages"] as? [[String: Any]])
                let content = try #require(messages[0]["content"] as? [[String: Any]])
                let source = try #require(content.last?["source"] as? [String: Any])
                #expect(source["media_type"] as? String == "image/jpeg")
            }
            let plain = try MeetingTextGenerationClient.makeRequest(.init(system: "fixture", user: "plain", config: config), credential: "synthetic")
            #expect(!String(decoding: try #require(plain.httpBody), as: UTF8.self).contains("input_image"))
        }
    }

    @Test func fileDependenciesSurviveRemovalAndInvalidateInheritedAnswers() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("image.png"); try image(at: original)
        let refs = try ChatFileReader.references(urls: [original], existing: [])
        let database = root.appendingPathComponent("fixture.db")
        let meetings = DictationStore(databaseURL: database); try meetings.migrateIfNeeded()
        let worker = MeetingChatWorker(databaseURL: database)
        let chat = await worker.store
        let session = try chat.createSession(scope: .init(selection: .meetings([])), title: "New chat")
        try chat.setFileAttachments(sessionID: session.id, files: refs)
        var config = AppConfig(); config.meetingSummaryBackend = "openai"
        let first = try await worker.beginTurn(sessionID: session.id, question: "describe", scope: session.scope, config: config, attemptID: UUID(), files: refs)
        #expect(try chat.finishTurn(turnID: first.id, answer: "Synthetic red image", citations: [], dependencies: []))
        try chat.setFileAttachments(sessionID: session.id, files: [])
        let second = try await worker.beginTurn(sessionID: session.id, question: "shorten it", scope: session.scope, config: config, attemptID: UUID())
        #expect(second.fileDependencies == refs)
        #expect(try chat.finishTurn(turnID: second.id, answer: "Red", citations: [], dependencies: []))
        #expect(try chat.updateTitleIfAutomatic(turnID: second.id, attemptID: try #require(second.attemptID), title: "Image summary"))
        #expect(try chat.sessions().first?.fileAttachments == nil)
        #expect(FileManager.default.fileExists(atPath: original.path))
        try FileManager.default.removeItem(at: original)
        let history = try await worker.history(selecting: session.id)
        #expect(history.turns.count == 2)
        for turn in history.turns {
            #expect(turn.state == .sourceDeleted)
            #expect(turn.originalAnswer == nil)
        }
        #expect(history.sessions.first?.title == "New chat")
        #expect(try chat.historyContext(before: second).turns.isEmpty)
        #expect(try chat.finishTurn(turnID: second.id, answer: "Late response", citations: [], dependencies: []) == false)
    }
    @Test(arguments: ["png", "md", "txt"]) @MainActor
    func fileOnlySendReopensReferencesAndPreservesDraftAcrossNavigation(_ suffix: String) async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("attachment." + suffix)
        if suffix == "png" { try image(at: original) }
        else { try "# Synthetic file\nLaunch Friday.".write(to: original, atomically: true, encoding: .utf8) }
        let imageCount = suffix == "png" ? 1 : 0
        let database = root.appendingPathComponent("fixture.db")
        let meetings = DictationStore(databaseURL: database); try meetings.migrateIfNeeded()
        let probe = AttachmentReplyProbe()
        let chat = MeetingChatCoordinator(databaseURL: database, generator: probe)
        await chat.waitForIdle()
        chat.startDraft(scope: .init(selection: .meetings([])))
        await chat.attachFiles([original])
        #expect(chat.composerFiles.count == 1)
        var config = AppConfig(); config.meetingSummaryBackend = "openai"
        await chat.send(question: "", config: config)
        await chat.waitForIdle()
        let sessionID = try #require(chat.selectedSessionID)
        #expect(chat.turns.first?.state == .completed)
        #expect(chat.turns.first?.question == "Describe the attached files.")
        #expect(chat.scope.selection == .meetings([]))
        #expect(await probe.imageCounts == [imageCount])
        chat.composerDraft = "Keep my text"
        let undo = chat.composerUndoIdentity
        chat.showIndex(); chat.selectChat(id: sessionID); await chat.waitForIdle()
        #expect(chat.composerDraft == "Keep my text")
        #expect(chat.composerUndoIdentity == undo)
        #expect(chat.composerFiles.count == 1)
        let reopened = MeetingChatCoordinator(databaseURL: database, generator: probe)
        await reopened.waitForIdle(); reopened.selectChat(id: sessionID); await reopened.waitForIdle()
        #expect(reopened.composerFiles.count == 1)
        await reopened.removeFile(try #require(reopened.composerFiles.first?.id))
        #expect(reopened.composerFiles.isEmpty)
        #expect(reopened.turns.first?.originalAnswer != nil)
        #expect(FileManager.default.fileExists(atPath: original.path))
        config.meetingSummaryBackend = "anthropic"
        await reopened.send(question: "Shorten that", config: config); await reopened.waitForIdle()
        #expect(reopened.turns.last?.state == .completed)
        #expect(await probe.imageCounts == [imageCount, 0])
        await reopened.deleteChat(id: sessionID)
        #expect(FileManager.default.fileExists(atPath: original.path))
    }

}


private actor AttachmentReplyProbe: MeetingTextGenerating {
    var imageCounts: [Int] = []
    func generate(_ request: MeetingTextGenerationRequest) async throws -> String {
        imageCounts.append(request.images.count)
        return #"{"status":"conversation","markdown":"Synthetic file response."}"#
    }
}
