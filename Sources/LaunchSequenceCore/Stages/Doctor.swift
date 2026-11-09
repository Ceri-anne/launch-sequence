import Foundation

/// Checks everything a release needs, without changing anything.
public struct Doctor: Sendable {
    let ctx: Context
    let transport: HTTPTransport

    public init(ctx: Context, transport: HTTPTransport = URLSessionTransport()) { self.ctx = ctx; self.transport = transport }

    public enum Level: Sendable { case pass, warn, fail }
    public struct Check: Sendable { public var level: Level; public var message: String }

    public func run(checkASC: Bool = true) async -> [Check] {
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
}
