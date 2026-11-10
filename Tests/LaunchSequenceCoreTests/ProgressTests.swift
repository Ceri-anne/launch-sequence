import Foundation
import Testing
@testable import LaunchSequenceCore

/// Collects console lines from any thread.
final class Lines: @unchecked Sendable {
    private var lines: [String] = []
    private let lock = NSLock()
    func append(_ line: String) { lock.lock(); lines.append(line); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return lines }
    var text: String { all.joined(separator: "\n") }
}

/// Takes a while, like xcodebuild, then succeeds.
struct SlowRunner: CommandRunning {
    var seconds: Double
    func run(_ arguments: [String], cwd: URL?, environment: [String: String], mode: OutputMode) throws -> CommandResult {
        Thread.sleep(forTimeInterval: seconds)
        return CommandResult(status: 0, stdout: "", stderr: "")
    }
}

@Suite("Progress and prompts")
struct ProgressTests {
    @Test func longStepsSayTheyAreStillWorking() {
        let lines = Lines()
        let console = Console(answers: [], heartbeatSeconds: 0.05, sink: lines.append)
        console.whileWorking("building StarChart") { Thread.sleep(forTimeInterval: 0.3) }
        let beats = lines.all.filter { $0.contains("… still building StarChart (") }
        #expect(beats.count >= 2)
    }

    @Test func quickStepsPrintNothingExtra() {
        let lines = Lines()
        let console = Console(answers: [], heartbeatSeconds: 0.2, sink: lines.append)
        console.whileWorking("booting") {}
        Thread.sleep(forTimeInterval: 0.3)
        #expect(lines.all.isEmpty)
    }

    @Test func asyncStepsSayTheyAreStillWorking() async throws {
        let lines = Lines()
        let console = Console(answers: [], heartbeatSeconds: 0.05, sink: lines.append)
        let result = try await console.whileWorking("translating into fr-FR") {
            try await Task.sleep(nanoseconds: 300_000_000)
            return "Bonjour"
        }
        #expect(result == "Bonjour")
        #expect(lines.all.contains { $0.contains("… still translating into fr-FR (") })
    }

    @Test func loggedCommandsGetAHeartbeat() throws {
        let lines = Lines()
        let console = Console(answers: [], heartbeatSeconds: 0.05, sink: lines.append)
        let shell = Shell(runner: SlowRunner(seconds: 0.3), console: console, dryRun: false, root: try tempDir())
        try shell.change(["/usr/bin/xcodebuild", "test"], mode: .log(try tempDir().appendingPathComponent("test.log")))
        #expect(lines.all.contains { $0.contains("… still running xcodebuild (") })

        let quiet = Lines()
        let captured = Shell(runner: SlowRunner(seconds: 0.3), console: Console(answers: [], heartbeatSeconds: 0.05, sink: quiet.append), dryRun: false, root: try tempDir())
        try captured.read(["git", "status"])
        #expect(quiet.all.isEmpty)
    }

    @Test func durations() {
        #expect(Console.duration(45) == "45s")
        #expect(Console.duration(125) == "2m 5s")
    }

    @Test func manualStepConfirmsTheKeypressAndAsksForFocus() throws {
        let lines = Lines()
        let console = Console(answers: [""], sink: lines.append)
        try console.pause("Unfold the iPhone Duo simulator.", acknowledgement: "Got it, capturing iPhone Duo inner…")
        #expect(lines.text.contains("click back into this terminal"))
        #expect(lines.text.contains("doesn't reach launchseq"))
        #expect(lines.all.last?.contains("Got it, capturing iPhone Duo inner…") == true)
    }

    @Test func manualStepCanBeStopped() {
        let lines = Lines()
        let console = Console(answers: ["q"], sink: lines.append)
        #expect(throws: LaunchError.self) { try console.pause("Unfold it.") }
        #expect(!lines.text.contains("Got it"))
    }

    @Test func interactiveCommandsStayInTheForegroundGroup() throws {
        let runner = ProcessRunner()
        let pgid = getpgrp()
        let sameGroup = try runner.run(["/bin/sh", "-c", "[ \"$(ps -o pgid= -p $$ | tr -d ' ')\" = \"\(pgid)\" ]"], cwd: nil, environment: [:], mode: .interactive)
        #expect(sameGroup.status == 0)
    }

    @Test func interactiveCommandsKeepCwdEnvironmentAndExitStatus() throws {
        let runner = ProcessRunner()
        let dir = try tempDir()
        let real = String(cString: realpath(dir.path, nil))
        let ok = try runner.run(["sh", "-c", "[ \"$(pwd -P)\" = \"\(real)\" ] && [ \"$LAUNCHSEQ_TEST\" = 'a b' ]"],
                                cwd: dir, environment: ["LAUNCHSEQ_TEST": "a b"], mode: .interactive)
        #expect(ok.status == 0)
        #expect(try runner.run(["sh", "-c", "exit 3"], cwd: nil, environment: [:], mode: .interactive).status == 3)
    }
}
