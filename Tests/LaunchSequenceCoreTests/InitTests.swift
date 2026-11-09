import Foundation
import Testing
@testable import LaunchSequenceCore

/// Answers `simctl list` with canned JSON; every other command fails, like a missing tool.
struct FakeRunner: CommandRunning {
    var simulators: String
    func run(_ arguments: [String], cwd: URL?, environment: [String: String], mode: OutputMode) throws -> CommandResult {
        if arguments.starts(with: ["xcrun", "simctl", "list"]) { return CommandResult(status: 0, stdout: simulators, stderr: "") }
        return CommandResult(status: 1, stdout: "", stderr: "not available in tests")
    }
}

@Suite("Init")
struct InitTests {
    let simulators = """
    {"devices": {
      "com.apple.CoreSimulator.SimRuntime.iOS-26-4": [{"name": "iPhone 17 Pro", "udid": "A", "isAvailable": true}],
      "com.apple.CoreSimulator.SimRuntime.iOS-27-0": [
        {"name": "iPhone 9 Pro", "udid": "B", "isAvailable": true},
        {"name": "iPhone 17 Pro", "udid": "C", "isAvailable": true},
        {"name": "iPhone 17 Pro Max", "udid": "D", "isAvailable": true}],
      "com.apple.CoreSimulator.SimRuntime.iOS-27-1": [{"name": "iPhone Duo", "udid": "E", "isAvailable": true}],
      "com.apple.CoreSimulator.SimRuntime.watchOS-27-0": [{"name": "Apple Watch Ultra 4 (49mm)", "udid": "F", "isAvailable": true}]
    }}
    """

    let projectYML = """
    name: PrimeTime
    targets:
      PrimeTime:
        info:
          properties:
            CFBundleDisplayName: Prime Time
        settings:
          base:
            PRODUCT_BUNDLE_IDENTIFIER: uk.co.ceri-anne.primetime
            MARKETING_VERSION: "1.2"
      PrimeTimeTests:
        settings:
          base:
            PRODUCT_BUNDLE_IDENTIFIER: uk.co.ceri-anne.primetimeTests
      PrimeTimeWatch:
        settings:
          base:
            PRODUCT_BUNDLE_IDENTIFIER: uk.co.ceri-anne.primetime.watchkitapp
            MARKETING_VERSION: "1.2"
    """

    @Test func picksAProOnTheNewestRuntimeThatHasOne() {
        // 27.1 only has a foldable, so 27.0's newest Pro wins; iPhone 17 beats iPhone 9 numerically.
        #expect(InitDraft.newestIPhone(in: Data(simulators.utf8)) == Simulator(name: "iPhone 17 Pro", os: "27.0"))
    }

    @Test func fallsBackToAnyIPhone() {
        let json = #"{"devices": {"com.apple.CoreSimulator.SimRuntime.iOS-27-1": [{"name": "iPhone Duo", "isAvailable": true}]}}"#
        #expect(InitDraft.newestIPhone(in: Data(json.utf8)) == Simulator(name: "iPhone Duo", os: "27.1"))
        #expect(InitDraft.newestIPhone(in: Data(#"{"devices": {}}"#.utf8)) == nil)
    }

    @Test func readsAnXcodeGenRepo() throws {
        let facts = try InitDraft.facts(files: ["project.yml", "Sources"], read: { $0 == "project.yml" ? projectYML : nil },
                                        schemes: nil, simulators: Data(simulators.utf8), remoteURL: "git@github.com:Ceri-anne/PrimeTime.git")
        #expect(facts.appName == "Prime Time")
        #expect(facts.project == "PrimeTime.xcodeproj")
        #expect(facts.generate == ["xcodegen", "generate"])
        #expect(facts.versionFile == "project.yml")
        #expect(facts.bundleId == "uk.co.ceri-anne.primetime")
        #expect(facts.scheme == "PrimeTime")
        #expect(facts.githubOwner == "Ceri-anne")
        #expect(facts.notes.count == 1)   // the scheme was guessed
    }

    @Test func readsAPlainXcodeProject() throws {
        let pbxproj = """
        INFOPLIST_KEY_CFBundleDisplayName = "Tide Times";
        MARKETING_VERSION = 2.1;
        PRODUCT_BUNDLE_IDENTIFIER = com.example.tides;
        PRODUCT_BUNDLE_IDENTIFIER = com.example.tidesUITests;
        """
        let facts = try InitDraft.facts(files: ["TideTimes.xcodeproj"], read: { $0 == "TideTimes.xcodeproj/project.pbxproj" ? pbxproj : nil },
                                        schemes: ["TideTimesUITests", "TideTimes"], simulators: Data(simulators.utf8),
                                        remoteURL: "https://github.com/someone/tides.git")
        #expect(facts.appName == "Tide Times")
        #expect(facts.generate == nil)
        #expect(facts.versionFile == "TideTimes.xcodeproj/project.pbxproj")
        #expect(facts.bundleId == "com.example.tides")
        #expect(facts.scheme == "TideTimes")
        #expect(facts.githubOwner == "someone")
        #expect(facts.notes.isEmpty)
    }

    @Test func fallsBackToTheProjectNameAndFlagsGaps() throws {
        let facts = try InitDraft.facts(files: ["MyGreatApp.xcodeproj"], read: { _ in "" }, schemes: [],
                                        simulators: Data(simulators.utf8), remoteURL: nil)
        #expect(facts.appName == "My Great App")
        #expect(facts.bundleId == nil)
        #expect(facts.githubOwner == nil)
        #expect(facts.notes.count == 3)   // version, bundle ID, scheme
    }

    @Test func needsAProject() {
        #expect(throws: LaunchError.self) {
            try InitDraft.facts(files: ["README.md"], read: { _ in nil }, schemes: nil, simulators: Data(simulators.utf8), remoteURL: nil)
        }
    }

    @Test func draftLoadsAsAConfig() throws {
        var facts = try InitDraft.facts(files: ["project.yml"], read: { _ in projectYML }, schemes: nil,
                                        simulators: Data(simulators.utf8), remoteURL: nil)
        facts.appName = #"Quote "Me" \ Please"#
        facts.bundleId = nil
        let config = try Config.parse(InitDraft.render(facts))
        #expect(config.app.name == facts.appName)
        #expect(config.app.generate == ["xcodegen", "generate"])
        #expect(config.appStore.bundleId == "TODO")
        #expect(config.test.simulator == Simulator(name: "iPhone 17 Pro", os: "27.0"))
        #expect(config.screenshots == nil && config.website == nil)
    }

    func runInit(in root: URL, force: Bool, dryRun: Bool) throws -> String {
        let console = Console(answers: [], sink: { _ in })
        let shell = Shell(runner: FakeRunner(simulators: simulators), console: console, dryRun: dryRun, root: root)
        return try Init(root: root, shell: shell, console: console).run(force: force)
    }

    @Test func writesOnlyWhenAsked() throws {
        let root = try tempDir()
        try projectYML.write(to: root.appendingPathComponent("project.yml"), atomically: true, encoding: .utf8)
        let target = root.appendingPathComponent(".launchseq.yml")

        _ = try runInit(in: root, force: false, dryRun: true)
        #expect(!FileManager.default.fileExists(atPath: target.path))

        let yaml = try runInit(in: root, force: false, dryRun: false)
        #expect(try String(contentsOf: target, encoding: .utf8) == yaml)

        #expect(throws: LaunchError.self) { try runInit(in: root, force: false, dryRun: false) }
        _ = try runInit(in: root, force: true, dryRun: false)
    }
}
