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
        if mode == .interactive {
            let status = try ForegroundSpawn.run(try Self.locate(program), arguments: Array(arguments.dropFirst()), cwd: cwd,
                                                 environment: ProcessInfo.processInfo.environment.merging(environment) { $1 })
            return CommandResult(status: status, stdout: "", stderr: "")
        }
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
            preconditionFailure("interactive commands run through ForegroundSpawn")
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
        let result: CommandResult
        if case .log = mode {
            // Logged commands are the slow ones (builds, tests, rendering), and print nothing here.
            result = try console.whileWorking("running \(args.first.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "")") {
                try runner.run(args, cwd: cwd ?? root, environment: environment, mode: mode)
            }
        } else {
            result = try runner.run(args, cwd: cwd ?? root, environment: environment, mode: mode)
        }
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

/// Runs a program on this terminal in launchseq's own process group, which is the
/// terminal's foreground group. `Process` starts children in a new group, so a
/// full-screen editor like vi is stopped by SIGTTOU and never appears.
enum ForegroundSpawn {
    static func run(_ executable: URL, arguments: [String], cwd: URL?, environment: [String: String]) throws -> Int32 {
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        // The child gets default Ctrl-C handling even though launchseq ignores it meanwhile.
        var defaults = sigset_t()
        sigemptyset(&defaults); sigaddset(&defaults, SIGINT); sigaddset(&defaults, SIGQUIT)
        posix_spawnattr_setsigdefault(&attr, &defaults)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSIGDEF))

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        if let cwd { posix_spawn_file_actions_addchdir_np(&actions, cwd.path) }

        let argv = ([executable.path] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (argv + envp).forEach { free($0) } }

        // Like system(3): Ctrl-C goes to the editor, not launchseq, while it's open.
        let oldInt = signal(SIGINT, SIG_IGN), oldQuit = signal(SIGQUIT, SIG_IGN)
        defer { signal(SIGINT, oldInt); signal(SIGQUIT, oldQuit) }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, executable.path, &actions, &attr, argv, envp)
        guard rc == 0 else { throw LaunchError.command("Couldn't start \(executable.lastPathComponent): \(String(cString: strerror(rc)))") }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 {
            guard errno == EINTR else { throw LaunchError.command("Lost track of \(executable.lastPathComponent): \(String(cString: strerror(errno)))") }
        }
        let signalled = status & 0x7f
        if signalled == SIGINT { throw LaunchError.aborted("\(executable.lastPathComponent) was stopped with Ctrl-C") }
        return signalled == 0 ? (status >> 8) & 0xff : 128 + signalled
    }

    /// Whether launchseq can hand this terminal to a child: stdin is a terminal and
    /// launchseq is in its foreground group.
    static var ownsTerminal: Bool {
        isatty(STDIN_FILENO) != 0 && tcgetpgrp(STDIN_FILENO) == getpgrp()
    }
}
