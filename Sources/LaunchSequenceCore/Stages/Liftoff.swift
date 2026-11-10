import Foundation

/// Stage two: tag the merged release, let Xcode Cloud build it, publish the website
/// pages, and prepare the App Store version. It stops before submitting for review.
public struct Liftoff: Sendable {
    public struct Options: Sendable {
        public var force = false
        public var skipWebsite = false
        public init() {}
    }

    let ctx: Context
    let options: Options
    let transport: HTTPTransport

    public init(ctx: Context, options: Options, transport: HTTPTransport = URLSessionTransport()) {
        self.ctx = ctx; self.options = options; self.transport = transport
    }

    var config: Config { ctx.config }
    var console: Console { ctx.console }

    public func run() async throws {
        console.stage("Liftoff: \(config.app.name)")
        if ctx.dryRun { console.info("Dry run: App Store Connect is read but not changed, and nothing is tagged or pushed.") }

        // 1. Work out what's being released.
        if try !ctx.git.isClean() {
            guard ctx.dryRun else { throw LaunchError.precondition("The working tree isn't clean.") }
            console.warn("The working tree isn't clean; the dry run uses it as it is.")
        }
        try ctx.git.fetch()
        let baseText = try ctx.git.show(ctx.remoteBase, path: config.version.file) ?? ""
        guard let version = try ctx.fileVersion(baseText) else {
            throw LaunchError.precondition("No \(config.version.key) in \(config.version.file) on \(ctx.remoteBase)")
        }
        let tag = version.description
        let tagExists = try ctx.git.tagExists(tag)
        let latest = SemVer.latest(in: try ctx.git.tags())
        if !tagExists, let latest, version <= latest {
            throw LaunchError.precondition("\(ctx.remoteBase) is at \(version), which is already released (latest tag \(latest)). Run countdown first.")
        }
        let commit = tagExists ? try ctx.git.revParse("refs/tags/\(tag)") : try ctx.git.revParse(ctx.remoteBase)
        if try ctx.git.revParse("HEAD") != commit, ctx.dryRun {
            console.warn("HEAD isn't the release commit \(commit.prefix(8)); the dry run previews this working tree's copy and screenshots.")
        } else if try ctx.git.revParse("HEAD") != commit {
            throw LaunchError.precondition("Check out the release commit first, so the copy and screenshots uploaded are the ones in the release:\n  git switch \(config.release.baseBranch) && git pull --rebase")
        }
        console.ok("Releasing \(version) from \(commit.prefix(8))\(tagExists ? " (tag already exists, resuming)" : "")")

        let gitDir = try ctx.git.gitDir()
        var state = RunState.load(gitDir: gitDir, version: tag)

        // Copy and screenshots must be valid before anything is published.
        let metadata = try Metadata.load(root: ctx.root, metadataDir: config.appStore.metadataDir, locales: ctx.ascLocales)
        let problems = Metadata.validate(metadata) + (config.screenshots == nil ? [] : try ScreenshotValidator.validate(config: config, root: ctx.root))
        guard problems.isEmpty else { throw LaunchError.validation(problems) }

        // 2. CI gate
        let repo = try ctx.github.repoName()
        if !tagExists {
            console.stage("CI checks on \(commit.prefix(8))")
            switch try ctx.github.checks(repo: repo, commit: commit) {
            case .passed(let n): console.ok("\(n) check\(n == 1 ? "" : "s") passed")
            case .pending(let names) where options.force: console.warn("Still running: \(names.joined(separator: ", ")). Carrying on (--force).")
            case .pending(let names): throw LaunchError.precondition("Checks still running: \(names.joined(separator: ", ")). Wait for them, or pass --force.")
            case .failed(let names) where options.force: console.warn("Failed: \(names.joined(separator: ", ")). Carrying on (--force).")
            case .failed(let names): throw LaunchError.precondition("Checks failed: \(names.joined(separator: ", ")). Fix them, or pass --force.")
            case .none where options.force: console.warn("No checks reported. Carrying on (--force).")
            case .none: throw LaunchError.precondition("No CI checks reported on \(commit.prefix(8)). Is Xcode Cloud reporting to GitHub? Pass --force to skip this.")
            }
        }

        // 3. Tag (this starts the Xcode Cloud Release workflow) and draft GitHub release.
        console.stage("Tag and GitHub release")
        if !tagExists {
            try console.require("Tag \(commit.prefix(8)) as \(tag) and push it? This starts the Xcode Cloud Release build.")
            try ctx.git.createAnnotatedTag(tag, at: commit, message: "\(config.app.name) \(tag)")
            try ctx.git.pushTag(tag)
            if !ctx.dryRun { console.ok("Pushed tag \(tag)") }
        } else {
            console.ok("Tag \(tag) already pushed")
        }
        let notesPath = LocaleMetadata.path(metadataDir: config.appStore.metadataDir, locale: config.appStore.primaryLocale, field: .releaseNotes)
        let englishNotes = try Metadata.read(ctx.root.appendingPathComponent(notesPath)) ?? ""
        if try !ctx.github.releaseExists(tag) {
            try ctx.github.createDraftRelease(tag: tag, notes: englishNotes)
            if !ctx.dryRun { console.ok("Created a draft GitHub release") }
        } else {
            console.ok("GitHub release already exists")
        }
        let tagDate = ctx.dryRun && !tagExists ? Date() : try tagDateOf(tag)

        // 4. Website
        if let site = config.website, !options.skipWebsite {
            console.stage("Website")
            if state.has("website") { console.ok("Already published for \(tag)") }
            else {
                switch try WebsiteSync(site: site, shell: ctx.shell, console: console).publish(appName: config.app.name, version: tag) {
                case .unchanged, .merged: state.mark("website"); try state.save(gitDir: gitDir, dryRun: ctx.dryRun)
                case .openPR(let pr): console.warn("Website PR left open: \(pr). Merge it yourself, or run liftoff again.")
                }
            }
        }

        // 5. App Store Connect
        console.stage("App Store Connect")
        let creds = try ASCCredentials.load()
        let client = ASCClient(credentials: creds, transport: transport, console: console, dryRun: ctx.dryRun)
        let asc = AppStoreConnect(client: client, console: console)
        let appID = try await asc.appID(bundleID: config.appStore.bundleId, configured: config.appStore.appId)
        let isFirst = try await !asc.hasReleasedVersion(appID: appID, platform: config.appStore.platform)
        let ascVersion = try await asc.prepareVersion(appID: appID, version: tag, platform: config.appStore.platform, releaseType: config.appStore.releaseType)
        try await asc.setPhasedRelease(versionID: ascVersion.id, enabled: config.appStore.phasedRelease)

        console.step("Copy")
        try await asc.syncAppInfoLocalizations(appID: appID, metadata: metadata)
        let locIDs = try await asc.syncVersionLocalizations(versionID: ascVersion.id, metadata: metadata, isFirstVersion: isFirst, readFrom: ascVersion.previewFrom)

        var shotSummary: [String] = []
        if let shots = config.screenshots {
            console.step("Screenshots")
            for language in config.languages {
                guard let locale = language.ascLocale else { continue }
                // Devices that share a display type (e.g. a foldable's folded and unfolded
                // captures) fill one App Store slot, in the order the config lists them.
                for group in ScreenshotValidator.slots(config: config, language: language.code) {
                    var locals: [AppStoreConnect.LocalScreenshot] = []
                    for device in group.devices {
                        for file in try ScreenshotValidator.files(config: config, root: ctx.root, language: language.code, device: device) {
                            locals.append(.init(fileName: file.lastPathComponent, data: try Data(contentsOf: file)))
                        }
                    }
                    guard !locals.isEmpty else { continue }
                    let locID = locIDs[locale] ?? "dryrun-loc-\(locale)"
                    switch try await asc.syncScreenshots(localizationID: locID, displayType: group.displayType, files: locals, label: "\(locale) \(group.displayType)") {
                    case .unchanged: console.ok("\(locale) \(group.displayType): unchanged")
                    case .replaced(let n): console.ok("\(locale) \(group.displayType): uploaded \(n)")
                    }
                    shotSummary.append("\(locale) \(group.displayType): \(locals.count)")
                }
            }
        }

        console.step("Build")
        var buildNumber = "(not yet built)"
        if let build = try await asc.waitForBuild(appID: appID, version: tag, since: tagDate, timeoutMinutes: config.appStore.buildTimeoutMinutes) {
            buildNumber = build.number
            try await asc.attachBuild(versionID: ascVersion.id, buildID: build.id)
            var whatToTest: [String: String] = [:]
            for m in metadata { if let notes = m[.releaseNotes] { whatToTest[m.locale] = notes } }
            try await asc.setWhatToTest(buildID: build.id, notes: whatToTest)
            if build.usesNonExemptEncryption == nil {
                console.warn("Export compliance isn't answered for this build. Set ITSAppUsesNonExemptEncryption in Info.plist, or answer it in App Store Connect.")
            }
        } else {
            console.dry("wait for Xcode Cloud's \(tag) build, attach it, and set TestFlight What to Test")
        }

        // 6. Publish the GitHub release now there's a build behind it.
        if !ctx.dryRun || tagExists {
            try ctx.github.publishRelease(tag: tag)
            console.ok("Published GitHub release \(tag)")
        } else {
            console.dry("publish the GitHub release \(tag)")
        }
        state.mark("liftoff"); try state.save(gitDir: gitDir, dryRun: ctx.dryRun)

        // 7. Summary. Submission is left to the person.
        console.stage("Ready for review: \(config.app.name) \(tag)")
        console.info("Build:        \(buildNumber)")
        console.info("Locales:      \(metadata.map(\.locale).joined(separator: ", "))")
        if !shotSummary.isEmpty { console.info("Screenshots:  \(shotSummary.joined(separator: ", "))") }
        console.info("Release:      \(config.appStore.releaseType.lowercased().replacingOccurrences(of: "_", with: " ")), phased \(config.appStore.phasedRelease ? "on" : "off")")
        console.info("Check it, then press Submit for Review yourself:")
        console.info("https://appstoreconnect.apple.com/apps/\(appID)/distribution/ios/version/inflight")
    }

    func tagDateOf(_ tag: String) throws -> Date {
        let raw = try ctx.shell.read(["git", "for-each-ref", "refs/tags/\(tag)", "--format=%(creatordate:iso-strict)"]).trimmed
        return ISO8601DateFormatter().date(from: raw) ?? Date()
    }
}
