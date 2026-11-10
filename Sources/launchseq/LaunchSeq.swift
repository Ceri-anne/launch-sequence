import ArgumentParser
import Foundation
import LaunchSequenceCore

struct GlobalOptions: ParsableArguments {
    @Flag(name: .long, help: "Show what would happen. Reads still run; nothing is changed, pushed or uploaded.")
    var dryRun = false

    @Flag(name: [.short, .long], help: "Answer yes to every confirmation.")
    var yes = false

    @Flag(name: [.short, .long], help: "Print every command and API request (never credentials).")
    var verbose = false

    @Option(name: .long, help: "Path to .launchseq.yml (default: the repo root).")
    var config: String?

    func context() throws -> Context {
        let located = try Context.locateConfig(explicit: config)
        let loaded = try Config.load(from: located.config)
        // In a dry run every change is faked, so confirmations are answered for you.
        let console = Console(verbose: verbose, assumeYes: yes || dryRun)
        return Context(config: loaded, root: located.root, console: console, dryRun: dryRun)
    }
}

@main
struct LaunchSeq: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "launchseq",
        abstract: "Release an iOS app: test, screenshot, tag, build on Xcode Cloud, and prepare the App Store version.",
        discussion: """
        Two stages:
          countdown  tests, version bump, screenshots, release notes, release PR
          liftoff    CI gate, tag, website pages, App Store Connect (stops before Submit for Review)
        """,
        version: "0.2.0",
        subcommands: [CountdownCommand.self, LiftoffCommand.self, DoctorCommand.self, InitCommand.self, MigrateCopyCommand.self]
    )

    static func main() async {
        do {
            var command = try parseAsRoot()
            if var asyncCommand = command as? AsyncParsableCommand { try await asyncCommand.run() } else { try command.run() }
        } catch let error as LaunchError {
            FileHandle.standardError.write(Data("\n✗ \(error.description)\n".utf8))
            Foundation.exit(1)
        } catch {
            exit(withError: error)
        }
    }
}

struct CountdownCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "countdown", abstract: "Test, bump the version, regenerate screenshots and release notes, and open the release PR.")

    @OptionGroup var global: GlobalOptions

    @Option(help: "Which part to bump: major, minor or patch.")
    var bump: String = "minor"

    @Option(name: .customLong("set-version"), help: "Release this exact X.Y.Z instead of bumping.")
    var exactVersion: String?

    @Flag(help: "Skip the local test run (CI is still required before liftoff).")
    var skipTests = false

    @Flag(help: "Reuse the committed screenshots.")
    var skipScreenshots = false

    @Flag(help: "Allow release notes unchanged since the last release.")
    var reuseNotes = false

    @Flag(help: "Commit straight to the base branch instead of opening a release PR.")
    var direct = false

    @Flag(help: "Forget saved progress for this version and redo every step.")
    var fresh = false

    func run() async throws {
        let ctx = try global.context()
        var options = Countdown.Options()
        if let exactVersion {
            guard let v = SemVer(exactVersion) else { throw ValidationError("--set-version must be X.Y.Z, like 2.0.0") }
            options.plan = .explicit(v)
        } else {
            guard let b = SemVer.Bump(rawValue: bump) else { throw ValidationError("--bump must be major, minor or patch") }
            options.plan = .bump(b)
        }
        options.skipTests = skipTests
        options.skipScreenshots = skipScreenshots
        options.reuseNotes = reuseNotes
        options.direct = direct
        options.fresh = fresh
        let translator = ClaudeTranslator(model: ctx.config.releaseNotes.translationModel)
        try await Countdown(ctx: ctx, options: options, translator: translator).run()
    }
}

struct LiftoffCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "liftoff", abstract: "Tag the merged release, publish website pages and prepare the App Store version. Never submits for review.")

    @OptionGroup var global: GlobalOptions

    @Flag(help: "Tag even if CI checks are missing, running or failed.")
    var force = false

    @Flag(help: "Don't publish the website pages.")
    var skipWebsite = false

    @Flag(help: "Drag the screenshots into App Store Connect yourself; liftoff checks them. Same as `screenshots.upload: manual`.")
    var manualScreenshots = false

    func run() async throws {
        var options = Liftoff.Options()
        options.force = force
        options.skipWebsite = skipWebsite
        options.manualScreenshots = manualScreenshots
        try await Liftoff(ctx: try global.context(), options: options).run()
    }
}

struct DoctorCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "doctor", abstract: "Check tools, credentials, simulators, copy and screenshots. Changes nothing.")

    @OptionGroup var global: GlobalOptions

    @Flag(help: "Don't contact App Store Connect.")
    var offline = false

    func run() async throws {
        let checks = await Doctor(ctx: try global.context()).run(checkASC: !offline)
        if checks.contains(where: { $0.level == .fail }) { throw ExitCode(1) }
    }
}

struct MigrateCopyCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "migrate-copy",
        abstract: "One-time import of Markdown App Store copy into metadata/<locale>/*.txt.",
        discussion: "Each file is FILE or FILE:LANG, where LANG is the language of fields outside any `## <code> — ` section."
    )

    @OptionGroup var global: GlobalOptions

    @Argument(help: "Markdown files, e.g. AppStoreAssets/Copy.md:en AppStoreAssets/Copy-Localized.md")
    var files: [String]

    @Option(help: "Shared support URL.") var supportUrl: String?
    @Option(help: "Shared marketing URL.") var marketingUrl: String?
    @Option(help: "Shared privacy policy URL.") var privacyUrl: String?

    @Flag(help: "Replace files that already exist.")
    var overwrite = false

    func run() async throws {
        let ctx = try global.context()
        let sources = files.map { spec -> MigrateCopy.Source in
            let parts = spec.split(separator: ":", maxSplits: 1).map(String.init)
            return .init(path: parts[0], defaultLanguage: parts.count > 1 ? parts[1] : nil)
        }
        var urls: [LocaleMetadata.Field: String] = [:]
        if let supportUrl { urls[.supportURL] = supportUrl }
        if let marketingUrl { urls[.marketingURL] = marketingUrl }
        if let privacyUrl { urls[.privacyURL] = privacyUrl }
        let written = try MigrateCopy(ctx: ctx).run(sources: sources, urls: urls, overwrite: overwrite)
        let files = "\(written.count) file\(written.count == 1 ? "" : "s")"
        if ctx.dryRun {
            ctx.console.stage("Would write \(files). Nothing was changed.")
        } else {
            ctx.console.stage("Wrote \(files). Run `launchseq doctor` to check them.")
        }
    }
}

struct InitCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "init",
        abstract: "Draft a .launchseq.yml from the project, its version file and the installed simulators."
    )

    @Flag(name: .long, help: "Print the draft instead of writing it.")
    var dryRun = false

    @Flag(name: [.short, .long], help: "Print every command run.")
    var verbose = false

    @Flag(help: "Replace an existing .launchseq.yml.")
    var force = false

    func run() async throws {
        let root = try Init.repoRoot()
        let console = Console(verbose: verbose)
        let shell = Shell(runner: ProcessRunner(), console: console, dryRun: dryRun, root: root)
        try Init(root: root, shell: shell, console: console).run(force: force)
    }
}
