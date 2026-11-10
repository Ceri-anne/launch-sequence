import Foundation
import Testing
@testable import LaunchSequenceCore

/// An App Store Connect set whose contents change as the person drags files in: each
/// read of the set returns the next scripted state, and the last one repeats.
final class DraggedSet: @unchecked Sendable {
    private let lock = NSLock()
    private var states: [[JSONValue]]
    private(set) var reads = 0
    private(set) var writes = 0
    init(_ states: [[JSONValue]]) { self.states = states }

    func handle(_ r: URLRequest) throws -> (Data, Int) {
        lock.lock(); defer { lock.unlock() }
        func doc(_ v: JSONValue) throws -> (Data, Int) { (try v.data(), 200) }
        guard r.httpMethod ?? "GET" == "GET" else { writes += 1; return (Data(), 204) }
        switch r.url!.path {
        case "/v1/appStoreVersionLocalizations/loc1/appScreenshotSets":
            return try doc(["data": [["id": "set1", "attributes": ["screenshotDisplayType": "APP_IPHONE_61"]]]])
        case "/v1/appScreenshotSets/set1/appScreenshots":
            reads += 1
            return try doc(["data": .array(states.count > 1 ? states.removeFirst() : states[0])])
        default:
            return (try (["errors": [["title": "Not found"]]] as JSONValue).data(), 404)
        }
    }

    /// A screenshot as App Store Connect reports it. A web upload may have no checksum.
    static func shot(_ file: AppStoreConnect.LocalScreenshot, state: String = "COMPLETE", checksum: Bool = true, size: Int? = nil) -> JSONValue {
        var attributes: [String: JSONValue] = [
            "fileName": .string(file.fileName), "fileSize": .number(Double(size ?? file.data.count)), "assetDeliveryState": ["state": .string(state)],
        ]
        if checksum { attributes["sourceFileChecksum"] = .string(file.md5) }
        return ["id": .string(file.fileName), "attributes": .object(attributes)]
    }
}

/// Records commands (here, `open <folder>`) and succeeds.
final class RecordingRunner: CommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var commands: [[String]] = []
    func run(_ arguments: [String], cwd: URL?, environment: [String: String], mode: OutputMode) throws -> CommandResult {
        lock.lock(); commands.append(arguments); lock.unlock()
        return CommandResult(status: 0, stdout: "", stderr: "")
    }
}

@Suite("Manual screenshots")
struct ManualScreenshotTests {
    let one = AppStoreConnect.LocalScreenshot(fileName: "01-decide.png", data: Data("one".utf8))
    let two = AppStoreConnect.LocalScreenshot(fileName: "02-streak.png", data: Data("two".utf8))
    var files: [AppStoreConnect.LocalScreenshot] { [one, two] }
    func shot(_ f: AppStoreConnect.LocalScreenshot, state: String = "COMPLETE", checksum: Bool = true, size: Int? = nil) -> JSONValue {
        DraggedSet.shot(f, state: state, checksum: checksum, size: size)
    }

    // MARK: Comparing a set with the local files

    @Test func matchingSet() {
        #expect(AppStoreConnect.compare([shot(one), shot(two)], with: files) == .matches)
    }

    @Test func webUploadsWithoutAChecksumMatchOnNameAndSize() {
        #expect(AppStoreConnect.compare([shot(one, checksum: false), shot(two, checksum: false)], with: files) == .matches)
        #expect(AppStoreConnect.compare([shot(one, checksum: false), shot(two, checksum: false, size: 99)], with: files)
                == .different(["02-streak.png isn't the same size as the local file"]))
    }

    @Test func wrongOrder() {
        #expect(AppStoreConnect.compare([shot(two), shot(one)], with: files)
                == .different(["01-decide.png should be number 1, but it's number 2", "02-streak.png should be number 2, but it's number 1"]))
    }

    @Test func missingExtraAndWrongImage() {
        #expect(AppStoreConnect.compare([shot(one)], with: files) == .different(["there is 1, and there should be 2", "02-streak.png is missing"]))
        let old = AppStoreConnect.LocalScreenshot(fileName: "03-old.png", data: Data("old".utf8))
        #expect(AppStoreConnect.compare([shot(one), shot(two), shot(old)], with: files)
                == .different(["there are 3, and there should be 2", "03-old.png shouldn't be there"]))
        let edited = AppStoreConnect.LocalScreenshot(fileName: "02-streak.png", data: Data("TWO".utf8))
        #expect(AppStoreConnect.compare([shot(one), shot(edited)], with: files) == .different(["02-streak.png isn't the same image as the local file"]))
    }

    @Test func processingAndFailed() {
        #expect(AppStoreConnect.compare([shot(one), shot(two, state: "UPLOAD_COMPLETE")], with: files) == .processing(1))
        #expect(AppStoreConnect.compare([shot(one), shot(two, state: "FAILED")], with: files) == .different(["02-streak.png failed processing"]))
    }

    // MARK: Liftoff's guided flow

    struct Run {
        let liftoff: Liftoff
        let asc: AppStoreConnect
        let lines: Lines
        let runner: RecordingRunner
        let root: URL
    }

    func run(_ set: DraggedSet, answers: [String], dryRun: Bool = false) throws -> Run {
        let lines = Lines(), runner = RecordingRunner(), root = try tempDir()
        let console = Console(answers: answers, sink: lines.append)
        let ctx = Context(config: try Config.parse(try fixture("launchseq.yml")), root: root, console: console, runner: runner, dryRun: dryRun)
        var options = Liftoff.Options()
        options.manualScreenshots = true
        let transport = RecordingTransport { try set.handle($0) }
        let liftoff = Liftoff(ctx: ctx, options: options, transport: transport, sleep: { _ in }, credentials: { testCredentials() })
        let client = ASCClient(credentials: testCredentials(), transport: transport, console: console, dryRun: dryRun, sleep: { _ in })
        return Run(liftoff: liftoff, asc: AppStoreConnect(client: client, console: console), lines: lines, runner: runner, root: root)
    }

    var slot: ScreenshotValidator.Slot {
        get throws {
            let config = try Config.parse(try fixture("launchseq.yml"))
            return ScreenshotValidator.Slot(displayType: "APP_IPHONE_61", devices: config.screenshots!.devices)
        }
    }

    @Test func aMatchingSetIsLeftAlone() async throws {
        let set = DraggedSet([[shot(one), shot(two)]])
        let r = try run(set, answers: [])
        let result = try await r.liftoff.placeByHand(asc: r.asc, localizationID: "loc1", locale: "en-GB", group: try slot, files: files)
        #expect(result == .unchanged)
        #expect(!r.lines.text.contains("✋"))
        #expect(r.runner.commands.isEmpty)
        #expect(set.writes == 0)
    }

    @Test func guidesThePersonUntilTheSetMatches() async throws {
        // Empty → dragged in the wrong order → reordered, one still processing → done.
        let set = DraggedSet([[], [shot(two), shot(one)], [shot(one), shot(two, state: "UPLOAD_COMPLETE")], [shot(one), shot(two)]])
        let r = try run(set, answers: ["", ""])
        let result = try await r.liftoff.placeByHand(asc: r.asc, localizationID: "loc1", locale: "en-GB", group: try slot, files: files)
        #expect(result == .replaced(2))

        let folder = r.root.appendingPathComponent("build/launchseq/upload/en-GB/APP_IPHONE_61")
        #expect(r.runner.commands == [["open", folder.path]])
        #expect(FileManager.default.contents(atPath: folder.appendingPathComponent("02-streak.png").path) == two.data)
        let text = r.lines.text
        #expect(text.contains("drag in the 2 files from the Finder window that just opened, in this order:\n       1. 01-decide.png\n       2. 02-streak.png"))
        #expect(text.contains("en-GB APP_IPHONE_61 doesn't match the local files yet:"))
        #expect(text.contains("01-decide.png should be number 1, but it's number 2"))
        #expect(text.contains("en-GB APP_IPHONE_61: 1/2 processed by Apple (0s)"))
        #expect(set.writes == 0)  // liftoff never uploads or deletes in manual mode
    }

    @Test func qStops() async throws {
        let r = try run(DraggedSet([[]]), answers: ["q"])
        await #expect(throws: LaunchError.self) {
            try await r.liftoff.placeByHand(asc: r.asc, localizationID: "loc1", locale: "en-GB", group: try slot, files: files)
        }
    }

    @Test func dryRunOnlySaysWhatItWouldAsk() async throws {
        let r = try run(DraggedSet([[]]), answers: [], dryRun: true)
        _ = try await r.liftoff.placeByHand(asc: r.asc, localizationID: "loc1", locale: "en-GB", group: try slot, files: files)
        #expect(r.lines.text.contains("[dry run] would: ask you to drag 2 screenshots into en-GB APP_IPHONE_61 (iPhone)"))
        #expect(!r.lines.text.contains("✋"))
        #expect(!FileManager.default.fileExists(atPath: r.root.appendingPathComponent("build/launchseq/upload").path))
    }

    @Test func aSharedSlotIsRenamedSoFinderListsItInOrder() throws {
        let r = try run(DraggedSet([[]]), answers: [])
        let config = try Config.parse(try fixture("launchseq.yml"))
        var folded = config.screenshots!.devices[0]; folded.name = "Fold-outer"
        var unfolded = folded; unfolded.name = "Fold-inner"
        for device in [folded, unfolded] {
            let path = r.root.appendingPathComponent("\(config.screenshots!.outputDir)/en/\(device.name)/01-decide.png")
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(device.name.utf8).write(to: path)
        }
        let group = ScreenshotValidator.Slot(displayType: "APP_IPHONE_61", devices: [folded, unfolded])
        #expect(try r.liftoff.slotFiles(language: "en", group: group, renameForUpload: true).map(\.fileName)
                == ["1-Fold-outer-01-decide.png", "2-Fold-inner-01-decide.png"])
        #expect(try r.liftoff.slotFiles(language: "en", group: group, renameForUpload: false).map(\.fileName)
                == ["01-decide.png", "01-decide.png"])
    }

    // MARK: Config

    @Test func uploadModeDefaultsToTheAPI() throws {
        let yml = try fixture("launchseq.yml")
        #expect(try Config.parse(yml).screenshots?.upload == .api)
        let manual = yml.replacingOccurrences(of: "  render: [node, scripts/render.js]\n", with: "  render: [node, scripts/render.js]\n  upload: manual\n")
        #expect(try Config.parse(manual).screenshots?.upload == .manual)
        let typo = yml.replacingOccurrences(of: "  render: [node, scripts/render.js]\n", with: "  render: [node, scripts/render.js]\n  upload: by-hand\n")
        #expect(throws: LaunchError.self) { try Config.parse(typo) }
    }
}
