import Foundation

/// Stage one: test, bump, regenerate screenshots and release notes, and open the release PR.
public struct Countdown: Sendable {
    public struct Options: Sendable {
        public var plan: VersionPlan = .bump(.minor)
        public var skipTests = false
        public var skipScreenshots = false
        public var reuseNotes = false
        public var direct = false
        public var fresh = false
        public init() {}
    }

    let ctx: Context
    let options: Options
    let translator: Translating?

    public init(ctx: Context, options: Options, translator: Translating? = nil) {
        self.ctx = ctx; self.options = options; self.translator = translator
    }

    var config: Config { ctx.config }
    var console: Console { ctx.console }

    public func run() async throws {
        console.stage("Countdown: \(config.app.name)")
        if ctx.dryRun { console.info("Dry run: nothing is committed, pushed, built or captured.") }

        // 1. Preflight
        // Changes are only allowed if they're this version's own output (checked once the version is known).
        let dirty = try ctx.git.dirtyPaths()
        try refuseOtherChanges(dirty)
        guard try ctx.github.authStatus() else { throw LaunchError.precondition("gh isn't signed in: run `gh auth login`.") }
        try ctx.git.fetch()

        // 2. Version
        let latestTag = SemVer.latest(in: try ctx.git.tags())
        let baseText = try ctx.git.show(ctx.remoteBase, path: config.version.file) ?? ""
        let decision = try options.plan.decide(latestTag: latestTag, fileVersion: try ctx.fileVersion(baseText))
        let version = decision.version
        decision.notes.forEach { console.info($0) }
        console.ok("Releasing \(version) (last release: \(latestTag.map(\.description) ?? "none"))")
        guard try !ctx.git.tagExists(version.description) else { throw LaunchError.precondition("Tag \(version) already exists. Run liftoff, or pick another version.") }

        let gitDir = try ctx.git.gitDir()
        var state = options.fresh ? RunState(version: version.description) : RunState.load(gitDir: gitDir, version: version.description)
        let branch = config.release.branchPrefix + version.description
        let lastTag = latestTag.map(\.description)
        if !dirty.isEmpty { try checkResuming(dirty, version: version, branch: branch, gitDir: gitDir) }

        // 3. Copy (everything except release notes) is checked before anything slow runs.
        console.stage("Checking App Store copy")
        let early = Metadata.validate(try loadMetadata(), requireReleaseNotes: false).filter { !$0.contains("release_notes.txt") }
        guard early.isEmpty else { throw LaunchError.validation(early) }
        console.ok("Copy is within limits for \(ctx.ascLocales.joined(separator: ", "))")

        // 4. Branch
        if !options.direct {
            let onBranch = try ctx.git.currentBranch() == branch
            if try onBranch || ctx.git.branchExists(branch) {
                try checkReleaseHistory(branch: branch, version: version)
                if !onBranch { try ctx.git.switchBranch(branch) }
                console.ok("Continuing on \(branch)")
            } else {
                try ctx.git.checkoutNewBranch(branch, from: ctx.remoteBase)
                if !ctx.dryRun { console.ok("Created \(branch) from \(ctx.remoteBase)") }
            }
            state.mark("branch", branch); try state.save(gitDir: gitDir, dryRun: ctx.dryRun)
        } else {
            guard try ctx.git.currentBranch() == config.release.baseBranch else {
                throw LaunchError.precondition("--direct commits to \(config.release.baseBranch); switch to it first.")
            }
            guard try ctx.git.revParse("HEAD") == ctx.git.revParse(ctx.remoteBase) else {
                throw LaunchError.precondition("Local \(config.release.baseBranch) differs from \(ctx.remoteBase). Rebase it first: git pull --rebase")
            }
        }

        // 5. Tests
        try generateProject()
        if options.skipTests {
            console.warn("Skipping tests (--skip-tests). Liftoff still requires green CI on \(config.release.baseBranch).")
        } else if let at = state.done["tests"], at == (try? ctx.git.revParse("HEAD")) {
            console.ok("Tests already passed on this commit")
        } else {
            try runTests()
            state.mark("tests", try ctx.git.revParse("HEAD")); try state.save(gitDir: gitDir, dryRun: ctx.dryRun)
        }

        // 6. Version bump
        console.stage("Version")
        let versionURL = try ctx.versionFileURL
        let text = try String(contentsOf: versionURL, encoding: .utf8)
        let updated = try VersionFile.write(text, key: config.version.key, version: version)
        if updated != text {
            if ctx.dryRun { console.dry("set \(config.version.key) to \(version) in \(config.version.file)") }
            else { try updated.write(to: versionURL, atomically: true, encoding: .utf8) }
        }
        console.ok("\(config.version.key) = \(version)")

        // 7. Screenshots
        if config.screenshots != nil {
            console.stage("Screenshots")
            if options.skipScreenshots || state.has("screenshots") {
                if options.skipScreenshots { console.warn("Reusing the raw captures (--skip-screenshots)") }
                else { console.ok("Already captured for \(version) (use --fresh to redo)") }
                if try ScreenshotFreshness.framesAreStale(config: config, root: ctx.root) {
                    console.step("The raw captures are newer than the framed screenshots, so rendering them again")
                    try ScreenshotCapture(config: config, shell: ctx.shell, console: console).render()
                } else {
                    console.ok("Framed screenshots are up to date with the raw captures")
                }
            } else {
                let capture = try ScreenshotCapture(config: config, shell: ctx.shell, console: console)
                try capture.build()
                try capture.capture()
                try capture.render()
                state.mark("screenshots"); try state.save(gitDir: gitDir, dryRun: ctx.dryRun)
            }
            if !ctx.dryRun {
                let problems = try ScreenshotValidator.validate(config: config, root: ctx.root)
                guard problems.isEmpty else { throw LaunchError.validation(problems) }
                console.ok("Every screenshot is present and the right size")
            }
        }

        // 8. Release notes
        console.stage("Release notes")
        try await prepareReleaseNotes(since: lastTag, version: version)

        // 9. Full copy validation
        let problems = Metadata.validate(try loadMetadata())
        guard ctx.dryRun || problems.isEmpty else { throw LaunchError.validation(problems) }
        if !problems.isEmpty { problems.forEach { console.warn($0) } } else { console.ok("All copy valid, release notes included") }

        // 10. Privacy-sensitive changes without website changes
        if let lastTag { try checkPrivacySensitive(since: lastTag) }

        // 11. Commit and PR
        console.stage(options.direct ? "Commit to \(config.release.baseBranch)" : "Release PR")
        var paths = [config.version.file, config.appStore.metadataDir]
        if let s = config.screenshots { paths += [s.rawDir, s.outputDir] }
        try ctx.git.add(paths.filter { FileManager.default.fileExists(atPath: ctx.root.appendingPathComponent($0).path) })
        let hasChanges = try ctx.dryRun || ctx.git.hasStagedChanges()
        if hasChanges {
            // Always a new commit: countdown never amends, so it can't rewrite a commit it didn't make.
            let again = try !ctx.dryRun && ctx.git.revParse("HEAD") != ctx.git.revParse(ctx.remoteBase) && !options.direct
            try ctx.git.commit(message: "\(Self.commitSubject(version))\(again ? ": updates" : "")\n\nVersion bump, App Store screenshots and release notes for \(version), prepared by launchseq countdown.")
        }
        let notes = (try? Metadata.read(ctx.root.appendingPathComponent(LocaleMetadata.path(metadataDir: config.appStore.metadataDir, locale: config.appStore.primaryLocale, field: .releaseNotes)))) ?? nil
        if options.direct {
            try console.require("Push the release commit straight to \(config.release.baseBranch)?")
            try ctx.git.push(branch: config.release.baseBranch, setUpstream: false)
            if !ctx.dryRun { console.ok("Pushed. Next: launchseq liftoff") }
        } else {
            try ctx.git.push(branch: branch)
            if let existing = try ctx.github.pullRequest(head: branch), existing.state == "OPEN" {
                console.ok("Release PR already open: \(existing.url)")
            } else {
                let body = """
                Release \(version), prepared by `launchseq countdown`.

                - \(config.version.key) → \(version)
                - Screenshots regenerated\(options.skipScreenshots ? " (skipped: reused)" : "") for \(config.languages.map(\.code).joined(separator: ", "))
                - Release notes for \(ctx.ascLocales.joined(separator: ", "))\(translator == nil ? "" : " (translated by Claude, please check them)")

                ### What's New (\(config.appStore.primaryLocale))

                \(notes ?? "")

                Review the screenshots and translations, then **Rebase and merge**. After that, run `launchseq liftoff` on an up-to-date \(config.release.baseBranch).
                """
                let url = try ctx.github.createPullRequest(base: config.release.baseBranch, head: branch, title: "Release \(version)", body: body)
                if !ctx.dryRun { console.ok("Opened \(url.isEmpty ? "the release PR" : url)") }
            }
            console.info("Next: review and Rebase and merge the PR, then `git switch \(config.release.baseBranch) && git pull --rebase && launchseq liftoff`.")
        }
    }

    static func commitSubject(_ version: SemVer) -> String { "Release \(version)" }

    /// Paths countdown writes: the version file, release notes, screenshots and its own logs.
    var generatedPaths: [String] {
        var paths = [config.version.file, "build/launchseq/"]
        paths += ctx.ascLocales.map(notesPath)
        if let s = config.screenshots { paths += [s.rawDir + "/", s.outputDir + "/"] }
        return paths
    }

    static func isGenerated(_ path: String, by generated: [String]) -> Bool {
        generated.contains { $0.hasSuffix("/") ? path.hasPrefix($0) : path == $0 }
    }

    /// Stops if anything other than countdown's own output has changed.
    func refuseOtherChanges(_ dirty: [String]) throws {
        let other = dirty.filter { !Self.isGenerated($0, by: generatedPaths) }
        guard !other.isEmpty else { return }
        let listed = other.prefix(10).map { "      \($0)" }.joined(separator: "\n") + (other.count > 10 ? "\n      …and \(other.count - 10) more" : "")
        throw LaunchError.precondition("Commit or put aside your changes first: the working tree isn't clean.\n\(listed)")
    }

    /// Allows countdown's own leftover output only when it's from a run of this same version, on its branch.
    func checkResuming(_ dirty: [String], version: SemVer, branch: String, gitDir: URL) throws {
        let saved = RunState.saved(gitDir: gitDir)
        let expectedBranch = options.direct ? config.release.baseBranch : branch
        let current = try ctx.git.currentBranch()
        guard let saved, saved.version == version.description, current == expectedBranch else {
            let from = saved.map { "a countdown run for \($0.version)" } ?? "an earlier countdown run"
            throw LaunchError.precondition("""
                The working tree has changes in countdown's own files (\(dirty.count)), but they aren't from a run of \(version) on \(expectedBranch) \
                (they look like \(from), and you're on \(current)). Commit or put them aside first.
                """)
        }
        console.ok("Picking up the last run of \(version): \(dirty.count) generated file\(dirty.count == 1 ? "" : "s") changed")
    }

    /// An existing release branch must sit on top of the base branch and hold only countdown's commits.
    func checkReleaseHistory(branch: String, version: SemVer) throws {
        guard try ctx.git.isAncestor(ctx.remoteBase, of: branch) else {
            throw LaunchError.precondition("""
                \(branch) doesn't start from the latest \(ctx.remoteBase). Rebase it (git rebase \(ctx.remoteBase)), \
                or delete it (git branch -D \(branch)) to start again.
                """)
        }
        let foreign = try ctx.git.subjects(from: ctx.remoteBase, to: branch).filter { !$0.hasPrefix(Self.commitSubject(version)) }
        guard foreign.isEmpty else {
            throw LaunchError.precondition("""
                \(branch) has commits countdown didn't make: \(foreign.prefix(5).map { "\"\($0)\"" }.joined(separator: ", ")). \
                Move them to \(config.release.baseBranch) first, or delete the branch (git branch -D \(branch)) to start again.
                """)
        }
    }

    func loadMetadata() throws -> [LocaleMetadata] {
        try Metadata.load(root: ctx.root, metadataDir: config.appStore.metadataDir, locales: ctx.ascLocales)
    }

    func generateProject() throws {
        guard let generate = config.app.generate, !generate.isEmpty else { return }
        console.step("Generating the project with \(Shell.display(generate))")
        try ctx.shell.change(generate, mode: .log(ctx.root.appendingPathComponent("build/launchseq/logs/generate.log")))
    }

    func runTests() throws {
        console.stage("Tests")
        console.step("\(config.test.scheme) on \(config.test.simulator.name) (\(config.test.simulator.platform) \(config.test.simulator.os))")
        let log = ctx.root.appendingPathComponent("build/launchseq/logs/test.log")
        try ctx.shell.change([
            "xcodebuild", "test", "-project", config.app.project, "-scheme", config.test.scheme,
            "-destination", config.test.simulator.destination,
        ], mode: .log(log))
        if !ctx.dryRun { console.ok("Tests passed (log: build/launchseq/logs/test.log)") }
    }

    func notesPath(_ locale: String) -> String {
        LocaleMetadata.path(metadataDir: config.appStore.metadataDir, locale: locale, field: .releaseNotes)
    }

    /// Whether this locale's notes are new since the last release (not the same text the tag shipped).
    func notesAreFresh(_ locale: String, since tag: String?) throws -> Bool {
        let current = try Metadata.read(ctx.root.appendingPathComponent(notesPath(locale)))
        guard let current else { return false }
        guard let tag, let old = try ctx.git.show(tag, path: notesPath(locale)) else { return true }
        return old.trimmingCharacters(in: .whitespacesAndNewlines) != current
    }

    func prepareReleaseNotes(since tag: String?, version: SemVer) async throws {
        let primary = config.appStore.primaryLocale
        let primaryURL = ctx.root.appendingPathComponent(notesPath(primary))

        if try notesAreFresh(primary, since: tag) {
            console.ok("\(primary): release notes already written for \(version)")
        } else if options.reuseNotes {
            console.warn("\(primary): reusing last release's notes (--reuse-notes)")
        } else {
            let draft = ReleaseNotesDraft.draft(subjects: try ctx.git.subjects(from: tag, to: "HEAD"), ignore: config.releaseNotes.ignore)
            if ctx.dryRun {
                console.dry("write this draft to \(notesPath(primary)) and open it in your editor:\n" + draft.split(separator: "\n").map { "        \($0)" }.joined(separator: "\n"))
                return
            }
            try FileManager.default.createDirectory(at: primaryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try (draft + "\n").write(to: primaryURL, atomically: true, encoding: .utf8)
            try edit(primaryURL)
            guard try notesAreFresh(primary, since: tag) else {
                throw LaunchError.validation(["\(primary): release notes are empty or unchanged from \(tag ?? "the last release")"])
            }
        }

        let english = try Metadata.read(primaryURL) ?? ""
        let others = ctx.ascLocales.filter { $0 != primary }
        for locale in others {
            if try notesAreFresh(locale, since: tag) {
                let text = try Metadata.read(ctx.root.appendingPathComponent(notesPath(locale))) ?? ""
                if !text.contains("TODO") { console.ok("\(locale): already has notes for \(version)"); continue }
            }
            if options.reuseNotes { continue }
            let url = ctx.root.appendingPathComponent(notesPath(locale))
            if ctx.dryRun { console.dry("\(translator == nil ? "write a TODO stub to" : "translate the notes into") \(notesPath(locale))"); continue }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let translator {
                let tone = try Metadata.read(ctx.root.appendingPathComponent(LocaleMetadata.path(metadataDir: config.appStore.metadataDir, locale: locale, field: .description)))
                console.step("\(locale): translating the release notes…")
                let translated = try await console.whileWorking("translating into \(locale)") {
                    try await translator.translate(english, to: locale, toneReference: tone, limit: LocaleMetadata.Field.releaseNotes.limit!)
                }
                try (translated + "\n").write(to: url, atomically: true, encoding: .utf8)
                console.ok("\(locale): translated")
            } else {
                try (ReleaseNotesDraft.todoStub(locale: locale) + "\n").write(to: url, atomically: true, encoding: .utf8)
                console.warn("\(locale): wrote a TODO stub")
            }
        }

        if !options.reuseNotes {
            let stale = try ctx.ascLocales.filter { try !notesAreFresh($0, since: tag) }
            guard stale.isEmpty || ctx.dryRun else {
                throw LaunchError.validation(stale.map { "\($0): release notes are unchanged from \(tag ?? "the last release") (pass --reuse-notes to ship them again)" })
            }
        }
        let todo = try ctx.ascLocales.filter { (try Metadata.read(ctx.root.appendingPathComponent(notesPath($0))) ?? "").contains("TODO") }
        if !todo.isEmpty {
            throw LaunchError.validation(todo.map { "\($0): translate \(notesPath($0)), then run countdown again" })
        }
    }

    func edit(_ file: URL) throws {
        let editor = ProcessInfo.processInfo.environment["VISUAL"] ?? ProcessInfo.processInfo.environment["EDITOR"] ?? "vi"
        let parts = editor.split(separator: " ").map(String.init)
        guard ForegroundSpawn.ownsTerminal else {
            // Without the terminal's foreground, an editor here would be stopped before it appears.
            try console.pause("Edit the release notes draft in your own editor:\n     \(file.path)", acknowledgement: "Got it, reading the release notes…")
            return
        }
        console.step("Opening the draft in \(parts[0]). Save and close it to carry on.")
        let result = try ctx.shell.runner.run(parts + [file.path], cwd: ctx.root, environment: [:], mode: .interactive)
        guard result.status == 0 else { throw LaunchError.aborted("the editor exited with \(result.status)") }
    }

    func checkPrivacySensitive(since tag: String) throws {
        guard !config.privacySensitivePaths.isEmpty, let site = config.website else { return }
        let changed = try ctx.git.changedFiles(from: tag, to: "HEAD")
        let sensitive = changed.filter { path in config.privacySensitivePaths.contains { Glob.matches($0, path) } }
        guard !sensitive.isEmpty else { return }
        let siteChanged = changed.contains { $0.hasPrefix(site.source + "/") }
        if siteChanged { console.ok("Privacy-sensitive code changed and \(site.source)/ was updated too"); return }
        console.warn("These changed since \(tag) and may affect what the privacy, support or accessibility pages say, but \(site.source)/ hasn't changed:")
        sensitive.prefix(15).forEach { console.info("      \($0)") }
        try console.require("Carry on without updating the website pages?")
    }
}
