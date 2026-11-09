import Foundation

public struct CommandResult: Sendable, Equatable {
    public var status: Int32
    public var stdout: String
    public var stderr: String
    public init(status: Int32, stdout: String, stderr: String) {
        self.status = status; self.stdout = stdout; self.stderr = stderr
    }
    public var trimmed: String { stdout.trimmingCharacters(in: .whitespacesAndNewlines) }
}

public enum OutputMode: Sendable, Equatable {
    /// Capture stdout and stderr.
    case capture
    /// Let the child use this terminal (editors, prompts, live progress).
    case interactive
    /// Send everything to a log file; on failure the tail is shown.
    case log(URL)
}

/// Runs programs with an argument array. There is never a shell in between, so
/// no value from config, git or the network can be interpreted as shell syntax.
public protocol CommandRunning: Sendable {
    func run(_ arguments: [String], cwd: URL?, environment: [String: String], mode: OutputMode) throws -> CommandResult
}

public struct ProcessRunner: CommandRunning {
    public init() {}

    public func run(_ arguments: [String], cwd: URL?, environment: [String: String], mode: OutputMode) throws -> CommandResult {
        guard let program = arguments.first else { throw LaunchError.command("Empty command") }
        let process = Process()
        process.executableURL = try Self.locate(program)
        process.arguments = Array(arguments.dropFirst())
        if let cwd { process.currentDirectoryURL = cwd }
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }

        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("launchseq-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        let outURL = tmp.appendingPathComponent("out"), errURL = tmp.appendingPathComponent("err")

        switch mode {
        case .interactive:
            process.standardInput = FileHandle.standardInput
            process.standardOutput = FileHandle.standardOutput
            process.standardError = FileHandle.standardError
        case .capture:
            fm.createFile(atPath: outURL.path, contents: nil)
            fm.createFile(atPath: errURL.path, contents: nil)
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = try FileHandle(forWritingTo: outURL)
            process.standardError = try FileHandle(forWritingTo: errURL)
        case .log(let url):
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            fm.createFile(atPath: url.path, contents: nil)
            let handle = try FileHandle(forWritingTo: url)
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = handle
            process.standardError = handle
        }

        try process.run()
        process.waitUntilExit()

        switch mode {
        case .capture:
            let out = (try? String(contentsOf: outURL, encoding: .utf8)) ?? ""
            let err = (try? String(contentsOf: errURL, encoding: .utf8)) ?? ""
            return CommandResult(status: process.terminationStatus, stdout: out, stderr: err)
        case .log(let url):
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let tail = text.split(separator: "\n", omittingEmptySubsequences: false).suffix(40).joined(separator: "\n")
            return CommandResult(status: process.terminationStatus, stdout: "", stderr: tail)
        case .interactive:
            return CommandResult(status: process.terminationStatus, stdout: "", stderr: "")
        }
    }

    /// Finds `program` on PATH. Absolute or relative paths are used as given.
    static func locate(_ program: String) throws -> URL {
        if program.contains("/") { return URL(fileURLWithPath: program) }
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        for dir in path.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent(program)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        throw LaunchError.command("`\(program)` isn't installed or isn't on PATH")
    }
}

/// Wraps a runner with dry-run behaviour: reads always run, changes are only printed.
public struct Shell: Sendable {
    public let runner: CommandRunning
    public let console: Console
    public let dryRun: Bool
    public let root: URL

    public init(runner: CommandRunning, console: Console, dryRun: Bool, root: URL) {
        self.runner = runner; self.console = console; self.dryRun = dryRun; self.root = root
    }

    /// Runs a command that only reads state. Throws on a non-zero exit unless `allowFailure`.
    @discardableResult
    public func read(_ args: [String], cwd: URL? = nil, allowFailure: Bool = false) throws -> CommandResult {
        console.debug("$ " + Self.display(args))
        let result = try runner.run(args, cwd: cwd ?? root, environment: [:], mode: .capture)
        if result.status != 0 && !allowFailure {
            throw LaunchError.command("`\(Self.display(args))` failed (\(result.status)):\n\(result.stderr.isEmpty ? result.stdout : result.stderr)")
        }
        return result
    }

    /// Runs a command that changes something. In a dry run it's printed instead.
    @discardableResult
    public func change(_ args: [String], cwd: URL? = nil, environment: [String: String] = [:], mode: OutputMode = .capture, allowFailure: Bool = false) throws -> CommandResult {
        if dryRun {
            console.dry(Self.display(args))
            return CommandResult(status: 0, stdout: "", stderr: "")
        }
        console.debug("$ " + Self.display(args))
        let result = try runner.run(args, cwd: cwd ?? root, environment: environment, mode: mode)
        if result.status != 0 && !allowFailure {
            var detail = result.stderr.isEmpty ? result.stdout : result.stderr
            if case .log(let url) = mode { detail = "Last lines of \(url.path):\n" + detail }
            throw LaunchError.command("`\(Self.display(args))` failed (\(result.status)):\n\(detail)")
        }
        return result
    }

    /// Quotes arguments for display only. Nothing is ever run through a shell.
    public static func display(_ args: [String]) -> String {
        args.map { arg in
            arg.range(of: #"^[A-Za-z0-9_./:=,+@%-]+$"#, options: .regularExpression) != nil ? arg : "'" + arg.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }.joined(separator: " ")
    }
}
