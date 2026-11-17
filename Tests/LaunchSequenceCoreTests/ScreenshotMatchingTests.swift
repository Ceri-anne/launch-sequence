import Foundation
import Testing
@testable import LaunchSequenceCore

/// Liftoff compares screenshots one at a time, so a rerun or a small change only touches
/// the screenshots that differ.
@Suite("Per-image screenshot matching")
struct ScreenshotMatchingTests {
    let fake = FakeASC()
    let transport: RecordingTransport
    let lines = LineSink()
    let asc: AppStoreConnect

    init() {
        let fake = self.fake
        transport = RecordingTransport { try fake.handle($0) }
        let lines = self.lines
        let console = Console(answers: [], sink: { lines.append($0) })
        asc = AppStoreConnect(client: ASCClient(credentials: testCredentials(), transport: transport, console: console, dryRun: false, sleep: { _ in }), console: console)
    }

    func shots(_ n: Int) -> [AppStoreConnect.LocalScreenshot] {
        (1...n).map { .init(fileName: "0\($0).png", data: Data("\($0)".utf8)) }
    }

    /// Syncs `files`, returning the result and the requests that made changes.
    func sync(_ files: [AppStoreConnect.LocalScreenshot]) async throws -> (AppStoreConnect.ScreenshotResult, [URLRequest]) {
        let before = transport.requests.count
        let result = try await asc.syncScreenshots(localizationID: "loc1", displayType: "APP_IPHONE_61", files: files, label: "en-GB APP_IPHONE_61")
        return (result, transport.requests[before...].filter { $0.httpMethod != "GET" && $0.url!.host == HostPolicy.ascHost })
    }

    func reserved(_ requests: [URLRequest]) -> [String] {
        requests.filter { $0.httpMethod == "POST" && $0.url!.path == "/v1/appScreenshots" }
            .compactMap { try? JSONValue.parse($0.httpBody!)["data"]["attributes"]["fileName"].string }
    }

    func deleted(_ requests: [URLRequest]) -> [String] {
        requests.filter { $0.httpMethod == "DELETE" }.map { String($0.url!.path.dropFirst("/v1/appScreenshots/".count)) }
    }

    @Test func anAppendedScreenshotIsTheOnlyUpload() async throws {
        _ = try await sync(shots(3))
        let (result, changes) = try await sync(shots(4))
        #expect(result == .replaced(1))
        #expect(reserved(changes) == ["04.png"])
        #expect(deleted(changes).isEmpty)
        #expect(fake.setOrder == ["shot1", "shot2", "shot3", "shot4"])
        #expect(lines.all.contains { $0.contains("en-GB APP_IPHONE_61: uploading 1 screenshot one at a time (3 are already there)") })
    }

    @Test func aChangedScreenshotInTheMiddleIsReplacedInPlace() async throws {
        var files = shots(4)
        _ = try await sync(files)
        files[1] = .init(fileName: "02.png", data: Data("two, reframed".utf8))
        let (result, changes) = try await sync(files)
        #expect(result == .replaced(1))
        #expect(reserved(changes) == ["02.png"])
        #expect(deleted(changes) == ["shot2"])
        #expect(fake.setOrder == ["shot1", "shot5", "shot3", "shot4"])
    }

    @Test func aScreenshotRemovedLocallyIsDeleted() async throws {
        let files = shots(4)
        _ = try await sync(files)
        let printed = lines.all.count
        let (result, changes) = try await sync([files[0], files[1], files[3]])
        #expect(result == .replaced(0))
        #expect(reserved(changes).isEmpty)
        #expect(deleted(changes) == ["shot3"])
        #expect(fake.setOrder == ["shot1", "shot2", "shot4"])
        #expect(!lines.all.dropFirst(printed).contains { $0.contains("uploading") })
    }

    @Test func aFailedScreenshotIsUploadedAgain() async throws {
        let files = shots(3)
        _ = try await sync(files)
        fake.lock.withLock {
            fake.screenshots["shot2"] = ["id": "shot2", "attributes": ["fileName": "02.png", "sourceFileChecksum": .string(files[1].md5),
                                                                       "assetDeliveryState": ["state": "FAILED"]]]
        }
        let (result, changes) = try await sync(files)
        #expect(result == .replaced(1))
        #expect(reserved(changes) == ["02.png"])
        #expect(deleted(changes) == ["shot2"])
        #expect(fake.setOrder == ["shot1", "shot4", "shot3"])
    }

    @Test func reorderedLocalFilesAreReorderedWithoutUploading() async throws {
        let files = shots(3)
        _ = try await sync(files)
        let (result, changes) = try await sync([files[2], files[0], files[1]])
        #expect(result == .replaced(0))
        #expect(reserved(changes).isEmpty && deleted(changes).isEmpty)
        #expect(fake.setOrder == ["shot3", "shot1", "shot2"])
    }

    @Test func aMatchingSetIsLeftAlone() async throws {
        _ = try await sync(shots(2))
        let (result, changes) = try await sync(shots(2))
        #expect(result == .unchanged)
        #expect(changes.isEmpty)
    }

    @Test func duplicateFileNamesEachNeedTheirOwnScreenshot() {
        let file = AppStoreConnect.LocalScreenshot(fileName: "01.png", data: Data("1".utf8))
        let remote: [JSONValue] = [["id": "a", "attributes": ["fileName": "01.png", "sourceFileChecksum": .string(file.md5), "assetDeliveryState": ["state": "COMPLETE"]]]]
        let plan = AppStoreConnect.matchScreenshots(remote, with: [file, file])
        #expect(plan.keep == ["a", nil])
        #expect(!plan.isUnchanged)
    }
}

@Suite("Liftoff --skip-screenshots")
struct SkipScreenshotsTests {
    @Test func warningSaysWhatIsKept() {
        #expect(Liftoff.screenshotsSkippedByFlag.contains("--skip-screenshots"))
        #expect(Liftoff.screenshotsSkippedByFlag.contains("keeps whatever screenshots App Store Connect already has"))
    }
}
