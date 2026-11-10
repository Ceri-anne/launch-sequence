import Foundation
import Testing
@testable import LaunchSequenceCore

/// Answers `gh` with scripted check states, one per call; the last repeats.
final class ScriptedChecks: CommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [CommandResult]
    private(set) var calls = 0
    init(_ replies: [CommandResult]) { self.replies = replies }

    static func checkRuns(_ runs: [(String, String, String?)]) -> CommandResult {
        let json: JSONValue = ["check_runs": .array(runs.map { ["name": .string($0.0), "status": .string($0.1), "conclusion": $0.2.map(JSONValue.string) ?? .null] })]
        return CommandResult(status: 0, stdout: String(decoding: try! json.data(), as: UTF8.self), stderr: "")
    }
    static func prChecks(_ checks: [(String, String)]) -> CommandResult {
        let json: JSONValue = .array(checks.map { ["name": .string($0.0), "bucket": .string($0.1)] })
        return CommandResult(status: 0, stdout: String(decoding: try! json.data(), as: UTF8.self), stderr: "")
    }
    static let noPRChecks = CommandResult(status: 1, stdout: "", stderr: "no checks reported on the 'launchseq/prime-time-1.3.0' branch\n")

    func run(_ arguments: [String], cwd: URL?, environment: [String: String], mode: OutputMode) throws -> CommandResult {
        lock.lock(); defer { lock.unlock() }
        guard arguments.first == "gh", arguments.contains("checks") || arguments.contains(where: { $0.contains("check-runs") }) else {
            return CommandResult(status: 0, stdout: "", stderr: "")
        }
        calls += 1
        return replies.count > 1 ? replies.removeFirst() : replies[0]
    }
}

/// A tiny Xcode Cloud: one app, one Main workflow, and the build runs it has.
final class FakeXcodeCloud: @unchecked Sendable {
    let lock = NSLock()
    var runs: [JSONValue] = []
    var started: [JSONValue] = []

    func handle(_ r: URLRequest) throws -> (Data, Int) {
        lock.lock(); defer { lock.unlock() }
        func doc(_ v: JSONValue) throws -> (Data, Int) { (try v.data(), 200) }
        switch (r.httpMethod ?? "GET", r.url!.path) {
        case ("GET", "/v1/apps"):
            return try doc(["data": [["id": "123", "attributes": ["bundleId": "uk.co.example.primetime"]]]])
        case ("GET", "/v1/apps/123/ciProduct"):
            return try doc(["data": ["id": "prod1"]])
        case ("GET", "/v1/ciProducts/prod1/workflows"):
            return try doc(["data": [["id": "wfRelease", "attributes": ["name": "Release", "isEnabled": true]],
                                     ["id": "wfMain", "attributes": ["name": "Main", "isEnabled": true]]]])
        case ("GET", "/v1/ciWorkflows/wfMain/buildRuns"):
            return try doc(["data": .array(runs)])
        case ("GET", "/v1/ciWorkflows/wfMain/repository"):
            return try doc(["data": ["id": "repo1"]])
        case ("GET", "/v1/scmRepositories/repo1/gitReferences"):
            return try doc(["data": [["id": "refTag", "attributes": ["canonicalName": "refs/tags/1.2.0"]],
                                     ["id": "refOld", "attributes": ["canonicalName": "refs/heads/main", "isDeleted": true]],
                                     ["id": "refMain", "attributes": ["canonicalName": "refs/heads/main", "isDeleted": false]]]])
        case ("POST", "/v1/ciBuildRuns"):
            let body = try JSONValue.parse(r.httpBody!)
            started.append(body)
            return try doc(["data": ["id": "run9", "attributes": ["number": 111]]])
        default:
            return (try (["errors": [["title": "Not found"]]] as JSONValue).data(), 404)
        }
    }

    static func run(_ number: Int, commit: String, progress: String) -> JSONValue {
        ["id": .string("run\(number)"), "attributes": ["number": .number(Double(number)), "executionProgress": .string(progress), "sourceCommit": ["commitSha": .string(commit)]]]
    }
}

@Suite("CI checks")
struct CITests {
    let commit = "3d605c9d7d9087219ac4c342ae4f24d439fedfe8"

    func liftoff(_ gh: ScriptedChecks, cloud: FakeXcodeCloud, answers: [String], lines: Lines, force: Bool = false) throws -> Liftoff {
        let console = Console(answers: answers, sink: lines.append)
        let ctx = Context(config: try Config.parse(try fixture("launchseq.yml")), root: try tempDir(), console: console, runner: gh, dryRun: false)
        var options = Liftoff.Options()
        options.force = force
        return Liftoff(ctx: ctx, options: options, transport: RecordingTransport { try cloud.handle($0) }, sleep: { _ in }, credentials: { testCredentials() })
    }

    // MARK: Waiting

    @Test func waitsForChecksToRegisterThenFinish() throws {
        let lines = Lines()
        let states: [GitHub.CheckState] = [.none, .none, .pending(["Main"]), .pending(["Main"]), .passed(2)]
        var i = 0
        let waiter = CheckWaiter(console: Console(answers: [], sink: lines.append), sleep: { _ in })
        #expect(try waiter.wait("abc12345") { defer { i += 1 }; return states[i] } == .passed(2))
        #expect(lines.text.contains("… no checks on abc12345 yet (0s)"))
        #expect(lines.text.contains("waiting for Main (30s)"))
    }

    @Test func givesUpWhenNoChecksRegister() throws {
        var polls = 0
        let waiter = CheckWaiter(console: quietConsole, appearMinutes: 5, sleep: { _ in })
        #expect(try waiter.wait("abc") { polls += 1; return .none } == .none)
        #expect(polls == 5 * 60 / 15 + 1)
    }

    @Test func runningTimeCountsFromWhenChecksRegister() throws {
        var polls = 0
        let waiter = CheckWaiter(console: quietConsole, appearMinutes: 5, finishMinutes: 1, sleep: { _ in })
        let state = try waiter.wait("abc") { polls += 1; return polls <= 10 ? .none : .pending(["Main"]) }
        #expect(state == .pending(["Main"]))
        #expect(polls == 10 + 60 / 15 + 1)
    }

    // MARK: Liftoff

    @Test func liftoffWaitsWhenChecksAreSlowToAppear() async throws {
        let gh = ScriptedChecks([.init(status: 0, stdout: #"{"check_runs":[]}"#, stderr: ""),
                                 ScriptedChecks.checkRuns([("Main", "in_progress", nil)]),
                                 ScriptedChecks.checkRuns([("Main", "completed", "success")])])
        let cloud = FakeXcodeCloud()
        let lines = Lines()
        try await liftoff(gh, cloud: cloud, answers: [], lines: lines).checkCI(repo: "Example/app", commit: commit)
        #expect(lines.text.contains("1 check passed"))
        #expect(cloud.started.isEmpty)
    }

    @Test func liftoffOffersToStartTheMainBuild() async throws {
        // No checks for the full five minutes, then the build it starts reports and passes.
        let none = CommandResult(status: 0, stdout: #"{"check_runs":[]}"#, stderr: "")
        let gh = ScriptedChecks(Array(repeating: none, count: 21) + [ScriptedChecks.checkRuns([("Main", "completed", "success")])])
        let cloud = FakeXcodeCloud()
        cloud.runs = [FakeXcodeCloud.run(105, commit: "someothercommit", progress: "COMPLETE")]
        let lines = Lines()
        try await liftoff(gh, cloud: cloud, answers: ["y"], lines: lines).checkCI(repo: "Example/app", commit: commit)

        #expect(lines.text.contains("Xcode Cloud hasn't started a Main build of 3d605c9d"))
        #expect(lines.text.contains("Start the Main workflow on main (3d605c9d) now?"))
        #expect(lines.text.contains("Started Main build 111"))
        let body = try #require(cloud.started.first)
        #expect(body["data"]["type"].string == "ciBuildRuns")
        #expect(body["data"]["relationships"]["workflow"]["data"]["id"].string == "wfMain")
        #expect(body["data"]["relationships"]["sourceBranchOrTag"]["data"]["id"].string == "refMain")
        #expect(lines.text.contains("1 check passed"))
    }

    @Test func liftoffStopsIfYouDontStartTheBuild() async throws {
        let gh = ScriptedChecks([.init(status: 0, stdout: #"{"check_runs":[]}"#, stderr: "")])
        let cloud = FakeXcodeCloud()
        let lines = Lines()
        await #expect(throws: LaunchError.self) {
            try await liftoff(gh, cloud: cloud, answers: ["n"], lines: lines).checkCI(repo: "Example/app", commit: commit)
        }
        #expect(cloud.started.isEmpty)
    }

    @Test func liftoffWaitsForABuildThatAlreadyStarted() async throws {
        let none = CommandResult(status: 0, stdout: #"{"check_runs":[]}"#, stderr: "")
        let gh = ScriptedChecks(Array(repeating: none, count: 21) + [ScriptedChecks.checkRuns([("Main", "completed", "success")])])
        let cloud = FakeXcodeCloud()
        cloud.runs = [FakeXcodeCloud.run(109, commit: commit, progress: "COMPLETE"), FakeXcodeCloud.run(110, commit: commit, progress: "RUNNING")]
        let lines = Lines()
        try await liftoff(gh, cloud: cloud, answers: [], lines: lines).checkCI(repo: "Example/app", commit: commit)
        #expect(lines.text.contains("Xcode Cloud Main build 110 of 3d605c9d is running. Waiting for its checks."))
        #expect(cloud.started.isEmpty)
    }

    @Test func forceSkipsTheWaitAndTheOffer() async throws {
        let gh = ScriptedChecks([.init(status: 0, stdout: #"{"check_runs":[]}"#, stderr: "")])
        let lines = Lines()
        try await liftoff(gh, cloud: FakeXcodeCloud(), answers: [], lines: lines, force: true).checkCI(repo: "Example/app", commit: commit)
        #expect(gh.calls == 1)
        #expect(lines.text.contains("No checks reported. Carrying on (--force)."))
    }

    // MARK: Website PR

    @Test func prCheckSummary() throws {
        func summary(_ checks: [(String, String)]) throws -> GitHub.CheckState {
            try GitHub.summarise(prChecksJSON: Data(ScriptedChecks.prChecks(checks).stdout.utf8))
        }
        #expect(try summary([]) == .none)
        #expect(try summary([("build", "pass"), ("lint", "skipping")]) == .passed(2))
        #expect(try summary([("build", "pending")]) == .pending(["build"]))
        #expect(try summary([("build", "fail"), ("deploy", "pending")]) == .failed(["build (fail)"]))
    }

    @Test func noChecksYetIsNotAFailure() throws {
        let gh = ScriptedChecks([ScriptedChecks.noPRChecks])
        let shell = Shell(runner: gh, console: quietConsole, dryRun: false, root: try tempDir())
        #expect(try GitHub(shell: shell).prChecks(pr: "41", repo: "Example/site") == .none)
    }

    func website(_ gh: ScriptedChecks, answers: [String], lines: Lines) throws -> WebsiteSync {
        let console = Console(answers: answers, sink: lines.append)
        let config = try Config.parse(try fixture("launchseq.yml"))
        let shell = Shell(runner: gh, console: console, dryRun: false, root: try tempDir())
        return WebsiteSync(site: try #require(config.website), shell: shell, console: console, waiter: CheckWaiter(console: console, sleep: { _ in }))
    }

    @Test func websitePRWaitsForChecksToRegister() throws {
        // The race from the 1.2.0 release: gh said "no checks" before the build registered.
        let gh = ScriptedChecks([ScriptedChecks.noPRChecks, ScriptedChecks.prChecks([("build", "pending")]), ScriptedChecks.prChecks([("build", "pass")])])
        let lines = Lines()
        let outcome = try website(gh, answers: ["y"], lines: lines).finish(pr: "https://github.com/Example/site/pull/41", cwd: try tempDir())
        #expect(outcome == .merged("https://github.com/Example/site/pull/41"))
        #expect(lines.text.contains("Website checks passed (1)"))
        #expect(!lines.text.contains("failed"))
    }

    @Test func websitePRWithNoChecksAsksRatherThanFailing() throws {
        let gh = ScriptedChecks([ScriptedChecks.noPRChecks])
        let lines = Lines()
        let outcome = try website(gh, answers: ["n"], lines: lines).finish(pr: "41", cwd: try tempDir())
        #expect(outcome == .openPR("41"))
        #expect(lines.text.contains("No checks have registered on 41 after 5 minutes"))
        #expect(!lines.text.contains("failed"))
    }

    @Test func websitePRFailureIsReportedAsAFailure() throws {
        let gh = ScriptedChecks([ScriptedChecks.prChecks([("build", "fail")])])
        let lines = Lines()
        #expect(try website(gh, answers: [], lines: lines).finish(pr: "41", cwd: try tempDir()) == .openPR("41"))
        #expect(lines.text.contains("Website checks failed: build (fail)"))
    }

    // MARK: Xcode Cloud

    @Test func picksTheLatestRunOfTheCommit() async throws {
        let cloud = FakeXcodeCloud()
        cloud.runs = [FakeXcodeCloud.run(110, commit: commit, progress: "COMPLETE"), FakeXcodeCloud.run(112, commit: commit, progress: "RUNNING"),
                      FakeXcodeCloud.run(113, commit: "other", progress: "PENDING")]
        let client = ASCClient(credentials: testCredentials(), transport: RecordingTransport { try cloud.handle($0) }, console: quietConsole, dryRun: false, sleep: { _ in })
        let xc = XcodeCloud(client: client)
        let workflow = try #require(try await xc.workflow(appID: "123", named: "Main"))
        #expect(workflow == .init(id: "wfMain", name: "Main", isEnabled: true))
        #expect(try await xc.buildRun(workflowID: "wfMain", commit: commit)?.number == 112)
        #expect(try await xc.buildRun(workflowID: "wfMain", commit: "nope") == nil)
        #expect(try await xc.workflow(appID: "123", named: "Nightly") == nil)
    }
}
