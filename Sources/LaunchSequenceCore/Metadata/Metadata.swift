import Foundation

/// App Store copy for one App Store Connect locale, read from
/// `<metadata_dir>/<asc-locale>/<field>.txt`. URL fields can also sit at
/// `<metadata_dir>/<field>.txt` and apply to every locale.
public struct LocaleMetadata: Equatable, Sendable {
    public var locale: String
    public var fields: [Field: String]

    public enum Field: String, CaseIterable, Sendable {
        case name, subtitle
        case promotionalText = "promotional_text"
        case keywords, description
        case releaseNotes = "release_notes"
        case supportURL = "support_url"
        case marketingURL = "marketing_url"
        case privacyURL = "privacy_url"

        public var limit: Int? {
            switch self {
            case .name, .subtitle: return 30
            case .promotionalText: return 170
            case .keywords: return 100
            case .description, .releaseNotes: return 4000
            case .supportURL, .marketingURL, .privacyURL: return nil
            }
        }
        public var isURL: Bool { [.supportURL, .marketingURL, .privacyURL].contains(self) }
        public var fileName: String { rawValue + ".txt" }
        static let required: [Field] = [.name, .description, .keywords, .supportURL, .releaseNotes]
    }

    public subscript(field: Field) -> String? { fields[field] }

    /// Relative path of a field's file for this locale.
    public static func path(metadataDir: String, locale: String, field: Field) -> String {
        "\(metadataDir)/\(locale)/\(field.fileName)"
    }
}

public enum Metadata {
    public static func load(root: URL, metadataDir: String, locales: [String]) throws -> [LocaleMetadata] {
        let dir = try SafePath.resolve(metadataDir, under: root)
        return try locales.map { locale in
            var fields: [LocaleMetadata.Field: String] = [:]
            for field in LocaleMetadata.Field.allCases {
                let own = dir.appendingPathComponent(locale).appendingPathComponent(field.fileName)
                let shared = dir.appendingPathComponent(field.fileName)
                if let text = try read(own) ?? (field.isURL ? read(shared) : nil) { fields[field] = text }
            }
            return LocaleMetadata(locale: locale, fields: fields)
        }
    }

    static func read(_ url: URL) throws -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let text = try String(contentsOf: url, encoding: .utf8)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Problems that would make App Store Connect reject the copy, or ship something unfinished.
    public static func validate(_ all: [LocaleMetadata], requireReleaseNotes: Bool = true) -> [String] {
        var problems: [String] = []
        for m in all {
            for field in LocaleMetadata.Field.required where m[field] == nil {
                if field == .releaseNotes && !requireReleaseNotes { continue }
                problems.append("\(m.locale): \(field.fileName) is missing or empty")
            }
            for (field, value) in m.fields {
                if let limit = field.limit, value.count > limit {
                    problems.append("\(m.locale): \(field.fileName) is \(value.count) characters (max \(limit))")
                }
                if field.isURL {
                    guard let url = URL(string: value), url.scheme == "https", url.host != nil else {
                        problems.append("\(m.locale): \(field.fileName) must be an https URL")
                        continue
                    }
                }
                if value.range(of: #"\bTODO\b"#, options: .regularExpression) != nil {
                    problems.append("\(m.locale): \(field.fileName) still contains TODO")
                }
            }
            if let keywords = m[.keywords] {
                let parts = keywords.split(separator: ",", omittingEmptySubsequences: false)
                if parts.contains(where: { $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                    problems.append("\(m.locale): keywords.txt has an empty keyword")
                }
                if keywords.contains(", ") {
                    problems.append("\(m.locale): keywords.txt has spaces after commas, which count against the 100-character limit")
                }
                if keywords.contains("\n") {
                    problems.append("\(m.locale): keywords.txt must be one line")
                }
            }
            for field in [LocaleMetadata.Field.name, .subtitle] where m[field]?.contains("\n") == true {
                problems.append("\(m.locale): \(field.fileName) must be one line")
            }
        }
        return problems
    }
}
