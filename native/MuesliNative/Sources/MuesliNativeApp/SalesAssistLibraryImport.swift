import Foundation
import MuesliCore

enum SalesAssistImportError: LocalizedError {
    case unsupportedFile
    case unreadableFile
    case noObjectionsFound
    case invalidJSON

    var errorDescription: String? {
        switch self {
        case .unsupportedFile:
            return "Use a .txt, .md, .csv, or .json file."
        case .unreadableFile:
            return "The file could not be read as text."
        case .noObjectionsFound:
            return "No objection cards were found."
        case .invalidJSON:
            return "The JSON did not match the objection import format."
        }
    }
}

enum SalesAssistLibraryImport {
    static func text(from url: URL) throws -> String {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16)
        else {
            throw SalesAssistImportError.unreadableFile
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func objections(from url: URL) throws -> [SalesAssistObjection] {
        let text = try text(from: url)
        switch url.pathExtension.lowercased() {
        case "json":
            return try objectionsFromJSON(text)
        case "csv":
            return try objectionsFromCSV(text)
        default:
            throw SalesAssistImportError.unsupportedFile
        }
    }

    static func objectionsFromJSON(_ text: String) throws -> [SalesAssistObjection] {
        guard let data = text.data(using: .utf8) else {
            throw SalesAssistImportError.invalidJSON
        }
        let object = try JSONSerialization.jsonObject(with: data)
        let rows: [[String: Any]]
        if let array = object as? [[String: Any]] {
            rows = array
        } else if let wrapped = object as? [String: Any],
                  let array = wrapped["objections"] as? [[String: Any]] {
            rows = array
        } else {
            throw SalesAssistImportError.invalidJSON
        }

        let objections = rows.compactMap(objection(from:))
        guard !objections.isEmpty else { throw SalesAssistImportError.noObjectionsFound }
        return objections
    }

    static func objectionsFromCSV(_ text: String) throws -> [SalesAssistObjection] {
        let rows = parseCSV(text)
        guard let header = rows.first else { throw SalesAssistImportError.noObjectionsFound }
        let normalizedHeader = header.map(normalizedKey)
        let objections = rows.dropFirst().compactMap { row -> SalesAssistObjection? in
            var dict: [String: String] = [:]
            for (index, key) in normalizedHeader.enumerated() where index < row.count {
                dict[key] = row[index]
            }
            let name = dict["name"] ?? dict["objection"] ?? dict["category"] ?? ""
            let triggers = dict["trigger_phrases"] ?? dict["triggers"] ?? dict["trigger"] ?? dict["phrases"] ?? ""
            let guidance = dict["guidance"] ?? dict["talk_track"] ?? dict["response"] ?? dict["handling"] ?? ""
            let priority = normalizedPriority(dict["priority"] ?? "medium")
            guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  (!triggers.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                   || !guidance.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            else {
                return nil
            }
            return SalesAssistObjection(
                name: name,
                priority: priority,
                triggerPhrases: normalizeTriggerText(triggers),
                guidance: guidance
            )
        }
        guard !objections.isEmpty else { throw SalesAssistImportError.noObjectionsFound }
        return objections
    }

    private static func objection(from row: [String: Any]) -> SalesAssistObjection? {
        let name = stringValue(row["name"] ?? row["objection"] ?? row["category"])
        let priority = normalizedPriority(stringValue(row["priority"]) ?? "medium")
        let guidance = stringValue(row["guidance"] ?? row["talk_track"] ?? row["response"] ?? row["handling"]) ?? ""
        let triggerValue = row["trigger_phrases"] ?? row["triggers"] ?? row["trigger"] ?? row["phrases"]
        let triggers: String
        if let array = triggerValue as? [String] {
            triggers = array.joined(separator: "\n")
        } else {
            triggers = stringValue(triggerValue) ?? ""
        }

        guard let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (!triggers.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
               || !guidance.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        else {
            return nil
        }

        return SalesAssistObjection(
            name: name,
            priority: priority,
            triggerPhrases: normalizeTriggerText(triggers),
            guidance: guidance
        )
    }

    private static func parseCSV(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var iterator = text.makeIterator()

        while let char = iterator.next() {
            if char == "\"" {
                if inQuotes, let next = iterator.next() {
                    if next == "\"" {
                        field.append("\"")
                    } else {
                        inQuotes = false
                        if next == "," {
                            row.append(field)
                            field = ""
                        } else if next == "\n" {
                            row.append(field)
                            rows.append(row)
                            row = []
                            field = ""
                        } else {
                            field.append(next)
                        }
                    }
                } else {
                    inQuotes.toggle()
                }
            } else if char == ",", !inQuotes {
                row.append(field)
                field = ""
            } else if char == "\n", !inQuotes {
                row.append(field)
                rows.append(row)
                row = []
                field = ""
            } else if char != "\r" {
                field.append(char)
            }
        }

        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }

        return rows
            .map { $0.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } }
            .filter { !$0.allSatisfy(\.isEmpty) }
    }

    private static func normalizedKey(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "-", with: "_")
    }

    private static func normalizedPriority(_ raw: String) -> String {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "high", "low":
            return raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        default:
            return "medium"
        }
    }

    private static func normalizeTriggerText(_ value: String) -> String {
        value
            .components(separatedBy: CharacterSet(charactersIn: "\n,;"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private static func stringValue(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            return string
        case let number as NSNumber:
            return number.stringValue
        default:
            return nil
        }
    }
}

actor SalesAssistObjectionExtractor {
    private static let whamURL = URL(string: "https://chatgpt.com/backend-api/wham/responses")!
    private static let model = "gpt-5.4-mini"

    func extract(from notes: String) async throws -> [SalesAssistObjection] {
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SalesAssistImportError.noObjectionsFound }
        let text = try await callWHAM(userPrompt: """
        Extract sales objection cards from these notes.

        Return only JSON in this shape:
        {
          "objections": [
            {
              "name": "Short category name",
              "priority": "high|medium|low",
              "trigger_phrases": ["phrase one", "phrase two"],
              "guidance": "What the rep should say or do next."
            }
          ]
        }

        Notes:
        \(trimmed)
        """)
        let json = try Self.extractJSONObject(from: text)
        return try SalesAssistLibraryImport.objectionsFromJSON(json)
    }

    private func callWHAM(userPrompt: String) async throws -> String {
        let (token, accountId) = try await ChatGPTAuthManager.shared.validAccessToken()
        let body: [String: Any] = [
            "model": Self.model,
            "store": false,
            "stream": true,
            "instructions": "You turn messy sales notes into concise structured sales objection cards. Return strict JSON only.",
            "input": [
                [
                    "role": "user",
                    "content": [
                        ["type": "input_text", "text": userPrompt],
                    ],
                ] as [String: Any],
            ],
        ]

        var request = URLRequest(url: Self.whamURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if !accountId.isEmpty {
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard httpStatus == 200 else {
            var errorData = Data()
            for try await byte in bytes {
                errorData.append(byte)
            }
            let message = String(data: errorData, encoding: .utf8) ?? HTTPURLResponse.localizedString(forStatusCode: httpStatus)
            throw NSError(domain: "SalesAssistObjectionExtractor", code: httpStatus, userInfo: [NSLocalizedDescriptionKey: message])
        }

        var fullText = ""
        for try await line in bytes.lines {
            guard line.hasPrefix("data: ") else { continue }
            let jsonString = String(line.dropFirst(6))
            if jsonString == "[DONE]" { break }
            guard let data = jsonString.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if let outputText = json["output_text"] as? String, !outputText.isEmpty {
                fullText = outputText
            }
            if let type = json["type"] as? String,
               type == "response.output_text.delta",
               let delta = json["delta"] as? String {
                fullText += delta
            }
        }
        return fullText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func extractJSONObject(from text: String) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{"), trimmed.hasSuffix("}") { return trimmed }
        let withoutFence = trimmed
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if withoutFence.hasPrefix("{"), withoutFence.hasSuffix("}") { return withoutFence }
        guard let start = withoutFence.firstIndex(of: "{"),
              let end = withoutFence.lastIndex(of: "}"),
              start < end else {
            throw SalesAssistImportError.invalidJSON
        }
        return String(withoutFence[start...end])
    }
}

actor SalesAssistCallLearningAnalyzer {
    private static let whamURL = URL(string: "https://chatgpt.com/backend-api/wham/responses")!
    private static let model = "gpt-5.4-mini"

    func analyze(meeting: MeetingRecord, config: AppConfig) async throws -> [SalesAssistLearningSuggestion] {
        let transcript = meeting.rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else { throw SalesAssistImportError.noObjectionsFound }
        let text = try await callWHAM(userPrompt: Self.prompt(
            meetingTitle: meeting.title,
            transcript: transcript,
            knowledgeBase: config.salesAssistKnowledgeBase,
            existingObjections: config.salesAssistObjections
        ))
        let json = try Self.extractJSONObject(from: text)
        return try Self.decodeSuggestions(from: json, sourceTitle: meeting.title)
    }

    private static func prompt(
        meetingTitle: String,
        transcript: String,
        knowledgeBase: String,
        existingObjections: [SalesAssistObjection]
    ) -> String {
        let objectionNames = existingObjections.map(\.name).joined(separator: ", ")
        return """
        Analyze this sales call transcript for useful Sales Assist learning.

        Existing knowledge base:
        \(knowledgeBase.prefix(6000))

        Existing objection categories:
        \(objectionNames)

        Return only JSON:
        {
          "suggestions": [
            {
              "kind": "knowledge_base",
              "title": "Short title",
              "content": "Concise durable knowledge to add to the KB.",
              "reason": "Why this is worth saving."
            },
            {
              "kind": "objection",
              "title": "Short objection category",
              "content": "Why this objection matters.",
              "reason": "Evidence from the call.",
              "objection": {
                "name": "Category name",
                "priority": "high|medium|low",
                "trigger_phrases": ["phrase one", "phrase two"],
                "guidance": "What the rep should say or do next."
              }
            }
          ]
        }

        Only return 0-5 high-signal suggestions. Do not duplicate existing categories unless the call adds a genuinely better trigger or talk track. Prefer durable learnings over call-specific trivia.

        Meeting title: \(meetingTitle)

        Transcript:
        \(transcript.prefix(18000))
        """
    }

    private func callWHAM(userPrompt: String) async throws -> String {
        let (token, accountId) = try await ChatGPTAuthManager.shared.validAccessToken()
        let body: [String: Any] = [
            "model": Self.model,
            "store": false,
            "stream": true,
            "instructions": "You identify durable sales KB learnings and objection cards from sales call transcripts. Return strict JSON only.",
            "input": [
                [
                    "role": "user",
                    "content": [
                        ["type": "input_text", "text": userPrompt],
                    ],
                ] as [String: Any],
            ],
        ]

        var request = URLRequest(url: Self.whamURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if !accountId.isEmpty {
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard httpStatus == 200 else {
            var errorData = Data()
            for try await byte in bytes { errorData.append(byte) }
            let message = String(data: errorData, encoding: .utf8) ?? HTTPURLResponse.localizedString(forStatusCode: httpStatus)
            throw NSError(domain: "SalesAssistCallLearningAnalyzer", code: httpStatus, userInfo: [NSLocalizedDescriptionKey: message])
        }

        var fullText = ""
        for try await line in bytes.lines {
            guard line.hasPrefix("data: ") else { continue }
            let jsonString = String(line.dropFirst(6))
            if jsonString == "[DONE]" { break }
            guard let data = jsonString.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if let outputText = json["output_text"] as? String, !outputText.isEmpty {
                fullText = outputText
            }
            if let type = json["type"] as? String,
               type == "response.output_text.delta",
               let delta = json["delta"] as? String {
                fullText += delta
            }
        }
        return fullText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeSuggestions(from json: String, sourceTitle: String) throws -> [SalesAssistLearningSuggestion] {
        guard let data = json.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = object["suggestions"] as? [[String: Any]]
        else {
            throw SalesAssistImportError.invalidJSON
        }

        let suggestions = rows.compactMap { row -> SalesAssistLearningSuggestion? in
            let kindRaw = row["kind"] as? String ?? ""
            let kind = SalesAssistLearningSuggestion.SuggestionKind(rawValue: kindRaw) ?? .knowledgeBase
            let title = row["title"] as? String ?? ""
            let content = row["content"] as? String ?? ""
            let reason = row["reason"] as? String ?? ""
            guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  (!content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                   || row["objection"] != nil)
            else {
                return nil
            }
            let objection: SalesAssistObjection?
            if let objectionRow = row["objection"] as? [String: Any] {
                objection = Self.objection(from: objectionRow)
            } else {
                objection = nil
            }
            return SalesAssistLearningSuggestion(
                kind: kind,
                title: title,
                content: content,
                reason: reason,
                sourceTitle: sourceTitle,
                objection: objection
            )
        }

        guard !suggestions.isEmpty else { throw SalesAssistImportError.noObjectionsFound }
        return suggestions
    }

    private static func objection(from row: [String: Any]) -> SalesAssistObjection? {
        let name = row["name"] as? String ?? ""
        let priority = row["priority"] as? String ?? "medium"
        let guidance = row["guidance"] as? String ?? ""
        let triggers: String
        if let array = row["trigger_phrases"] as? [String] {
            triggers = array.joined(separator: "\n")
        } else {
            triggers = row["trigger_phrases"] as? String ?? ""
        }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return SalesAssistObjection(name: name, priority: priority, triggerPhrases: triggers, guidance: guidance)
    }

    private static func extractJSONObject(from text: String) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{"), trimmed.hasSuffix("}") { return trimmed }
        let withoutFence = trimmed
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if withoutFence.hasPrefix("{"), withoutFence.hasSuffix("}") { return withoutFence }
        guard let start = withoutFence.firstIndex(of: "{"),
              let end = withoutFence.lastIndex(of: "}"),
              start < end else {
            throw SalesAssistImportError.invalidJSON
        }
        return String(withoutFence[start...end])
    }
}
