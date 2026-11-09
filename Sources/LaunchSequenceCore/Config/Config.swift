import Foundation
import Yams

/// The per-app `.launchseq.yml`. It holds no secrets: credentials come from
/// the environment, `~/.config/launchseq/credentials` or the Keychain.
///
/// Decoding is strict: every struct rejects keys it doesn't know, so a typo
/// fails loudly instead of being silently ignored.
public struct Config: Codable, Sendable, Equatable {
    public var app: AppSection
    public var version: VersionSection
    public var test: TestSection
    public var languages: [Language]
    public var screenshots: ScreenshotsSection?
    public var appStore: AppStoreSection
    public var releaseNotes: ReleaseNotesSection
    public var website: WebsiteSection?
    public var privacySensitivePaths: [String]
    public var release: ReleaseSection

    enum CodingKeys: String, CodingKey, CaseIterable {
        case app, version, test, languages, screenshots
        case appStore = "app_store"
        case releaseNotes = "release_notes"
        case website
        case privacySensitivePaths = "privacy_sensitive_paths"
        case release
    }

    public init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        app = try c.decode(AppSection.self, forKey: .app)
        version = try c.decodeIfPresent(VersionSection.self, forKey: .version) ?? VersionSection()
        test = try c.decode(TestSection.self, forKey: .test)
        languages = try c.decode([Language].self, forKey: .languages)
        screenshots = try c.decodeIfPresent(ScreenshotsSection.self, forKey: .screenshots)
        appStore = try c.decode(AppStoreSection.self, forKey: .appStore)
        releaseNotes = try c.decodeIfPresent(ReleaseNotesSection.self, forKey: .releaseNotes) ?? ReleaseNotesSection()
        website = try c.decodeIfPresent(WebsiteSection.self, forKey: .website)
        privacySensitivePaths = try c.decodeIfPresent([String].self, forKey: .privacySensitivePaths) ?? []
        release = try c.decodeIfPresent(ReleaseSection.self, forKey: .release) ?? ReleaseSection()
        try validate()
    }

    public static let fileName = ".launchseq.yml"

    public static func load(from url: URL) throws -> Config {
        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw LaunchError.config("Couldn't read \(url.path): \(error.localizedDescription)")
        }
        return try parse(text)
    }

    public static func parse(_ yaml: String) throws -> Config {
        do {
            return try YAMLDecoder().decode(Config.self, from: yaml)
        } catch let error as LaunchError {
            throw error
        } catch let DecodingError.dataCorrupted(context) {
            // Yams wraps errors thrown by our own validation; surface those as they are.
            var underlying = context.underlyingError
            while let current = underlying {
                if let launch = current as? LaunchError { throw launch }
                if case DecodingError.dataCorrupted(let inner) = current { underlying = inner.underlyingError } else { break }
            }
            throw LaunchError.config(describe(context) + (context.underlyingError.map { ": \($0)" } ?? ""))
        } catch let DecodingError.keyNotFound(key, context) {
            throw LaunchError.config("Missing key `\(key.stringValue)` at \(path(context.codingPath))")
        } catch let DecodingError.typeMismatch(_, context) {
            throw LaunchError.config(describe(context))
        } catch let DecodingError.valueNotFound(_, context) {
            throw LaunchError.config(describe(context))
        } catch {
            throw LaunchError.config("Invalid \(fileName): \(error)")
        }
    }

    private static func path(_ codingPath: [CodingKey]) -> String {
        codingPath.isEmpty ? "the top level" : codingPath.map(\.stringValue).joined(separator: ".")
    }

    private static func describe(_ context: DecodingError.Context) -> String {
        "\(context.debugDescription) (at \(path(context.codingPath)))"
    }

    /// Checks that cross fields: unique names, safe relative paths, known references.
    func validate() throws {
        guard !languages.isEmpty else { throw LaunchError.config("`languages` must list at least one language") }
        let codes = languages.map(\.code)
        guard Set(codes).count == codes.count else { throw LaunchError.config("`languages` has duplicate codes") }
        for code in codes { try SafeName.check(code, field: "languages.code") }
        let ascLocales = languages.compactMap(\.ascLocale)
        guard Set(ascLocales).count == ascLocales.count else { throw LaunchError.config("Two languages map to the same `asc_locale`") }
        guard ascLocales.contains(appStore.primaryLocale) else {
            throw LaunchError.config("`app_store.primary_locale` (\(appStore.primaryLocale)) must be the `asc_locale` of one of `languages`")
        }
        try SafePath.checkRelative(appStore.metadataDir, field: "app_store.metadata_dir")
        try SafePath.checkRelative(version.file, field: "version.file")
        if let shots = screenshots {
            try SafePath.checkRelative(shots.rawDir, field: "screenshots.raw_dir")
            try SafePath.checkRelative(shots.outputDir, field: "screenshots.output_dir")
            let deviceNames = shots.devices.map(\.name)
            guard Set(deviceNames).count == deviceNames.count else { throw LaunchError.config("`screenshots.devices` has duplicate names") }
            for name in deviceNames { try SafeName.check(name, field: "screenshots.devices.name") }
            for scene in shots.scenes { try SafeName.check(scene.name, field: "screenshots.scenes.name") }
            for device in shots.devices {
                for code in device.languages ?? [] where !codes.contains(code) {
                    throw LaunchError.config("Device `\(device.name)` lists unknown language `\(code)`")
                }
                try SafePath.checkRelative(device.app, field: "screenshots.devices.app")
            }
        }
        if let site = website {
            try SafePath.checkRelative(site.source, field: "website.source")
            try SafePath.checkRelative(site.folder, field: "website.folder")
            guard site.repo.range(of: #"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil else {
                throw LaunchError.config("`website.repo` must look like owner/name")
            }
        }
        for pattern in releaseNotes.ignore {
            guard (try? NSRegularExpression(pattern: pattern)) != nil else {
                throw LaunchError.config("`release_notes.ignore` has an invalid regex: \(pattern)")
            }
        }
    }

    public func language(code: String) -> Language? { languages.first { $0.code == code } }
}

// MARK: - Sections

public struct AppSection: Codable, Sendable, Equatable {
    /// Human name, used in messages and branch names (e.g. "Star Chart").
    public var name: String
    /// Optional command run before any xcodebuild call, e.g. `[xcodegen, generate]`.
    public var generate: [String]?
    /// `.xcodeproj` or `.xcworkspace` path.
    public var project: String

    enum CodingKeys: String, CodingKey, CaseIterable { case name, generate, project }

    public init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        generate = try c.decodeIfPresent([String].self, forKey: .generate)
        project = try c.decode(String.self, forKey: .project)
        try SafePath.checkRelative(project, field: "app.project")
    }

    public var slug: String { Self.slug(for: name) }

    /// "Star Chart" → "star-chart".
    public static func slug(for name: String) -> String {
        name.lowercased().replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}

public struct VersionSection: Codable, Sendable, Equatable {
    /// File whose build setting holds the marketing version.
    public var file: String = "project.yml"
    /// Build setting name; every `KEY: value` occurrence in `file` is rewritten.
    public var key: String = "MARKETING_VERSION"

    enum CodingKeys: String, CodingKey, CaseIterable { case file, key }
    public init() {}
    public init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        file = try c.decodeIfPresent(String.self, forKey: .file) ?? "project.yml"
        key = try c.decodeIfPresent(String.self, forKey: .key) ?? "MARKETING_VERSION"
        guard key.range(of: #"^[A-Z_][A-Z0-9_]*$"#, options: .regularExpression) != nil else {
            throw LaunchError.config("`version.key` must be a build setting name like MARKETING_VERSION")
        }
    }
}

public struct Simulator: Codable, Sendable, Equatable {
    /// Device name as `simctl` lists it, e.g. "iPhone 17 Pro".
    public var name: String
    /// Runtime version, e.g. "27.2". Required: several runtimes can share a device name.
    public var os: String
    /// "iOS" or "watchOS".
    public var platform: String

    enum CodingKeys: String, CodingKey, CaseIterable { case name, os, platform }
    public init(name: String, os: String, platform: String = "iOS") {
        self.name = name; self.os = os; self.platform = platform
    }
    public init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        os = try c.decode(String.self, forKey: .os)
        platform = try c.decodeIfPresent(String.self, forKey: .platform) ?? "iOS"
        guard ["iOS", "watchOS", "tvOS", "visionOS"].contains(platform) else {
            throw LaunchError.config("Simulator platform must be iOS, watchOS, tvOS or visionOS, not \(platform)")
        }
        guard os.range(of: #"^\d+(\.\d+){0,2}$"#, options: .regularExpression) != nil else {
            throw LaunchError.config("Simulator os must be a version like 27.2, not \(os)")
        }
    }

    /// `xcodebuild -destination` value.
    public var destination: String { "platform=\(platform) Simulator,name=\(name),OS=\(os)" }
}

public struct TestSection: Codable, Sendable, Equatable {
    public var scheme: String
    public var simulator: Simulator

    enum CodingKeys: String, CodingKey, CaseIterable { case scheme, simulator }
    public init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        scheme = try c.decode(String.self, forKey: .scheme)
        simulator = try c.decode(Simulator.self, forKey: .simulator)
    }
}

public struct Language: Codable, Sendable, Equatable {
    /// The app's own language code and the folder name for screenshots, e.g. "fr".
    public var code: String
    /// `-AppleLocale` value used when capturing, e.g. "fr_FR".
    public var locale: String
    /// App Store Connect locale, e.g. "fr-FR". Omit for languages the App Store doesn't list (e.g. Welsh).
    public var ascLocale: String?

    enum CodingKeys: String, CodingKey, CaseIterable { case code, locale, ascLocale = "asc_locale" }
    public init(code: String, locale: String, ascLocale: String?) {
        self.code = code; self.locale = locale; self.ascLocale = ascLocale
    }
    public init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        code = try c.decode(String.self, forKey: .code)
        locale = try c.decode(String.self, forKey: .locale)
        ascLocale = try c.decodeIfPresent(String.self, forKey: .ascLocale)
        if let ascLocale { try SafeName.check(ascLocale, field: "languages.asc_locale") }
    }
}

public struct Build: Codable, Sendable, Equatable {
    public var scheme: String
    public var simulator: Simulator

    enum CodingKeys: String, CodingKey, CaseIterable { case scheme, simulator }
    public init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        scheme = try c.decode(String.self, forKey: .scheme)
        simulator = try c.decode(Simulator.self, forKey: .simulator)
    }
}

public struct Scene: Codable, Sendable, Equatable {
    /// File name without extension, e.g. "01-decide". Upload order is file-name order.
    public var name: String
    /// Extra launch arguments that open the app on this screen.
    public var args: [String]

    enum CodingKeys: String, CodingKey, CaseIterable { case name, args }
    public init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        args = try c.decodeIfPresent([String].self, forKey: .args) ?? []
    }
}

public struct Device: Codable, Sendable, Equatable {
    /// Folder name under `<lang>/`, e.g. "iPhone" or "iPhoneDuo-inner".
    public var name: String
    public var simulator: Simulator
    /// Path to the built `.app`, relative to the build products folder.
    public var app: String
    public var bundleId: String
    /// App Store Connect screenshot display type, e.g. APP_IPHONE_61. Omit to capture without uploading.
    public var displayType: String?
    /// Accepted rendered sizes as [width, height]. Defaults to the built-in table for `display_type`.
    public var sizes: [[Int]]?
    /// `simctl io screenshot --display` value, for multi-display devices.
    public var display: String?
    /// Manual step shown (and waited on) before this device is captured.
    public var before: String?
    /// Subset of language codes for this device; defaults to all.
    public var languages: [String]?
    public var settleSeconds: Double
    public var warmupSeconds: Double
    /// Extra `simctl status_bar <udid> override` arguments.
    public var statusBar: [String]

    enum CodingKeys: String, CodingKey, CaseIterable {
        case name, simulator, app
        case bundleId = "bundle_id"
        case displayType = "display_type"
        case sizes, display, before, languages
        case settleSeconds = "settle_seconds"
        case warmupSeconds = "warmup_seconds"
        case statusBar = "status_bar"
    }
    public init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        simulator = try c.decode(Simulator.self, forKey: .simulator)
        app = try c.decode(String.self, forKey: .app)
        bundleId = try c.decode(String.self, forKey: .bundleId)
        displayType = try c.decodeIfPresent(String.self, forKey: .displayType)
        sizes = try c.decodeIfPresent([[Int]].self, forKey: .sizes)
        display = try c.decodeIfPresent(String.self, forKey: .display)
        before = try c.decodeIfPresent(String.self, forKey: .before)
        languages = try c.decodeIfPresent([String].self, forKey: .languages)
        settleSeconds = try c.decodeIfPresent(Double.self, forKey: .settleSeconds) ?? 3
        warmupSeconds = try c.decodeIfPresent(Double.self, forKey: .warmupSeconds) ?? 0
        statusBar = try c.decodeIfPresent([String].self, forKey: .statusBar) ?? ["--time", "9:41"]
        if let sizes, sizes.contains(where: { $0.count != 2 }) {
            throw LaunchError.config("Device `\(name)` sizes must be [width, height] pairs")
        }
        if let displayType, displayType.range(of: #"^[A-Z0-9_]+$"#, options: .regularExpression) == nil {
            throw LaunchError.config("Device `\(name)` display_type looks wrong: \(displayType)")
        }
    }

    /// Sizes this device's rendered screenshots must have.
    public var acceptedSizes: [[Int]] {
        if let sizes { return sizes }
        guard let displayType else { return [] }
        return DisplayTypes.knownSizes[displayType] ?? []
    }
}

public struct ScreenshotsSection: Codable, Sendable, Equatable {
    public var rawDir: String
    public var outputDir: String
    /// Builds made (Debug, simulator) before capturing.
    public var builds: [Build]
    public var scenes: [Scene]
    public var devices: [Device]
    /// App hook that frames `raw_dir` into `output_dir`. Run with LAUNCHSEQ_RAW_DIR / LAUNCHSEQ_OUTPUT_DIR set.
    public var render: [String]?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case rawDir = "raw_dir", outputDir = "output_dir", builds, scenes, devices, render
    }
    public init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rawDir = try c.decode(String.self, forKey: .rawDir)
        outputDir = try c.decode(String.self, forKey: .outputDir)
        builds = try c.decodeIfPresent([Build].self, forKey: .builds) ?? []
        scenes = try c.decode([Scene].self, forKey: .scenes)
        devices = try c.decode([Device].self, forKey: .devices)
        render = try c.decodeIfPresent([String].self, forKey: .render)
    }
}

public struct AppStoreSection: Codable, Sendable, Equatable {
    public var bundleId: String
    /// Numeric App Store Connect app ID. Looked up by bundle ID when omitted.
    public var appId: String?
    public var platform: String
    public var metadataDir: String
    public var primaryLocale: String
    /// MANUAL, AFTER_APPROVAL or SCHEDULED.
    public var releaseType: String
    public var phasedRelease: Bool
    public var buildTimeoutMinutes: Int

    enum CodingKeys: String, CodingKey, CaseIterable {
        case bundleId = "bundle_id", appId = "app_id", platform
        case metadataDir = "metadata_dir", primaryLocale = "primary_locale"
        case releaseType = "release_type", phasedRelease = "phased_release"
        case buildTimeoutMinutes = "build_timeout_minutes"
    }
    public init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bundleId = try c.decode(String.self, forKey: .bundleId)
        appId = try c.decodeIfPresent(String.self, forKey: .appId)
        platform = try c.decodeIfPresent(String.self, forKey: .platform) ?? "IOS"
        metadataDir = try c.decodeIfPresent(String.self, forKey: .metadataDir) ?? "AppStoreAssets/metadata"
        primaryLocale = try c.decode(String.self, forKey: .primaryLocale)
        releaseType = try c.decodeIfPresent(String.self, forKey: .releaseType) ?? "MANUAL"
        phasedRelease = try c.decodeIfPresent(Bool.self, forKey: .phasedRelease) ?? true
        buildTimeoutMinutes = try c.decodeIfPresent(Int.self, forKey: .buildTimeoutMinutes) ?? 90
        guard ["MANUAL", "AFTER_APPROVAL", "SCHEDULED"].contains(releaseType) else {
            throw LaunchError.config("`app_store.release_type` must be MANUAL, AFTER_APPROVAL or SCHEDULED")
        }
        if let appId, appId.range(of: #"^\d+$"#, options: .regularExpression) == nil {
            throw LaunchError.config("`app_store.app_id` must be numeric")
        }
    }
}

public struct ReleaseNotesSection: Codable, Sendable, Equatable {
    /// Regexes; commit subjects matching any are left out of the English draft.
    public var ignore: [String] = []
    /// Claude model used to translate release notes. Translation is skipped without ANTHROPIC_API_KEY.
    public var translationModel: String = "claude-opus-5-5"

    enum CodingKeys: String, CodingKey, CaseIterable { case ignore, translationModel = "translation_model" }
    public init() {}
    public init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ignore = try c.decodeIfPresent([String].self, forKey: .ignore) ?? []
        translationModel = try c.decodeIfPresent(String.self, forKey: .translationModel) ?? "claude-opus-5-5"
    }
}

public struct WebsiteSection: Codable, Sendable, Equatable {
    /// GitHub repo, owner/name.
    public var repo: String
    public var branch: String
    /// Folder in the website repo the pages go into, e.g. "star-chart".
    public var folder: String
    /// Folder in the app repo the pages are authored in, e.g. "website".
    public var source: String

    enum CodingKeys: String, CodingKey, CaseIterable { case repo, branch, folder, source }
    public init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        repo = try c.decode(String.self, forKey: .repo)
        branch = try c.decodeIfPresent(String.self, forKey: .branch) ?? "main"
        folder = try c.decode(String.self, forKey: .folder)
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? "website"
        try GitRef.checkBranch(branch)
    }
}

public struct ReleaseSection: Codable, Sendable, Equatable {
    /// Base branch the release PR targets and the tag is cut from.
    public var baseBranch: String = "main"
    /// Release PR branch prefix; the version is appended.
    public var branchPrefix: String = "release/"

    enum CodingKeys: String, CodingKey, CaseIterable { case baseBranch = "base_branch", branchPrefix = "branch_prefix" }
    public init() {}
    public init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        baseBranch = try c.decodeIfPresent(String.self, forKey: .baseBranch) ?? "main"
        branchPrefix = try c.decodeIfPresent(String.self, forKey: .branchPrefix) ?? "release/"
        try GitRef.checkBranch(baseBranch)
        try GitRef.checkBranch(branchPrefix + "0.0.0")
    }
}
