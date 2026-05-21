import Foundation

/// Normalises English text before phonemisation.
///
/// The pipeline is:
/// 1. Expand currency symbols (`$42M` → `forty-two million dollars`)
/// 2. Expand percentages (`42%` → `forty-two percent`)
/// 3. Expand ordinals (`3rd` → `third`)
/// 4. Expand plain numbers (`1984` → `one thousand nine hundred eighty-four`)
/// 5. Clean punctuation (strip HTML, normalise dashes)
/// 6. Collapse whitespace
enum TextPreprocessor {

    /// Apply the full normalisation pipeline to `text`.
    ///
    /// - Parameter text: Raw input text, e.g. as typed by the user.
    /// - Returns: Normalised text ready for ``Phonemizer/phonemize(_:)``.
    static func process(_ text: String) -> String {
        var t = text
        t = expandCurrency(t)
        t = expandPercentages(t)
        t = expandOrdinals(t)
        t = expandNumbers(t)
        t = cleanPunctuation(t)
        t = normaliseWhitespace(t)
        return t
    }

    // MARK: - Currency

    private static func expandCurrency(_ text: String) -> String {
        let pattern = #"([$€£¥])(\d+(?:[,\d]*\d)?(?:\.\d+)?)(K|M|B|T)?"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        var result = text
        for match in re.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let symbolRange     = match.range(at: 1)
            let amountRange     = match.range(at: 2)
            let multiplierRange = match.range(at: 3)

            let symbol     = symbolRange.location     != NSNotFound ? ns.substring(with: symbolRange)     : ""
            var amountStr  = amountRange.location     != NSNotFound ? ns.substring(with: amountRange)     : "0"
            let multiplier = multiplierRange.location != NSNotFound ? ns.substring(with: multiplierRange) : ""

            amountStr = amountStr.replacingOccurrences(of: ",", with: "")
            var amount = Double(amountStr) ?? 0

            let multiplierWord: String
            switch multiplier {
            case "K": amount *= 1_000;              multiplierWord = " thousand"
            case "M": amount *= 1_000_000;          multiplierWord = " million"
            case "B": amount *= 1_000_000_000;      multiplierWord = " billion"
            case "T": amount *= 1_000_000_000_000;  multiplierWord = " trillion"
            default:  multiplierWord = ""
            }

            let currencyName: String
            switch symbol {
            case "$": currencyName = amount == 1 ? " dollar" : " dollars"
            case "€": currencyName = amount == 1 ? " euro"   : " euros"
            case "£": currencyName = amount == 1 ? " pound"  : " pounds"
            case "¥": currencyName = " yen"
            default:  currencyName = ""
            }

            let words: String
            if amount == floor(amount) {
                words = numberToWords(Int(amount)) + multiplierWord + currencyName
            } else {
                let intPart  = numberToWords(Int(amount))
                let fracPart = amountStr.components(separatedBy: ".").last ?? ""
                let fracWords = fracPart.map { digitWord(String($0)) }.joined(separator: " ")
                words = intPart + " point " + fracWords + multiplierWord + currencyName
            }

            result = replaceRange(result, nsRange: match.range, with: words)
        }
        return result
    }

    // MARK: - Percentages

    private static func expandPercentages(_ text: String) -> String {
        let pattern = #"(\d+(?:\.\d+)?)\s*%"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        var result = text
        for match in re.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let numStr = ns.substring(with: match.range(at: 1))
            let words: String
            if let intVal = Int(numStr) {
                words = numberToWords(intVal) + " percent"
            } else if let dbl = Double(numStr) {
                let parts = numStr.components(separatedBy: ".")
                let intWords  = numberToWords(Int(dbl))
                let fracWords = (parts.last ?? "").map { digitWord(String($0)) }.joined(separator: " ")
                words = intWords + " point " + fracWords + " percent"
            } else {
                continue
            }
            result = replaceRange(result, nsRange: match.range, with: words)
        }
        return result
    }

    // MARK: - Ordinals

    private static let ordinalMap: [String: String] = [
        "1st": "first",    "2nd": "second",   "3rd": "third",    "4th": "fourth",
        "5th": "fifth",    "6th": "sixth",    "7th": "seventh",  "8th": "eighth",
        "9th": "ninth",    "10th": "tenth",   "11th": "eleventh","12th": "twelfth",
        "13th": "thirteenth","14th": "fourteenth","15th": "fifteenth",
        "16th": "sixteenth","17th": "seventeenth","18th": "eighteenth",
        "19th": "nineteenth","20th": "twentieth",
        "21st": "twenty-first","22nd": "twenty-second","23rd": "twenty-third",
        "30th": "thirtieth","40th": "fortieth","50th": "fiftieth",
        "100th": "one hundredth","1000th": "one thousandth",
    ]

    private static func expandOrdinals(_ text: String) -> String {
        let pattern = #"\b(\d+)(st|nd|rd|th)\b"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return text }
        let ns = text as NSString
        var result = text
        for match in re.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let full = ns.substring(with: match.range).lowercased()
            if let word = ordinalMap[full] {
                result = replaceRange(result, nsRange: match.range, with: word)
            } else {
                let num    = ns.substring(with: match.range(at: 1))
                let suffix = ns.substring(with: match.range(at: 2)).lowercased()
                if let n = Int(num) {
                    result = replaceRange(result, nsRange: match.range, with: numberToWords(n) + suffix)
                }
            }
        }
        return result
    }

    // MARK: - Numbers

    private static func expandNumbers(_ text: String) -> String {
        // Decimals first so "3.14" doesn't become "three .14"
        let decPattern = #"\b(\d+)\.(\d+)\b"#
        var t = text
        if let re = try? NSRegularExpression(pattern: decPattern) {
            let ns = t as NSString
            for match in re.matches(in: t, range: NSRange(location: 0, length: ns.length)).reversed() {
                let intPart  = ns.substring(with: match.range(at: 1))
                let fracPart = ns.substring(with: match.range(at: 2))
                let intWords  = numberToWords(Int(intPart) ?? 0)
                let fracWords = fracPart.map { digitWord(String($0)) }.joined(separator: " ")
                t = replaceRange(t, nsRange: match.range, with: intWords + " point " + fracWords)
            }
        }
        // Integers (with optional comma separators)
        let intPattern = #"\b\d{1,3}(?:,\d{3})*\b|\b\d+\b"#
        if let re = try? NSRegularExpression(pattern: intPattern) {
            let ns = t as NSString
            for match in re.matches(in: t, range: NSRange(location: 0, length: ns.length)).reversed() {
                let numStr = ns.substring(with: match.range).replacingOccurrences(of: ",", with: "")
                if let n = Int(numStr) {
                    t = replaceRange(t, nsRange: match.range, with: numberToWords(n))
                }
            }
        }
        return t
    }

    // MARK: - Cleanup

    private static func cleanPunctuation(_ text: String) -> String {
        var t = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: "–", with: "—")
             .replacingOccurrences(of: " - ", with: " — ")
        return t
    }

    private static func normaliseWhitespace(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Number to words

    /// Convert an integer to its English word representation.
    ///
    /// Handles negative numbers and values up to the trillions.
    static func numberToWords(_ n: Int) -> String {
        if n < 0  { return "negative " + numberToWords(-n) }
        if n == 0 { return "zero" }

        var result    = ""
        var remaining = n

        if remaining >= 1_000_000_000 {
            result += numberToWords(remaining / 1_000_000_000) + " billion "
            remaining %= 1_000_000_000
        }
        if remaining >= 1_000_000 {
            result += numberToWords(remaining / 1_000_000) + " million "
            remaining %= 1_000_000
        }
        if remaining >= 1_000 {
            result += numberToWords(remaining / 1_000) + " thousand "
            remaining %= 1_000
        }
        if remaining >= 100 {
            result += ones[remaining / 100] + " hundred "
            remaining %= 100
        }
        if remaining >= 20 {
            result += tens[remaining / 10]
            remaining %= 10
            if remaining > 0 { result += "-" + ones[remaining] }
        } else if remaining > 0 {
            result += ones[remaining]
        }

        return result.trimmingCharacters(in: .whitespaces)
    }

    private static let ones = [
        "", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine",
        "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen",
        "seventeen", "eighteen", "nineteen",
    ]
    private static let tens = [
        "", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety",
    ]

    private static func digitWord(_ d: String) -> String {
        switch d {
        case "0": return "zero"
        case "1": return "one"
        case "2": return "two"
        case "3": return "three"
        case "4": return "four"
        case "5": return "five"
        case "6": return "six"
        case "7": return "seven"
        case "8": return "eight"
        case "9": return "nine"
        default:  return d
        }
    }

    // MARK: - Helpers

    private static func replaceRange(_ s: String, nsRange: NSRange, with replacement: String) -> String {
        guard let range = Range(nsRange, in: s) else { return s }
        return s.replacingCharacters(in: range, with: replacement)
    }
}
