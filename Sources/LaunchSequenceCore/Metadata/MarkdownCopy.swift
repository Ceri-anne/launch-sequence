import Foundation

/// One-time import of App Store copy kept in Markdown, where each field is a heading
/// like `## Subtitle (max 30)` or `### Subtitle (max 30)` followed by a fenced block,
/// and languages are sections headed `## <code> — <anything>`. A heading can also
/// carry both, as in `## en — What's New (max 4000)`. Headings without a fenced block
/// straight after them are ignored, so notes around the copy are fine.
public enum MarkdownCopy {
    static let fieldNames: [String: LocaleMetadata.Field] = [
        "app name": .name, "name": .name,
        "subtitle": .subtitle,
        "promotional text": .promotionalText,
        "keywords": .keywords,
        "description": .description,
        "what's new": .releaseNotes, "whats new": .releaseNotes, "release notes": .releaseNotes,
    ]

    /// Returns `[languageCode: [field: text]]`. Text before any language section belongs to `defaultLanguage`.
    public static func parse(_ markdown: String, defaultLanguage: String?) -> [String: [LocaleMetadata.Field: String]] {
        var result: [String: [LocaleMetadata.Field: String]] = [:]
        let lines = markdown.components(separatedBy: "\n")
        var language = defaultLanguage
        var i = 0
        let heading = try! NSRegularExpression(pattern: #"^(#{2,3}) (.+?)\s*$"#)
        let langPrefix = try! NSRegularExpression(pattern: #"^([A-Za-z]{2,3}(?:-[A-Za-z]{2,4})?) — (.+)$"#)
        let maxSuffix = try! NSRegularExpression(pattern: #"\s*\(max \d+[^)]*\)\s*$"#)

        func match(_ re: NSRegularExpression, _ s: String) -> [String]? {
            guard let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
            return (0..<m.numberOfRanges).map { Range(m.range(at: $0), in: s).map { String(s[$0]) } ?? "" }
        }

        while i < lines.count {
            guard let h = match(heading, lines[i]) else { i += 1; continue }
            let level = h[1].count
            var title = h[2]
            if let lp = match(langPrefix, title) {
                if level == 2 { language = lp[1] }
                title = lp[2]
            }
            let hasLimit = match(maxSuffix, title) != nil
            let fieldTitle = maxSuffix.stringByReplacingMatches(in: title, range: NSRange(title.startIndex..., in: title), withTemplate: "")
                .trimmingCharacters(in: .whitespaces).lowercased()
            i += 1
            guard hasLimit, let field = fieldNames[fieldTitle], let lang = language else { continue }
            // Expect a fence on the next non-blank line.
            var j = i
            while j < lines.count && lines[j].trimmingCharacters(in: .whitespaces).isEmpty { j += 1 }
            guard j < lines.count, lines[j].hasPrefix("```") else { continue }
            var body: [String] = []
            j += 1
            while j < lines.count && !lines[j].hasPrefix("```") { body.append(lines[j]); j += 1 }
            result[lang, default: [:]][field] = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            i = j + 1
        }
        return result
    }
}
