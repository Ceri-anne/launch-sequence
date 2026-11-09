import Foundation

/// Everything a stage needs, built once per run.
public struct Context: Sendable {
    public let config: Config
    public let root: URL
    public let console: Console
    public let shell: Shell
    public let git: Git
    public let github: GitHub
    public var dryRun: Bool { shell.dryRun }

    public init(config: Config, root: URL, console: Console, runner: CommandRunning = ProcessRunner(), dryRun: Bool) {
        self.config = config
        self.root = root
        self.console = console
        self.shell = Shell(runner: runner, console: console, dryRun: dryRun, root: root)
        self.git = Git(shell: shell)
        self.github = GitHub(shell: shell)
    }

    /// Finds the repo root and `.launchseq.yml` from the current directory.
    public static func locateConfig(explicit: String?, runner: CommandRunning = ProcessRunner()) throws -> (root: URL, config: URL) {
        if let explicit {
            let url = URL(fileURLWithPath: (explicit as NSString).expandingTildeInPath).standardizedFileURL
            return (url.deletingLastPathComponent(), url)
        }
        let top = try runner.run(["git", "rev-parse", "--show-toplevel"], cwd: nil, environment: [:], mode: .capture)
        guard top.status == 0 else { throw LaunchError.precondition("Run launchseq inside an app's git repo") }
        let root = URL(fileURLWithPath: top.trimmed)
        let config = root.appendingPathComponent(Config.fileName)
        guard FileManager.default.fileExists(atPath: config.path) else {
            throw LaunchError.precondition("No \(Config.fileName) at \(root.path). See the README for an example.")
        }
        return (root, config)
    }

    var versionFileURL: URL { get throws { try SafePath.resolve(config.version.file, under: root) } }

    func fileVersion(_ text: String) throws -> SemVer? {
        let values = Set(VersionFile.read(text, key: config.version.key))
        guard !values.isEmpty else { return nil }
        guard values.count == 1, let v = values.first.flatMap({ SemVer(marketing: $0) }) else {
            throw LaunchError.precondition("\(config.version.file) has different \(config.version.key) values: \(values.sorted().joined(separator: ", "))")
        }
        return v
    }

    var ascLocales: [String] { config.languages.compactMap(\.ascLocale) }
    var remoteBase: String { "origin/\(config.release.baseBranch)" }
}

/// Progress for one version, kept inside `.git/` so it's never committed.
public struct RunState: Codable, Equatable, Sendable {
    public var version: String
    public var done: [String: String] = [:]

    public static func url(gitDir: URL) -> URL { gitDir.appendingPathComponent("launchseq/state.json") }

    public static func load(gitDir: URL, version: String) -> RunState {
        guard let data = try? Data(contentsOf: url(gitDir: gitDir)),
              let state = try? JSONDecoder().decode(RunState.self, from: data), state.version == version else {
            return RunState(version: version)
        }
        return state
    }

    public func save(gitDir: URL, dryRun: Bool) throws {
        guard !dryRun else { return }
        let url = Self.url(gitDir: gitDir)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    public func has(_ step: String) -> Bool { done[step] != nil }
    public mutating func mark(_ step: String, _ detail: String = ISO8601DateFormatter().string(from: Date())) { done[step] = detail }
}

/// `fnmatch`-style matching for `privacy_sensitive_paths` (`**` crosses folders).
public enum Glob {
    public static func matches(_ pattern: String, _ path: String) -> Bool {
        var regex = "^"
        var chars = Array(pattern)[...]
        while let c = chars.popFirst() {
            switch c {
            case "*":
                if chars.first == "*" {
                    chars.removeFirst()
                    if chars.first == "/" { chars.removeFirst(); regex += "(?:.*/)?" } else { regex += ".*" }
                } else {
                    regex += "[^/]*"
                }
            case "?": regex += "[^/]"
            default: regex += NSRegularExpression.escapedPattern(for: String(c))
            }
        }
        regex += "$"
        return path.range(of: regex, options: .regularExpression) != nil
    }
}
