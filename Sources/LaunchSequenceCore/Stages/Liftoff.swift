import Foundation

/// Stage two: tag the merged release, let Xcode Cloud build it, publish the website
/// pages, and prepare the App Store version. It stops before submitting for review.
public struct Liftoff: Sendable {
    public struct Options: Sendable {
        public var force = false
        public var skipWebsite = false
        /// Drag the screenshots into App Store Connect yourself, whatever the config says.
        public var manualScreenshots = false
        public init() {}
    }

    let ctx: Context
    let options: Options
    let transport: HTTPTransport
    let sleep: @Sendable (Double) -> Void
    let credentials: @Sendable () throws -> ASCCredentials

    public init(ctx: Context, options: Options, transport: HTTPTransport = URLSessionTransport(),
                sleep: @escaping @Sendable (Double) -> Void = { Thread.sleep(forTimeInterval: $0) },
                credentials: @escaping @Sendable () throws -> ASCCredentials = { try ASCCredentials.load() }) {
        self.ctx = ctx; self.options = options; self.transport = transport; self.sleep = sleep; self.credentials = credentials
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
        if !tagExists { try await checkCI(repo: repo, commit: commit) }

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
        let creds = try credentials()
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
        if config.screenshots != nil {
            let manual = options.manualScreenshots || config.screenshots?.upload == .manual
            console.step("Screenshots\(manual ? " (you drag them in, liftoff checks them)" : "")")
            if manual { console.info("App Store Connect: https://appstoreconnect.apple.com/apps/\(appID)/distribution/ios/version/inflight") }
            for language in config.languages {
                guard let locale = language.ascLocale else { continue }
                // Devices that share a display type (e.g. a foldable's folded and unfolded
                // captures) fill one App Store slot, in the order the config lists them.
                for group in ScreenshotValidator.slots(config: config, language: language.code) {
                    let locals = try slotFiles(language: language.code, group: group, renameForUpload: manual)
                    guard !locals.isEmpty else { continue }
                    let locID = locIDs[locale] ?? "dryrun-loc-\(locale)"
                    let result = manual
                        ? try await placeByHand(asc: asc, localizationID: locID, locale: locale, group: group, files: locals)
                        : try await asc.syncScreenshots(localizationID: locID, displayType: group.displayType, files: locals, label: "\(locale) \(group.displayType)")
                    switch result {
                    case .unchanged: console.ok("\(locale) \(group.displayType): unchanged")
                    case .replaced(let n): console.ok("\(locale) \(group.displayType): \(manual ? "your \(n) match the local files" : "uploaded \(n)")")
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

    /// The framed screenshots for one App Store slot, in upload order. When a slot is filled
    /// from several devices (a foldable's two captures), manual uploads are renamed
    /// `1-<device>-<scene>.png` so the names don't clash and Finder lists them in order.
    func slotFiles(language: String, group: ScreenshotValidator.Slot, renameForUpload: Bool) throws -> [AppStoreConnect.LocalScreenshot] {
        var files: [AppStoreConnect.LocalScreenshot] = []
        for (i, device) in group.devices.enumerated() {
            for file in try ScreenshotValidator.files(config: config, root: ctx.root, language: language, device: device) {
                let name = renameForUpload && group.devices.count > 1 ? "\(i + 1)-\(device.name)-\(file.lastPathComponent)" : file.lastPathComponent
                files.append(.init(fileName: name, data: try Data(contentsOf: file)))
            }
        }
        return files
    }

    /// Copies one slot's files into their own folder, `build/launchseq/upload/<locale>/<display type>`,
    /// so they can be dragged in together.
    func stage(_ files: [AppStoreConnect.LocalScreenshot], locale: String, displayType: String) throws -> URL {
        let folder = try SafePath.resolve("build/launchseq/upload/\(locale)/\(displayType)", under: ctx.root)
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for file in files { try file.data.write(to: folder.appendingPathComponent(file.fileName)) }
        return folder
    }

    /// Manual mode: asks you to drag one slot's screenshots into App Store Connect, then checks
    /// them against the local files until they match and Apple has processed them.
    func placeByHand(asc: AppStoreConnect, localizationID: String, locale: String, group: ScreenshotValidator.Slot,
                     files: [AppStoreConnect.LocalScreenshot]) async throws -> AppStoreConnect.ScreenshotResult {
        let slot = "\(locale) \(group.displayType)"
        let check = { try await asc.checkScreenshots(localizationID: localizationID, displayType: group.displayType, files: files) }
        var state = try await check()
        if state == .matches { return .unchanged }
        let devices = group.devices.map(\.name).joined(separator: " + ")
        if ctx.dryRun {
            console.dry("ask you to drag \(files.count) screenshots into \(slot) (\(devices)), then check them")
            return .unchanged
        }
        let folder = try stage(files, locale: locale, displayType: group.displayType)
        if case .different = state {
            try ctx.shell.change(["open", folder.path], allowFailure: true)
            let list = files.enumerated().map { "       \($0.offset + 1). \($0.element.fileName)" }.joined(separator: "\n")
            try console.pause("""
                In App Store Connect, go to the \(locale) screenshots for \(group.displayType) (\(devices)). \
                Delete any that are there, then drag in the \(files.count) files from the Finder window that just opened, in this order:
                \(list)
                     Folder: \(folder.path)
                     Wait until they've all appeared in App Store Connect.
                """, acknowledgement: "Got it, checking \(slot)…")
        }
        var waited = 0.0
        while true {
            state = try await check()
            switch state {
            case .matches:
                return .replaced(files.count)
            case .processing(let n):
                if waited >= 30 * 60 {
                    throw LaunchError.api("\(slot): \(n) screenshot\(n == 1 ? " is" : "s are") still processing after 30 minutes. Run liftoff again later; sets that match are skipped.")
                }
                if Int(waited) % 30 == 0 { console.info("… \(slot): \(files.count - n)/\(files.count) processed by Apple (\(Console.duration(waited)))") }
                sleep(15); waited += 15
            case .different(let problems):
                console.warn("\(slot) doesn't match the local files yet:")
                problems.forEach { console.info("      \($0)") }
                try console.pause("Fix it in App Store Connect (the files are in \(folder.path)).", acknowledgement: "Got it, checking \(slot) again…")
            }
        }
    }

    /// Requires green CI on the release commit. Waits for checks to register and finish,
    /// and if Xcode Cloud hasn't built the commit at all, offers to start the workflow.
    func checkCI(repo: String, commit: String) async throws {
        let short = String(commit.prefix(8))
        console.stage("CI checks on \(short)")
        let fetch = { try ctx.github.checks(repo: repo, commit: commit) }
        var state: GitHub.CheckState
        if options.force || ctx.dryRun {
            state = try fetch()
        } else {
            state = try waiter(appearMinutes: 5).wait(short, fetch: fetch)
        }
        if state == .none, !options.force, try await startCIBuild(commit: commit) {
            // Xcode Cloud takes a few minutes to pick up a new build and report it to GitHub.
            state = ctx.dryRun ? try fetch() : try waiter(appearMinutes: 15).wait(short, fetch: fetch)
        }
        switch state {
        case .passed(let n): console.ok("\(n) check\(n == 1 ? "" : "s") passed")
        case .pending(let names) where options.force: console.warn("Still running: \(names.joined(separator: ", ")). Carrying on (--force).")
        case .pending(let names): throw LaunchError.precondition("Checks still running after \(config.appStore.buildTimeoutMinutes) minutes: \(names.joined(separator: ", ")). Run liftoff again when they finish, or pass --force.")
        case .failed(let names) where options.force: console.warn("Failed: \(names.joined(separator: ", ")). Carrying on (--force).")
        case .failed(let names): throw LaunchError.precondition("Checks failed: \(names.joined(separator: ", ")). Fix them, or pass --force.")
        case .none where options.force: console.warn("No checks reported. Carrying on (--force).")
        case .none: throw LaunchError.precondition("No CI checks have reported on \(short). Is Xcode Cloud reporting to GitHub? Pass --force to skip this.")
        }
    }

    func waiter(appearMinutes: Double) -> CheckWaiter {
        CheckWaiter(console: console, appearMinutes: appearMinutes, finishMinutes: Double(config.appStore.buildTimeoutMinutes), sleep: sleep)
    }

    /// When no checks have reported, Xcode Cloud may not have built the commit at all
    /// (its start condition didn't fire on the push). Returns true if a build of the
    /// commit is now running, so it's worth waiting for its checks again.
    func startCIBuild(commit: String) async throws -> Bool {
        let short = String(commit.prefix(8))
        let name = config.appStore.ciWorkflow
        let branch = config.release.baseBranch
        do {
            let client = ASCClient(credentials: try credentials(), transport: transport, console: console, dryRun: ctx.dryRun)
            let appID = try await AppStoreConnect(client: client, console: console).appID(bundleID: config.appStore.bundleId, configured: config.appStore.appId)
            let cloud = XcodeCloud(client: client)
            guard let workflow = try await cloud.workflow(appID: appID, named: name) else {
                console.warn("Xcode Cloud has no workflow called \(name). Set `app_store.ci_workflow` to the one that builds \(branch).")
                return false
            }
            if let run = try await cloud.buildRun(workflowID: workflow.id, commit: commit) {
                console.info("Xcode Cloud \(name) build\(run.number.map { " \($0)" } ?? "") of \(short) is \(run.progress.lowercased()). Waiting for its checks.")
                return true
            }
            console.warn("Xcode Cloud hasn't started a \(name) build of \(short).")
            guard try console.confirm("Start the \(name) workflow on \(branch) (\(short)) now?") else { return false }
            let run = try await cloud.startBuild(workflow: workflow, branch: branch)
            if !ctx.dryRun { console.ok("Started \(name) build\(run.number.map { " \($0)" } ?? "")") }
            return true
        } catch {
            // Saying no to the prompt stops the run; anything else just means no offer.
            if case LaunchError.aborted = error { throw error }
            console.warn("Couldn't check Xcode Cloud: \((error as? LaunchError)?.description ?? error.localizedDescription)")
            return false
        }
    }

    func tagDateOf(_ tag: String) throws -> Date {
        let raw = try ctx.shell.read(["git", "for-each-ref", "refs/tags/\(tag)", "--format=%(creatordate:iso-strict)"]).trimmed
        return ISO8601DateFormatter().date(from: raw) ?? Date()
    }
}
