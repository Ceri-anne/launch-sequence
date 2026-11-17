import Foundation
import Testing
@testable import LaunchSequenceCore

/// Every `simctl io screenshot` fails, as it does when no display is available.
struct FailingScreenshots: CommandRunning {
    func run(_ arguments: [String], cwd: URL?, environment: [String: String], mode: OutputMode) throws -> CommandResult {
        if arguments.contains("screenshot") { return CommandResult(status: 1, stdout: "", stderr: "Error creating the image\n") }
        return CommandResult(status: 0, stdout: "", stderr: "")
    }
}

@Suite("Doctor capture check")
struct DoctorCaptureTests {
    let listJSON = #"{"devices": {"com.apple.CoreSimulator.SimRuntime.iOS-27-2": [{"name": "iPhone 17 Pro", "udid": "U1", "isAvailable": true}]}}"#

    func doctor(_ runner: CommandRunning, dryRun: Bool = false, yml: String? = nil) throws -> Doctor {
        let config = try Config.parse(try yml ?? fixture("launchseq.yml"))
        let ctx = Context(config: config, root: try tempDir(), console: quietConsole, runner: runner, dryRun: dryRun)
        return Doctor(ctx: ctx, sleep: { _ in })
    }

    @Test func blankCaptureMeansCaptureIsBroken() throws {
        let check = try #require(try doctor(FakeSimctl([blankScreen])).captureCheck(listJSON: listJSON))
        #expect(check.level == .fail)
        #expect(check.message.contains("Screen capture isn't working from this shell"))
        #expect(check.message.contains("normal terminal"))
    }

    @Test func realCapturePasses() throws {
        let simctl = FakeSimctl([realScreen])
        let check = try #require(try doctor(simctl).captureCheck(listJSON: listJSON))
        #expect(check.level == .pass)
        #expect(simctl.commands.contains(["xcrun", "simctl", "boot", "U1"]))
        #expect(simctl.commands.contains(["xcrun", "simctl", "launch", "U1", "com.apple.Preferences"]))
        #expect(simctl.screenshots == 1)
    }

    @Test func failedScreenshotIsReported() throws {
        let check = try #require(try doctor(FailingScreenshots()).captureCheck(listJSON: listJSON))
        #expect(check.level == .fail)
        #expect(check.message.contains("Error creating the image"))
    }

    @Test func nothingToCheckInADryRunOrWithoutScreenshots() throws {
        let simctl = FakeSimctl([realScreen])
        #expect(try doctor(simctl, dryRun: true).captureCheck(listJSON: listJSON) == nil)
        #expect(simctl.screenshots == 0)
        let noShots = try fixture("launchseq.yml").replacingOccurrences(of: #"(?s)screenshots:.*?(?=app_store:)"#, with: "", options: .regularExpression)
        #expect(try doctor(simctl, yml: noShots).captureCheck(listJSON: listJSON) == nil)
        #expect(try doctor(simctl).captureCheck(listJSON: #"{"devices": {}}"#) == nil)
    }
}
