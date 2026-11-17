import Foundation
import Testing
@testable import LaunchSequenceCore

/// Answers `node -e` and `simctl bootstatus` with canned results; everything else succeeds.
struct DoctorRunner: CommandRunning {
    var node = CommandResult(status: 0, stdout: "", stderr: "")
    var bootstatus = CommandResult(status: 0, stdout: "", stderr: "")
    func run(_ arguments: [String], cwd: URL?, environment: [String: String], mode: OutputMode) throws -> CommandResult {
        if arguments.first == "node" { return node }
        if arguments.starts(with: ["xcrun", "simctl", "bootstatus"]) { return bootstatus }
        return CommandResult(status: 0, stdout: "", stderr: "")
    }
}

@Suite("Doctor checks")
struct DoctorChecksTests {
    let listJSON = #"{"devices": {"com.apple.CoreSimulator.SimRuntime.iOS-27-2": [{"name": "iPhone 17 Pro", "udid": "U1", "isAvailable": true}]}}"#

    /// A doctor for the fixture config, with `scripts/render.js` (the fixture's render hook) written when given.
    func doctor(_ runner: CommandRunning, renderScript: String? = nil, yml: String? = nil, dryRun: Bool = false) throws -> Doctor {
        let root = try tempDir()
        if let renderScript {
            try FileManager.default.createDirectory(at: root.appendingPathComponent("scripts"), withIntermediateDirectories: true)
            try renderScript.write(to: root.appendingPathComponent("scripts/render.js"), atomically: true, encoding: .utf8)
        }
        let ctx = Context(config: try Config.parse(try yml ?? fixture("launchseq.yml")), root: root, console: quietConsole, runner: runner, dryRun: dryRun)
        return Doctor(ctx: ctx, sleep: { _ in })
    }

    // MARK: Playwright

    let playwrightScript = "const { chromium } = require('playwright');\n"

    @Test func playwrightInstalledPasses() throws {
        let check = try #require(try doctor(DoctorRunner(), renderScript: playwrightScript).playwrightCheck())
        #expect(check.level == .pass)
    }

    @Test func missingPlaywrightSaysHowToInstallIt() throws {
        let runner = DoctorRunner(node: .init(status: 1, stdout: "", stderr: "Error: Cannot find module 'playwright'\n"))
        let check = try #require(try doctor(runner, renderScript: playwrightScript).playwrightCheck())
        #expect(check.level == .fail)
        #expect(check.message.contains("Playwright isn't installed"))
        #expect(check.message.contains("npm install --no-save playwright && npx playwright install chromium"))
    }

    @Test func missingChromiumIsNamed() throws {
        let runner = DoctorRunner(node: .init(status: 1, stdout: "", stderr: "Error: ENOENT: no such file or directory, access '/ms-playwright/chromium'\n"))
        let check = try #require(try doctor(runner, renderScript: playwrightScript).playwrightCheck())
        #expect(check.message.contains("Playwright's Chromium isn't installed"))
    }

    @Test func renderHookWithoutPlaywrightIsNotChecked() throws {
        #expect(try doctor(DoctorRunner(), renderScript: "console.log('frames')\n").playwrightCheck() == nil)
        #expect(try doctor(DoctorRunner()).playwrightCheck() == nil)
    }

    // MARK: Booting

    @Test func bootableSimulatorPasses() throws {
        let checks = try doctor(DoctorRunner()).bootChecks(listJSON: listJSON)
        #expect(checks.map(\.level) == [.pass])
        #expect(checks[0].message.contains("iPhone 17 Pro (27.2) boots"))
    }

    @Test func simulatorThatWontBootFails() throws {
        let runner = DoctorRunner(bootstatus: .init(status: 164, stdout: "", stderr: "Unable to boot: runtime is unavailable\n"))
        let checks = try doctor(runner).bootChecks(listJSON: listJSON)
        #expect(checks.map(\.level) == [.fail])
        #expect(checks[0].message.contains("didn't boot: Unable to boot: runtime is unavailable"))
    }

    @Test func missingSimulatorsAndDryRunsAreNotBooted() throws {
        #expect(try doctor(DoctorRunner()).bootChecks(listJSON: #"{"devices": {}}"#).isEmpty)
        #expect(try doctor(DoctorRunner(), dryRun: true).bootChecks(listJSON: listJSON).isEmpty)
    }

    // MARK: Xcode Cloud access

    func client(_ handler: @escaping @Sendable (URLRequest) throws -> (Data, Int)) -> ASCClient {
        ASCClient(credentials: testCredentials(), transport: RecordingTransport(handler), console: quietConsole, dryRun: true, sleep: { _ in })
    }

    @Test func readableWorkflowPasses() async throws {
        let cloud = FakeXcodeCloud()
        let check = try await doctor(DoctorRunner()).ciAccessCheck(client: client { try cloud.handle($0) }, appID: "123")
        #expect(check.level == .pass)
        #expect(check.message == "Xcode Cloud workflow Main found")
    }

    @Test func unknownWorkflowWarns() async throws {
        let cloud = FakeXcodeCloud()
        let yml = try fixture("launchseq.yml").replacingOccurrences(of: "  primary_locale: en-GB", with: "  primary_locale: en-GB\n  ci_workflow: Nightly")
        let check = try await doctor(DoctorRunner(), yml: yml).ciAccessCheck(client: client { try cloud.handle($0) }, appID: "123")
        #expect(check.level == .warn)
        #expect(check.message.contains("no workflow called Nightly"))
    }

    @Test func keyWithoutCIAccessWarns() async throws {
        let forbidden = client { _ in (try (["errors": [["status": "403", "title": "Forbidden"]]] as JSONValue).data(), 403) }
        let check = try await doctor(DoctorRunner()).ciAccessCheck(client: forbidden, appID: "123")
        #expect(check.level == .warn)
        #expect(check.message.contains("can't read Xcode Cloud (ciProducts, ciWorkflows)"))
    }
}
