import Foundation

/// What `launchseq init` could work out about an app repo.
public struct RepoFacts: Sendable, Equatable {
    public var appName: String
    public var project: String
    public var generate: [String]?
    public var versionFile: String
    public var scheme: String
    public var bundleId: String?
    public var simulator: Simulator
    public var githubOwner: String?
    /// Things a person has to check or fill in, shown after the file is written.
    public var notes: [String] = []
}

/// Drafts a starter `.launchseq.yml`. Gathering and rendering are pure so they can be tested
/// without a real repo; `Init` does the reading and writing.
public enum InitDraft {
    /// - Parameters:
    ///   - files: names at the repo root.
    ///   - read: reads a file by repo-relative path, or nil if it can't.
    ///   - schemes: from `xcodebuild -list -json`, when the project exists to ask.
    ///   - simulators: `xcrun simctl list devices --json` output.
    ///   - remoteURL: `git remote get-url origin`, if there is one.
    public static func facts(files: [String], read: (String) -> String?, schemes: [String]?,
                             simulators: Data, remoteURL: String?) throws -> RepoFacts {
        var notes: [String] = []

        // Project and version file
        let project: String, generate: [String]?, projectYML: String?
        if files.contains("project.yml"), let yml = read("project.yml") {
            projectYML = yml
            guard let name = firstMatch(#"(?m)^name:\s*["']?([^"'\n#]+?)["']?\s*$"#, in: yml) else {
                throw LaunchError.precondition("project.yml has no top-level `name:`, so the .xcodeproj name isn't known")
            }
            project = "\(name).xcodeproj"
            generate = ["xcodegen", "generate"]
        } else if let workspace = files.sorted().first(where: { $0.hasSuffix(".xcworkspace") }) {
            project = workspace; generate = nil; projectYML = nil
        } else if let xcodeproj = files.sorted().first(where: { $0.hasSuffix(".xcodeproj") }) {
            project = xcodeproj; generate = nil; projectYML = nil
        } else {
            throw LaunchError.precondition("No project.yml, .xcworkspace or .xcodeproj at the repo root. Run `launchseq init` from the app's repo.")
        }

        let pbxprojPath = files.sorted().first(where: { $0.hasSuffix(".xcodeproj") }).map { "\($0)/project.pbxproj" }
        let pbxproj = pbxprojPath.flatMap(read)
        let versionFile: String, settings: String
        if let projectYML, projectYML.contains("MARKETING_VERSION") {
            versionFile = "project.yml"; settings = projectYML
        } else if let pbxprojPath, let pbxproj {
            versionFile = pbxprojPath; settings = pbxproj
        } else {
            versionFile = projectYML != nil ? "project.yml" : pbxprojPath ?? "project.yml"
            settings = projectYML ?? pbxproj ?? ""
        }
        if !settings.contains("MARKETING_VERSION") {
            notes.append("No MARKETING_VERSION found in \(versionFile). Set `version.file` to the file that holds the app's version.")
        }

        // Names
        let projectBase = (project as NSString).deletingPathExtension
        let displayName = firstMatch(#"CFBundleDisplayName["']?\s*[:=]\s*["']?([^"'\n;]+?)["']?\s*;?\s*$"#, in: settings, multiline: true)
        let appName = displayName ?? spacedWords(projectBase)

        let bundleIds = matches(#"PRODUCT_BUNDLE_IDENTIFIER["']?\s*[:=]\s*["']?([A-Za-z0-9.-]+)"#, in: settings)
            .filter { $0.range(of: "test", options: .caseInsensitive) == nil }
        let bundleId = bundleIds.min { $0.count != $1.count ? $0.count < $1.count : $0 < $1 }
        if bundleId == nil { notes.append("Couldn't find the app's bundle ID. Fill in `app_store.bundle_id`.") }

        let scheme: String
        if let schemes, !schemes.isEmpty {
            scheme = schemes.first { $0 == projectBase }
                ?? schemes.first { $0.range(of: "test", options: .caseInsensitive) == nil } ?? schemes[0]
        } else {
            scheme = projectBase
            notes.append("Guessed the test scheme `\(scheme)` from the project name. Check `test.scheme`.")
        }

        guard let simulator = newestIPhone(in: simulators) else {
            throw LaunchError.precondition("No available iPhone simulator. Add an iOS runtime in Xcode › Settings › Components, then run init again.")
        }

        let owner = remoteURL.flatMap { firstMatch(#"github\.com[:/]([A-Za-z0-9_.-]+)/"#, in: $0) }

        return RepoFacts(appName: appName, project: project, generate: generate, versionFile: versionFile, scheme: scheme,
                         bundleId: bundleId, simulator: simulator, githubOwner: owner, notes: notes)
    }

    /// An "iPhone N Pro" on the newest iOS runtime that has one. Failing that, an "iPhone N",
    /// then any iPhone (a runtime can hold only special models, like a foldable).
    public static func newestIPhone(in json: Data) -> Simulator? {
        guard let doc = try? JSONValue.parse(json), case .object(let runtimes) = doc["devices"] else { return nil }
        let prefix = "com.apple.CoreSimulator.SimRuntime.iOS-"
        let ordered = runtimes.keys.filter { $0.hasPrefix(prefix) }
            .map { (key: $0, version: $0.dropFirst(prefix.count).split(separator: "-").compactMap { Int($0) }) }
            .sorted { $0.version.lexicographicallyPrecedes($1.version) }
            .reversed()
        let preferences: [(String) -> Bool] = [
            { $0.range(of: #"^iPhone \d+ Pro$"#, options: .regularExpression) != nil },
            { $0.range(of: #"^iPhone \d+$"#, options: .regularExpression) != nil },
            { $0.hasPrefix("iPhone") },
        ]
        for wanted in preferences {
            for runtime in ordered {
                let names = (runtimes[runtime.key]?.array ?? [])
                    .filter { $0["isAvailable"].bool != false }
                    .compactMap { $0["name"].string }
                    .filter(wanted)
                // "iPhone 17 Pro" sorts after "iPhone 16 Pro", but "iPhone 9" also sorts after "iPhone 17".
                let pick = names.max { modelNumber($0) != modelNumber($1) ? modelNumber($0) < modelNumber($1) : $0 < $1 }
                if let pick { return Simulator(name: pick, os: runtime.version.map(String.init).joined(separator: ".")) }
            }
        }
        return nil
    }

    static func modelNumber(_ name: String) -> Int { firstMatch(#"^iPhone (\d+)"#, in: name).flatMap { Int($0) } ?? 0 }

    public static func render(_ f: RepoFacts) -> String {
        let slug = AppSection.slug(for: f.appName)
        var out = """
        # Drafted by `launchseq init`. Check every value, then run `launchseq doctor`.
        # Every key is described in examples/launchseq.yml in the launch-sequence repo.

        app:
          name: \(quoted(f.appName))
          project: \(quoted(f.project))

        """
        if let generate = f.generate {
            out += "  generate: [\(generate.map(quoted).joined(separator: ", "))]   # the project is generated, not committed\n"
        }
        out += """

        version:
          file: \(quoted(f.versionFile))
          key: MARKETING_VERSION

        test:
          scheme: \(quoted(f.scheme))
          # Pin the exact OS: several runtimes can share a device name. If CI checks snapshot
          # tests, use the iOS version CI runs on.
          simulator: { name: \(quoted(f.simulator.name)), os: \(quoted(f.simulator.os)) }

        # One entry per language the app ships. `locale` is passed as -AppleLocale when capturing
        # screenshots. `asc_locale` is the App Store Connect locale; leave it out for a language
        # the App Store has no listing for.
        languages:
          - { code: en, locale: en_US, asc_locale: en-US }

        app_store:
          bundle_id: \(quoted(f.bundleId ?? "TODO"))
          primary_locale: en-US          # must be the asc_locale of one of `languages`
          metadata_dir: AppStoreAssets/metadata
          release_type: MANUAL           # MANUAL, AFTER_APPROVAL or SCHEDULED
          phased_release: true

        # Optional sections. Uncomment and fill in the ones you use.

        # Screenshots need the app to open on a fixed screen from a launch argument.
        # screenshots:
        #   raw_dir: AppStoreAssets/Screenshots/Raw
        #   output_dir: AppStoreAssets/Screenshots/AppStore
        #   render: [node, scripts/render_store_screenshots.js]
        #   builds:
        #     - scheme: \(f.scheme)
        #       simulator: { name: \(quoted(f.simulator.name)), os: \(quoted(f.simulator.os)) }
        #   scenes:
        #     - { name: 01-home, args: [-screenshotScene, home] }
        #   devices:
        #     - name: iPhone
        #       simulator: { name: \(quoted(f.simulator.name)), os: \(quoted(f.simulator.os)) }
        #       app: Debug-iphonesimulator/\((f.project as NSString).deletingPathExtension).app
        #       bundle_id: \(f.bundleId ?? "TODO")
        #       display_type: APP_IPHONE_67

        # Support, privacy and accessibility pages, kept in this repo and published by liftoff.
        # website:
        #   repo: \(f.githubOwner.map { "\($0)/\($0).github.io" } ?? "owner/site-repo")
        #   branch: main
        #   folder: \(slug)
        #   source: website

        # Changes under these paths make countdown warn if the website pages didn't change too.
        # privacy_sensitive_paths:
        #   - "**/*.entitlements"

        """
        return out
    }

    // MARK: Helpers

    static func quoted(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// "PrimeTime" → "Prime Time".
    static func spacedWords(_ s: String) -> String {
        s.replacingOccurrences(of: #"([a-z0-9])([A-Z])"#, with: "$1 $2", options: .regularExpression)
    }

    static func matches(_ pattern: String, in text: String, multiline: Bool = false) -> [String] {
        let options: NSRegularExpression.Options = multiline ? [.anchorsMatchLines] : []
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { m in
            Range(m.range(at: 1), in: text).map { String(text[$0]).trimmingCharacters(in: .whitespaces) }
        }
    }

    static func firstMatch(_ pattern: String, in text: String, multiline: Bool = false) -> String? {
        matches(pattern, in: text, multiline: multiline).first
    }
}

/// `launchseq init`: writes a starter `.launchseq.yml` at the repo root.
public struct Init: Sendable {
    let root: URL
    let shell: Shell
    let console: Console

    public init(root: URL, shell: Shell, console: Console) { self.root = root; self.shell = shell; self.console = console }

    /// Finds the repo root from the current directory.
    public static func repoRoot(runner: CommandRunning = ProcessRunner()) throws -> URL {
        let top = try runner.run(["git", "rev-parse", "--show-toplevel"], cwd: nil, environment: [:], mode: .capture)
        guard top.status == 0 else { throw LaunchError.precondition("Run launchseq init inside an app's git repo") }
        return URL(fileURLWithPath: top.trimmed)
    }

    @discardableResult
    public func run(force: Bool) throws -> String {
        let target = root.appendingPathComponent(Config.fileName)
        if FileManager.default.fileExists(atPath: target.path) && !force {
            throw LaunchError.precondition("\(Config.fileName) already exists. Pass --force to replace it.")
        }
        console.stage("Drafting \(Config.fileName)")

        let files = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        let read: (String) -> String? = { path in
            guard let url = try? SafePath.resolve(path, under: root) else { return nil }
            return try? String(contentsOf: url, encoding: .utf8)
        }
        let simulators = try shell.read(["xcrun", "simctl", "list", "devices", "--json"]).stdout
        let remote = try? shell.read(["git", "remote", "get-url", "origin"], allowFailure: true).trimmed

        // Ask Xcode for schemes only when the project is already on disk; init never generates it.
        var schemes: [String]?
        if let project = files.sorted().first(where: { $0.hasSuffix(".xcworkspace") || $0.hasSuffix(".xcodeproj") }) {
            let flag = project.hasSuffix(".xcworkspace") ? "-workspace" : "-project"
            if let out = try? shell.read(["xcodebuild", "-list", "-json", flag, project], allowFailure: true), out.status == 0,
               let doc = try? JSONValue.parse(Data(out.stdout.utf8)) {
                let section = doc["workspace"]["schemes"].array.isEmpty ? doc["project"]["schemes"] : doc["workspace"]["schemes"]
                schemes = section.array.compactMap(\.string)
            }
        }

        let facts = try InitDraft.facts(files: files, read: read, schemes: schemes, simulators: Data(simulators.utf8),
                                        remoteURL: remote?.isEmpty == false ? remote : nil)
        let yaml = InitDraft.render(facts)
        do { _ = try Config.parse(yaml) } catch {
            throw LaunchError.config("init drafted a config that doesn't load, which is a launchseq bug: \(error)")
        }

        console.ok("App: \(facts.appName), project \(facts.project), scheme \(facts.scheme)")
        console.ok("Version from \(facts.versionFile)")
        console.ok("Tests on \(facts.simulator.name) (iOS \(facts.simulator.os))")
        if let id = facts.bundleId { console.ok("Bundle ID \(id)") }
        for note in facts.notes { console.warn(note) }

        if shell.dryRun {
            console.dry("write \(Config.fileName):\n\n\(yaml)")
        } else {
            try yaml.write(to: target, atomically: true, encoding: .utf8)
            console.stage("Wrote \(Config.fileName). Next:")
            console.info("1. Check every value, and add your languages.")
            console.info("2. Put the App Store copy in app_store.metadata_dir (`launchseq migrate-copy` converts Markdown copy).")
            console.info("3. Run `launchseq doctor`.")
        }
        return yaml
    }
}
