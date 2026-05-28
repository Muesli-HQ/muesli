import Foundation

enum DictionaryImportParser {
    static func parse(_ text: String, defaultThreshold: Double = 0.88) -> [CustomWord] {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .compactMap { parseLine($0, defaultThreshold: defaultThreshold) }
    }

    private static func parseLine(_ line: String, defaultThreshold: Double) -> CustomWord? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
        guard !isHeader(trimmed) else { return nil }

        let parts = splitLine(trimmed)
        let rawWord = parts.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !rawWord.isEmpty else { return nil }

        let rawReplacement = parts.dropFirst().first?.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawThreshold = parts.dropFirst(2).first?.trimmingCharacters(in: .whitespacesAndNewlines)
        let threshold = rawThreshold.flatMap(Double.init) ?? defaultThreshold

        return CustomWord(
            word: rawWord,
            replacement: rawReplacement?.isEmpty == false ? rawReplacement : nil,
            matchingThreshold: threshold
        )
    }

    private static func splitLine(_ line: String) -> [String] {
        if line.contains("=>") {
            return line.components(separatedBy: "=>")
        }
        if line.contains("->") {
            return line.components(separatedBy: "->")
        }
        if line.contains("\t") {
            return line.components(separatedBy: "\t")
        }
        if line.contains(",") {
            return parseCSVLine(line)
        }
        return [line]
    }

    private static func parseCSVLine(_ line: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var inQuotes = false
        var iterator = line.makeIterator()
        while let char = iterator.next() {
            if char == "\"" {
                if inQuotes, let next = iterator.next() {
                    if next == "\"" {
                        current.append("\"")
                    } else {
                        inQuotes = false
                        if next == "," {
                            parts.append(current)
                            current = ""
                        } else {
                            current.append(next)
                        }
                    }
                } else {
                    inQuotes.toggle()
                }
            } else if char == ",", !inQuotes {
                parts.append(current)
                current = ""
            } else {
                current.append(char)
            }
        }
        parts.append(current)
        return parts
    }

    private static func isHeader(_ line: String) -> Bool {
        let normalized = line
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
        return normalized == "word"
            || normalized.hasPrefix("word,replacement")
            || normalized.hasPrefix("term,replacement")
            || normalized.hasPrefix("phrase,replacement")
    }
}
