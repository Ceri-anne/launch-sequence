import Foundation
import Testing
@testable import LaunchSequenceCore

/// A real clone of a local bare "origin", with one commit on main.
struct Repo {
    let root: URL
    let origin: URL

    init() throws {
        let base = try tempDir()
        origin = base.appendingPathComponent("origin.git")
        root = base.appendingPathComponent("app")
        try Repo.git(["init", "--quiet", "--bare", "-b", "main", origin.path], in: base)
        try Repo.git(["clone", "--quiet", origin.path, root.path], in: base)
        try write("README.md", "hello\n")
        try commit("First")
        try git(["push", "--quiet", "-u", "origin", "main"])
        try git(["fetch", "--quiet"])
    }

    @discardableResult
    static func git(_ args: [String], in dir: URL) throws -> String {
        let env = ["GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.com", "GIT_COMMITTER_NAME": "Test",
                   "GIT_COMMITTER_EMAIL": "test@example.com", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"]
        let result = try ProcessRunner().run(["git"] + args, cwd: dir, environment: env, mode: .capture)
        guard result.status == 0 else { throw LaunchError.precondition("git \(args.joined(separator: " ")): \(result.stderr)") }
        return result.trimmed
    }

    @discardableResult
    func git(_ args: [String]) throws -> String { try Repo.git(args, in: root) }

    func write(_ path: String, _ text: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func commit(_ subject: String) throws {
        try git(["add", "-A"])
        try git(["commit", "--quiet", "--allow-empty", "-m", subject])
    }

    var gitDir: URL { get throws { URL(fileURLWithPath: try git(["rev-parse", "--absolute-git-dir"])) } }

    func countdown(lines: Lines = Lines(), direct: Bool = false) throws -> Countdown {
        let ctx = Context(config: try Config.parse(try fixture("launchseq.yml")), root: root,
                          console: Console(answers: [], sink: lines.append), runner: GitEnvRunner(), dryRun: false)
        var options = Countdown.Options()
        options.direct = direct
        return Countdown(ctx: ctx, options: options)
    }
}

/// Runs real commands with the test identity, so commits work on any machine.
struct GitEnvRunner: CommandRunning {
    func run(_ arguments: [String], cwd: URL?, environment: [String: String], mode: OutputMode) throws -> CommandResult {
        var env = environment
        env["GIT_CONFIG_GLOBAL"] = "/dev/null"; env["GIT_CONFIG_NOSYSTEM"] = "1"
        env["GIT_AUTHOR_NAME"] = "Test"; env["GIT_AUTHOR_EMAIL"] = "test@example.com"
        env["GIT_COMMITTER_NAME"] = "Test"; env["GIT_COMMITTER_EMAIL"] = "test@example.com"
        return try ProcessRunner().run(arguments, cwd: cwd, environment: env, mode: mode)
    }
}

@Suite("Resuming countdown")
struct ResumeTests {
    let version = SemVer(1, 3, 0)
    let branch = "release/1.3.0"

    func notes(_ c: Countdown) -> String { c.notesPath("en-GB") }
    func raw(_ c: Countdown) -> String { c.config.screenshots!.rawDir }
    func framed(_ c: Countdown) -> String { c.config.screenshots!.outputDir }

    // MARK: Uncommitted changes

    @Test func readsEveryKindOfChangeFromGit() throws {
        let repo = try Repo()
        try repo.write("old.txt", "x\n"); try repo.commit("Add old")
        try repo.write("README.md", "changed\n")
        try repo.write("new folder/a b.txt", "untracked, with a space\n")
        try repo.git(["mv", "old.txt", "renamed.txt"])
        let paths = try Git(shell: try repo.countdown().ctx.shell).dirtyPaths()
        #expect(Set(paths) == ["README.md", "new folder/a b.txt", "renamed.txt", "old.txt"])
    }

    @Test func allowsOnlyCountdownsOwnFiles() throws {
        let c = try Repo().countdown()
        #expect(throws: Never.self) {
            try c.refuseOtherChanges([c.config.version.file, notes(c), "\(raw(c))/en/iPhone/01-decide.png",
                                      "\(framed(c))/en/iPhone/01-decide.png", "build/launchseq/logs/test.log"])
        }
        let error = #expect(throws: LaunchError.self) {
            try c.refuseOtherChanges([notes(c), "Sources/App.swift", "\(raw(c))-old/x.png"])
        }
        #expect("\(error!)".contains("Sources/App.swift"))
        #expect("\(error!)".contains("\(raw(c))-old/x.png"))
        #expect(!"\(error!)".contains("release_notes"))
    }

    @Test func otherLocalesNotesCountButNotOtherMetadata() throws {
        let c = try Repo().countdown()
        #expect(throws: Never.self) { try c.refuseOtherChanges([c.notesPath("fr-FR")]) }
        let description = LocaleMetadata.path(metadataDir: c.config.appStore.metadataDir, locale: "en-GB", field: .description)
        #expect(throws: LaunchError.self) { try c.refuseOtherChanges([description]) }
    }

    @Test func resumesWhenTheSavedRunMatches() throws {
        let repo = try Repo()
        try repo.git(["switch", "--quiet", "-c", branch])
        try RunState(version: "1.3.0", done: ["branch": branch]).save(gitDir: try repo.gitDir, dryRun: false)
        let lines = Lines()
        let c = try repo.countdown(lines: lines)
        try c.checkResuming([notes(c)], version: version, branch: branch, gitDir: try repo.gitDir)
        #expect(lines.text.contains("Picking up the last run of 1.3.0: 1 generated file changed"))
    }

    @Test func refusesLeftoversFromAnotherVersion() throws {
        let repo = try Repo()
        try repo.git(["switch", "--quiet", "-c", branch])
        try RunState(version: "1.2.0").save(gitDir: try repo.gitDir, dryRun: false)
        let c = try repo.countdown()
        let error = #expect(throws: LaunchError.self) {
            try c.checkResuming([notes(c)], version: version, branch: branch, gitDir: try repo.gitDir)
        }
        #expect("\(error!)".contains("a countdown run for 1.2.0"))
    }

    @Test func refusesLeftoversWithNoSavedRun() throws {
        let repo = try Repo()
        try repo.git(["switch", "--quiet", "-c", branch])
        let c = try repo.countdown()
        #expect(throws: LaunchError.self) {
            try c.checkResuming([notes(c)], version: version, branch: branch, gitDir: try repo.gitDir)
        }
    }

    @Test func refusesLeftoversOnTheWrongBranch() throws {
        let repo = try Repo()
        try RunState(version: "1.3.0").save(gitDir: try repo.gitDir, dryRun: false)
        let c = try repo.countdown()
        let error = #expect(throws: LaunchError.self) {
            try c.checkResuming([notes(c)], version: version, branch: branch, gitDir: try repo.gitDir)
        }
        #expect("\(error!)".contains("you're on main"))
    }

    // MARK: Release branch history

    @Test func acceptsABranchOfCountdownCommitsOnTopOfMain() throws {
        let repo = try Repo()
        try repo.git(["switch", "--quiet", "-c", branch])
        try repo.write("notes.txt", "1\n"); try repo.commit("Release 1.3.0")
        try repo.write("notes.txt", "2\n"); try repo.commit("Release 1.3.0: updates")
        #expect(throws: Never.self) { try repo.countdown().checkReleaseHistory(branch: branch, version: version) }
    }

    @Test func refusesABranchWithSomeoneElsesCommit() throws {
        let repo = try Repo()
        try repo.git(["switch", "--quiet", "-c", branch])
        try repo.write("App.swift", "x\n"); try repo.commit("Fix the timer")
        try repo.write("notes.txt", "1\n"); try repo.commit("Release 1.3.0")
        let error = #expect(throws: LaunchError.self) { try repo.countdown().checkReleaseHistory(branch: branch, version: version) }
        #expect("\(error!)".contains("\"Fix the timer\""))
    }

    @Test func refusesABranchThatDoesntStartFromOriginMain() throws {
        // The 1.2.0 problem: a branch made before main moved on, so it doesn't contain origin/main.
        let repo = try Repo()
        try repo.git(["branch", branch])
        try repo.write("App.swift", "x\n"); try repo.commit("Land a feature")
        try repo.git(["push", "--quiet", "origin", "main"])
        try repo.git(["fetch", "--quiet"])
        let error = #expect(throws: LaunchError.self) { try repo.countdown().checkReleaseHistory(branch: branch, version: version) }
        #expect("\(error!)".contains("doesn't start from the latest origin/main"))
    }

    @Test func detectsAnExistingBranch() throws {
        let repo = try Repo()
        let git = Git(shell: try repo.countdown().ctx.shell)
        #expect(try !git.branchExists(branch))
        try repo.git(["branch", branch])
        #expect(try git.branchExists(branch))
    }

    @Test func parsesRenamesAndCopiesFromPorcelain() {
        let out = "R  new.txt\0old.txt\0 M a.txt\0?? b c.txt\0"
        #expect(Git.parsePorcelain(out) == ["new.txt", "old.txt", "a.txt", "b c.txt"])
    }

    // MARK: Stale framed screenshots

    func shot(_ repo: Repo, _ path: String, age: TimeInterval) throws {
        try repo.write(path, "png")
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: repo.root.appendingPathComponent(path).path)
    }

    @Test func framesAreStaleWhenARawCaptureIsNewer() throws {
        let repo = try Repo(); let c = try repo.countdown()
        try shot(repo, "\(framed(c))/en/iPhone/01-decide.png", age: 100)
        try shot(repo, "\(framed(c))/fr/iPhone/01-decide.png", age: 100)
        try shot(repo, "\(framed(c))/cy/iPhone/01-decide.png", age: 100)
        try shot(repo, "\(raw(c))/en/iPhone/01-decide.png", age: 200)
        #expect(try !ScreenshotFreshness.framesAreStale(config: c.config, root: repo.root))
        try shot(repo, "\(raw(c))/fr/iPhone/01-decide.png", age: 10)
        #expect(try ScreenshotFreshness.framesAreStale(config: c.config, root: repo.root))
    }

    @Test func framesAreStaleWhenOneIsMissing() throws {
        let repo = try Repo(); let c = try repo.countdown()
        try shot(repo, "\(raw(c))/en/iPhone/01-decide.png", age: 200)
        try shot(repo, "\(framed(c))/en/iPhone/01-decide.png", age: 100)
        #expect(try ScreenshotFreshness.framesAreStale(config: c.config, root: repo.root))
    }

    @Test func noRawCapturesMeansNothingToRender() throws {
        let repo = try Repo(); let c = try repo.countdown()
        #expect(try !ScreenshotFreshness.framesAreStale(config: c.config, root: repo.root))
    }
}
