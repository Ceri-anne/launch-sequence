import Foundation
import Testing
@testable import LaunchSequenceCore

/// Answers `gh release view <tag> --json isDraft` with a canned state and records every command.
final class FakeReleases: CommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    let state: GitHub.ReleaseState
    private(set) var commands: [[String]] = []
    init(_ state: GitHub.ReleaseState) { self.state = state }

    func run(_ arguments: [String], cwd: URL?, environment: [String: String], mode: OutputMode) throws -> CommandResult {
        lock.lock(); defer { lock.unlock() }
        commands.append(arguments)
        if arguments.starts(with: ["gh", "release", "view"]) {
            switch state {
            case .missing: return CommandResult(status: 1, stdout: "", stderr: "release not found\n")
            case .draft: return CommandResult(status: 0, stdout: "true\n", stderr: "")
            case .published: return CommandResult(status: 0, stdout: "false\n", stderr: "")
            }
        }
        return CommandResult(status: 0, stdout: "", stderr: "")
    }

    var edits: [[String]] { lock.lock(); defer { lock.unlock() }; return commands.filter { $0.starts(with: ["gh", "release", "edit"]) } }
}

@Suite("Liftoff output")
struct LiftoffOutputTests {
    func liftoff(_ runner: CommandRunning, lines: Lines, dryRun: Bool) throws -> Liftoff {
        let console = Console(answers: [], sink: lines.append)
        let config = try Config.parse(try fixture("launchseq.yml"))
        let ctx = Context(config: config, root: try tempDir(), console: console, runner: runner, dryRun: dryRun)
        return Liftoff(ctx: ctx, options: .init(), transport: RecordingTransport { _ in (Data(), 404) }, sleep: { _ in }, credentials: { testCredentials() })
    }

    // MARK: GitHub release (item 13)

    @Test func alreadyPublishedReleaseIsLeftAlone() throws {
        for dryRun in [false, true] {
            let gh = FakeReleases(.published), lines = Lines()
            try liftoff(gh, lines: lines, dryRun: dryRun).publishGitHubRelease("1.1.0")
            #expect(gh.edits.isEmpty)
            #expect(lines.text.contains("GitHub release 1.1.0 already published"))
            #expect(!lines.text.contains("would:"))
        }
    }

    @Test func draftReleaseIsPublished() throws {
        let gh = FakeReleases(.draft), lines = Lines()
        try liftoff(gh, lines: lines, dryRun: false).publishGitHubRelease("1.1.0")
        #expect(gh.edits == [["gh", "release", "edit", "1.1.0", "--draft=false", "--latest"]])
        #expect(lines.text.contains("✓ Published GitHub release 1.1.0"))
    }

    @Test func dryRunPreviewsPublishingWithoutATick() throws {
        for state in [GitHub.ReleaseState.draft, .missing] {
            let gh = FakeReleases(state), lines = Lines()
            try liftoff(gh, lines: lines, dryRun: true).publishGitHubRelease("1.1.0")
            #expect(gh.edits.isEmpty)
            #expect(lines.text.contains("[dry run] would:"))
            #expect(!lines.text.contains("✓"))
        }
    }

    // MARK: Screenshots summary (item 12)

    @Test func summarySaysWhenScreenshotsAreNotManaged() throws {
        let lift = try liftoff(FakeReleases(.draft), lines: Lines(), dryRun: false)
        let unmanaged = lift.summary(build: "42", locales: ["en-GB"], screenshots: nil, appID: "123")
        #expect(unmanaged.contains("Screenshots:  not managed"))
        let managed = lift.summary(build: "42", locales: ["en-GB"], screenshots: ["en-GB APP_IPHONE_67: 4"], appID: "123")
        #expect(managed.contains("Screenshots:  en-GB APP_IPHONE_67: 4"))
        #expect(!managed.contains("Screenshots:  not managed"))
    }

    @Test func skippedMessageNamesTheMissingSection() {
        #expect(Liftoff.screenshotsSkipped.contains("no screenshots: section in .launchseq.yml"))
        #expect(Liftoff.screenshotsSkipped.contains("App Store Connect keeps the previous version's"))
    }

    @Test func dryRunAppStoreChangesHaveNoTick() async throws {
        let lines = Lines()
        let console = Console(answers: [], sink: lines.append)
        let transport = RecordingTransport { _ in (try (["data": .null] as JSONValue).data(), 200) }
        let client = ASCClient(credentials: testCredentials(), transport: transport, console: console, dryRun: true, sleep: { _ in })
        try await AppStoreConnect(client: client, console: console).attachBuild(versionID: "v1", buildID: "b1")
        #expect(lines.text.contains("[dry run] would: PATCH /v1/appStoreVersions/v1/relationships/build"))
        #expect(!lines.text.contains("✓"))
    }

    // MARK: Console

    @Test func doneIsSilentInADryRun() {
        let lines = Lines()
        let console = Console(answers: [], sink: lines.append)
        console.done("Attached build", dryRun: true)
        #expect(lines.text.isEmpty)
        console.done("Attached build", dryRun: false)
        #expect(lines.text.contains("✓ Attached build"))
    }
}
