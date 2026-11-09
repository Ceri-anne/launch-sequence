import Foundation

public enum ReleaseNotesDraft {
    /// Subjects that are never user-facing, on top of the config's `release_notes.ignore`.
    static let builtInIgnore = [
        #"^(Merge|Revert) "#, #"^(chore|ci|docs|test|build|refactor)(\(.*\))?:"#, #"^Bump "#, #"^Release \d+\.\d+\.\d+"#,
    ]

    /// An English draft built from commit subjects since the last release. It's a starting
    /// point for the person to edit, not finished copy.
    public static func draft(subjects: [String], ignore: [String]) -> String {
        let patterns = (builtInIgnore + ignore).compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }
        var seen = Set<String>()
        let kept = subjects
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { s in !s.isEmpty && !patterns.contains { $0.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil } }
            .filter { seen.insert($0.lowercased()).inserted }
        if kept.isEmpty { return "- Bug fixes and improvements" }
        return kept.map { "- \($0)" }.joined(separator: "\n")
    }

    /// Text placed in a locale that still needs translating. Validation refuses to ship it.
    public static func todoStub(locale: String) -> String { "TODO: translate the release notes into \(locale)" }
}

public protocol Translating: Sendable {
    func translate(_ english: String, to locale: String, toneReference: String?, limit: Int) async throws -> String
}

/// Translates release notes with the Claude Messages API. The API key is read from
/// ANTHROPIC_API_KEY only, sent only to api.anthropic.com, and never logged. Only the
/// release notes (and the locale's existing description, for tone) are sent.
public struct ClaudeTranslator: Translating {
    let apiKey: String
    let model: String
    let transport: HTTPTransport
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    public init?(environment: [String: String] = ProcessInfo.processInfo.environment, model: String, transport: HTTPTransport = URLSessionTransport()) {
        guard let key = environment["ANTHROPIC_API_KEY"], !key.isEmpty else { return nil }
        self.apiKey = key; self.model = model; self.transport = transport
    }

    static func prompt(english: String, locale: String, toneReference: String?, limit: Int) -> String {
        var text = """
        Translate these App Store "What's New" release notes from English into the App Store locale \(locale).

        Keep the same meaning, structure and line breaks. Write natural, friendly copy a native speaker would expect on the App Store, not a literal translation. Keep it under \(limit) characters. Reply with the translated notes only: no preamble, quotes or explanations.
        """
        if let toneReference, !toneReference.isEmpty {
            text += "\n\nMatch the register and tone (formal or informal address, and so on) of the app's existing \(locale) description:\n<description>\n\(toneReference)\n</description>"
        }
        text += "\n\n<release_notes>\n\(english)\n</release_notes>"
        return text
    }

    public func translate(_ english: String, to locale: String, toneReference: String?, limit: Int) async throws -> String {
        let body: JSONValue = [
            "model": .string(model),
            "max_tokens": 16000,
            "fallbacks": "default",
            "messages": [["role": "user", "content": .string(Self.prompt(english: english, locale: locale, toneReference: toneReference, limit: limit))]],
        ]
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try body.data()
        request.timeoutInterval = 300

        let (data, response) = try await transport.send(request)
        guard response.statusCode == 200 else {
            let detail = (try? JSONValue.parse(data))?["error"]["message"].string ?? "HTTP \(response.statusCode)"
            throw LaunchError.command("Translation to \(locale) failed: \(detail)")
        }
        let doc = try JSONValue.parse(data)
        if doc["stop_reason"].string == "refusal" {
            throw LaunchError.command("Translation to \(locale) was declined; translate it by hand")
        }
        if doc["stop_reason"].string == "max_tokens" {
            throw LaunchError.command("Translation to \(locale) was cut off; translate it by hand")
        }
        let text = doc["content"].array.filter { $0["type"].string == "text" }.compactMap { $0["text"].string }.joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw LaunchError.command("Translation to \(locale) came back empty") }
        return text
    }
}
