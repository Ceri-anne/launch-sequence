import Foundation

/// Checks everything a release needs, without changing anything.
public struct Doctor: Sendable {
    let ctx: Context
    let transport: HTTPTransport
    let sleep: @Sendable (Double) -> Void

    public init(ctx: Context, transport: HTTPTransport = URLSessionTransport(),
                sleep: @escaping @Sendable (Double) -> Void = { Thread.sleep(forTimeInterval: $0) }) {
        self.ctx = ctx; self.transport = transport; self.sleep = sleep
    }

    public enum Level: Sendable { case pass, warn, fail }
    public struct Check: Sendable { public var level: Level; public var message: String }

    public func run(checkASC: Bool = true, checkCapture: Bool = true) async -> [Check] {
        var checks: [Check] = []
        func add(_ level: Level, _ message: String) {
            checks.append(Check(level: level, message: message))
            switch level {
            case .pass: ctx.console.ok(message)
            case .warn: ctx.console.warn(message)
            case .fail: ctx.console.info("✗ \(message)")
            }
        }
        let config = ctx.config
        ctx.console.stage("Doctor: \(config.app.name)")

        var tools = ["git", "gh", "xcodebuild", "xcrun"]
        if let gen = config.app.generate?.first { tools.append(gen) }
        if let hook = config.screenshots?.render?.first { tools.append(hook) }
        for tool in Set(tools).sorted() {
            do { _ = try ProcessRunner.locate(tool); add(.pass, "\(tool) is installed") }
            catch { add(.fail, "\(tool) isn't installed or isn't on PATH") }
        }

        if (try? ctx.github.authStatus()) == true { add(.pass, "gh is signed in") } else { add(.fail, "gh isn't signed in: run `gh auth login`") }
        if (try? ctx.git.isClean()) == true { add(.pass, "Working tree is clean") } else { add(.warn, "Working tree has uncommitted changes") }

        do {
            let latest = SemVer.latest(in: try ctx.git.tags())
            add(.pass, "Latest release tag: \(latest.map(\.description) ?? "none")")
            let text = try String(contentsOf: try ctx.versionFileURL, encoding: .utf8)
            if let v = try ctx.fileVersion(text) { add(.pass, "\(config.version.file) \(config.version.key) is \(v)") }
            else { add(.fail, "No \(config.version.key) found in \(config.version.file)") }
        } catch { add(.fail, "Version: \(error)") }

        // Simulators
        if let json = try? ctx.shell.read(["xcrun", "simctl", "list", "devices", "--json"]).stdout {
            var sims = [config.test.simulator]
            sims += config.screenshots?.builds.map(\.simulator) ?? []
            sims += config.screenshots?.devices.map(\.simulator) ?? []
            var seen = Set<String>()
            for sim in sims where seen.insert(sim.destination).inserted {
                if (try? Simulators.find(sim, in: Data(json.utf8))) ?? nil != nil { add(.pass, "Simulator \(sim.name) (\(sim.platform) \(sim.os))") }
                else { add(.fail, "No simulator \(sim.name) on \(sim.platform) \(sim.os)") }
            }
            if checkCapture, let check = captureCheck(listJSON: json) { add(check.level, check.message) }
        }

        // Copy
        do {
            let metadata = try Metadata.load(root: ctx.root, metadataDir: config.appStore.metadataDir, locales: ctx.ascLocales)
            let problems = Metadata.validate(metadata, requireReleaseNotes: false)
            if problems.isEmpty { add(.pass, "App Store copy is valid for \(metadata.count) locales") }
            for p in problems { add(.fail, p) }
        } catch { add(.fail, "App Store copy: \(error)") }

        if config.screenshots != nil {
            do {
                let problems = try ScreenshotValidator.validate(config: config, root: ctx.root)
                if problems.isEmpty { add(.pass, "Rendered screenshots are all present and the right size") }
                else { add(.warn, "\(problems.count) screenshot problem(s), e.g. \(problems[0]). countdown regenerates them.") }
            } catch { add(.warn, "Screenshots: \(error)") }
        }

        if let site = config.website {
            if let files = try? WebsiteSync.sourceFiles(root: ctx.root, source: site.source), !files.isEmpty {
                add(.pass, "Website source \(site.source)/ has \(files.count) file(s)")
            } else { add(.fail, "Website source \(site.source)/ is empty or missing") }
            if (try? ctx.shell.read(["gh", "repo", "view", site.repo, "--json", "name"]).status) == 0 { add(.pass, "Can reach \(site.repo)") }
            else { add(.fail, "Can't reach \(site.repo) with gh") }
        }

        if ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]?.isEmpty == false { add(.pass, "ANTHROPIC_API_KEY set: release notes will be translated") }
        else { add(.warn, "ANTHROPIC_API_KEY not set: other locales get TODO stubs to translate by hand") }

        if checkASC {
            do {
                let creds = try ASCCredentials.load()
                add(.pass, "App Store Connect key \(creds.keyID) loaded")
                let client = ASCClient(credentials: creds, transport: transport, console: ctx.console, dryRun: true)
                let asc = AppStoreConnect(client: client, console: ctx.console)
                let id = try await asc.appID(bundleID: config.appStore.bundleId, configured: config.appStore.appId)
                add(.pass, "App Store Connect app \(id) found for \(config.appStore.bundleId)")
            } catch { add(.fail, "\(error)") }
        }

        let fails = checks.filter { $0.level == .fail }.count, warns = checks.filter { $0.level == .warn }.count
        ctx.console.stage(fails == 0 ? "Ready (\(warns) warning\(warns == 1 ? "" : "s"))" : "\(fails) problem\(fails == 1 ? "" : "s") to fix")
        return checks
    }

    /// The Settings app, which every iOS simulator has.
    static let settingsApp = "com.apple.Preferences"
    /// How long Settings gets to draw before the test capture.
    static let captureSettleSeconds = 3.0

    /// Boots the first iOS screenshot device, opens Settings and takes one capture. From a
    /// sandboxed shell `simctl io screenshot` returns a blank frame for every app with no
    /// error, which would otherwise look like an app that hadn't drawn yet. Returns nil when
    /// there's nothing to check: no screenshots, no iOS device, a missing simulator or a dry run.
    func captureCheck(listJSON: String) -> Check? {
        guard let device = ctx.config.screenshots?.devices.first(where: { $0.simulator.platform == "iOS" }),
              let sim = (try? Simulators.find(device.simulator, in: Data(listJSON.utf8))) ?? nil else { return nil }
        if ctx.dryRun {
            ctx.console.dry("boot \(sim.name), open Settings and check a test capture isn't blank")
            return nil
        }
        let shell = ctx.shell
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("launchseq-doctor-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: file) }
        do {
            ctx.console.info("Taking a test capture of Settings on \(sim.name)…")
            let result = try ctx.console.whileWorking("taking a test capture on \(sim.name)") { () throws -> CommandResult in
                try shell.change(["xcrun", "simctl", "boot", sim.udid], allowFailure: true)
                try shell.change(["xcrun", "simctl", "bootstatus", sim.udid, "-b"])
                try shell.change(["xcrun", "simctl", "launch", sim.udid, Self.settingsApp])
                sleep(Self.captureSettleSeconds)
                return try shell.change(["xcrun", "simctl", "io", sim.udid, "screenshot", file.path], allowFailure: true)
            }
            try? shell.change(["xcrun", "simctl", "terminate", sim.udid, Self.settingsApp], allowFailure: true)
            guard result.status == 0, let data = FileManager.default.contents(atPath: file.path) else {
                let why = (result.stderr.isEmpty ? result.stdout : result.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
                return Check(level: .fail, message: "Couldn't take a screenshot on \(sim.name)\(why.isEmpty ? "" : ": \(why)")")
            }
            if BlankCapture.isBlank(data) {
                return Check(level: .fail, message: "Screen capture isn't working from this shell: a test capture of Settings on \(sim.name) came out blank. Run launchseq from a normal terminal, not a sandboxed one.")
            }
            return Check(level: .pass, message: "Screen capture works (test capture of Settings on \(sim.name))")
        } catch {
            return Check(level: .fail, message: "Couldn't take a test capture on \(sim.name): \((error as? LaunchError)?.description ?? error.localizedDescription)")
        }
    }
}
