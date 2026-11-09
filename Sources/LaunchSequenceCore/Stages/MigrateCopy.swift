import Foundation

/// One-time import of Markdown App Store copy into `<metadata_dir>/<asc-locale>/*.txt`.
public struct MigrateCopy: Sendable {
    let ctx: Context
    public init(ctx: Context) { self.ctx = ctx }

    public struct Source: Sendable {
        public var path: String
        /// Language for fields that sit before any `## <code> — ` section.
        public var defaultLanguage: String?
        public init(path: String, defaultLanguage: String?) { self.path = path; self.defaultLanguage = defaultLanguage }
    }

    /// Returns the files written (relative paths).
    @discardableResult
    public func run(sources: [Source], urls: [LocaleMetadata.Field: String], overwrite: Bool) throws -> [String] {
        let config = ctx.config
        var merged: [String: [LocaleMetadata.Field: String]] = [:]
        for source in sources {
            let url = try SafePath.resolve(source.path, under: ctx.root)
            let parsed = MarkdownCopy.parse(try String(contentsOf: url, encoding: .utf8), defaultLanguage: source.defaultLanguage)
            for (lang, fields) in parsed { merged[lang, default: [:]].merge(fields) { _, new in new } }
        }
        guard !merged.isEmpty else { throw LaunchError.precondition("No copy fields found. Headings must look like `### Subtitle (max 30)` followed by a fenced block.") }

        let dir = try SafePath.resolve(config.appStore.metadataDir, under: ctx.root)
        var written: [String] = []
        func write(_ text: String, to url: URL, relative: String) throws {
            if FileManager.default.fileExists(atPath: url.path) && !overwrite {
                ctx.console.warn("\(relative) exists, left alone (pass --overwrite to replace it)")
                return
            }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try (text + "\n").write(to: url, atomically: true, encoding: .utf8)
            written.append(relative)
        }

        for (code, fields) in merged.sorted(by: { $0.key < $1.key }) {
            guard let language = config.language(code: code) else { ctx.console.warn("Skipping \(code): not in `languages`"); continue }
            guard let locale = language.ascLocale else { ctx.console.warn("Skipping \(code): no App Store locale (`asc_locale`)"); continue }
            // Release notes belong to one release. Importing last release's would make them look
            // new to countdown (the files didn't exist at the last tag), so countdown drafts them instead.
            let importable = fields.filter { $0.key != .releaseNotes }
            if importable.count < fields.count { ctx.console.info("\(code): skipped What's New; countdown drafts it for the next release") }
            for (field, text) in importable.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                let rel = LocaleMetadata.path(metadataDir: config.appStore.metadataDir, locale: locale, field: field)
                try write(text, to: dir.appendingPathComponent(locale).appendingPathComponent(field.fileName), relative: rel)
            }
            ctx.console.ok("\(code) → \(locale): \(importable.count) field\(importable.count == 1 ? "" : "s")")
        }
        for (field, value) in urls {
            try write(value, to: dir.appendingPathComponent(field.fileName), relative: "\(config.appStore.metadataDir)/\(field.fileName)")
        }
        return written
    }
}
