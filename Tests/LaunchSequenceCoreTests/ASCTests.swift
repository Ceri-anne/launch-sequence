import CryptoKit
import Foundation
import Testing
@testable import LaunchSequenceCore

final class RecordingTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    let handler: @Sendable (URLRequest) throws -> (Data, Int)
    init(_ handler: @escaping @Sendable (URLRequest) throws -> (Data, Int)) { self.handler = handler }
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return _requests }
    private func record(_ r: URLRequest) { lock.lock(); _requests.append(r); lock.unlock() }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        record(request)
        let (data, status) = try handler(request)
        return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

/// A tiny in-memory App Store Connect for screenshot sets.
final class FakeASC: @unchecked Sendable {
    let lock = NSLock()
    var screenshots: [String: JSONValue] = [:]   // id -> resource
    var setOrder: [String] = []
    var setExists = false
    var nextID = 0
    /// How many status checks each screenshot answers "still processing" to after upload.
    var processingPolls = 0
    var pollsLeft: [String: Int] = [:]

    func handle(_ r: URLRequest) throws -> (Data, Int) {
        lock.lock(); defer { lock.unlock() }
        let path = r.url!.path
        let method = r.httpMethod ?? "GET"
        func doc(_ v: JSONValue) throws -> (Data, Int) { (try v.data(), 200) }
        if r.url!.host != HostPolicy.ascHost { return (Data(), 200) }  // upload chunk
        switch (method, path) {
        case ("GET", "/v1/appStoreVersionLocalizations/loc1/appScreenshotSets"):
            return try doc(["data": setExists ? [["id": "set1", "attributes": ["screenshotDisplayType": "APP_IPHONE_61"]]] : []])
        case ("POST", "/v1/appScreenshotSets"):
            setExists = true
            return try doc(["data": ["id": "set1"]])
        case ("GET", "/v1/appScreenshotSets/set1/appScreenshots"):
            return try doc(["data": .array(setOrder.compactMap { screenshots[$0] })])
        case ("POST", "/v1/appScreenshots"):
            nextID += 1
            let id = "shot\(nextID)"
            let body = try JSONValue.parse(r.httpBody!)
            screenshots[id] = ["id": .string(id), "attributes": ["fileName": body["data"]["attributes"]["fileName"], "assetDeliveryState": ["state": "UPLOAD_COMPLETE"]]]
            setOrder.append(id)  // a reserved screenshot joins its set straight away
            let size = body["data"]["attributes"]["fileSize"].int!
            return try doc(["data": ["id": .string(id), "attributes": ["uploadOperations": [["method": "PUT", "url": .string("https://store-1.blobstore.apple.com/\(id)"), "offset": 0, "length": .number(Double(size)), "requestHeaders": [["name": "Content-Type", "value": "image/png"]]]]]]])
        case ("PATCH", let p) where p.hasPrefix("/v1/appScreenshots/"):
            let id = String(p.dropFirst("/v1/appScreenshots/".count))
            let body = try JSONValue.parse(r.httpBody!)
            screenshots[id] = ["id": .string(id), "attributes": ["fileName": screenshots[id]!["attributes"]["fileName"], "sourceFileChecksum": body["data"]["attributes"]["sourceFileChecksum"], "assetDeliveryState": ["state": "COMPLETE"]]]
            pollsLeft[id] = processingPolls
            return try doc(["data": screenshots[id]!])
        case ("GET", let p) where p.hasPrefix("/v1/appScreenshots/"):
            let id = String(p.dropFirst("/v1/appScreenshots/".count))
            if let left = pollsLeft[id], left > 0 {
                pollsLeft[id] = left - 1
                return try doc(["data": ["id": .string(id), "attributes": ["fileName": screenshots[id]!["attributes"]["fileName"], "assetDeliveryState": ["state": "UPLOAD_COMPLETE"]]]])
            }
            return try doc(["data": screenshots[id]!])
        case ("DELETE", let p) where p.hasPrefix("/v1/appScreenshots/"):
            let id = String(p.dropFirst("/v1/appScreenshots/".count))
            screenshots[id] = nil
            setOrder.removeAll { $0 == id }
            return (Data(), 204)
        case ("PATCH", "/v1/appScreenshotSets/set1/relationships/appScreenshots"):
            setOrder = try JSONValue.parse(r.httpBody!)["data"].array.compactMap { $0["id"].string }
            return (Data(), 204)
        default:
            return (try (["errors": [["title": "Not found", "detail": .string("\(method) \(path)")]]] as JSONValue).data(), 404)
        }
    }
}

func testCredentials() -> ASCCredentials { ASCCredentials(keyID: "ABC123DEF4", issuerID: "i", privateKey: P256.Signing.PrivateKey()) }
let quietConsole = Console(answers: [], sink: { _ in })

final class LineSink: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func append(_ line: String) { lock.lock(); lines.append(line); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return lines }
}

@Suite("App Store Connect")
struct ASCTests {
    @Test func screenshotSyncIsIdempotent() async throws {
        let fake = FakeASC()
        let transport = RecordingTransport { try fake.handle($0) }
        let client = ASCClient(credentials: testCredentials(), transport: transport, console: quietConsole, dryRun: false, sleep: { _ in })
        let asc = AppStoreConnect(client: client, console: quietConsole)
        let files = [AppStoreConnect.LocalScreenshot(fileName: "01.png", data: Data("one".utf8)),
                     AppStoreConnect.LocalScreenshot(fileName: "02.png", data: Data("two".utf8))]

        #expect(try await asc.syncScreenshots(localizationID: "loc1", displayType: "APP_IPHONE_61", files: files) == .replaced(2))
        #expect(fake.setOrder.count == 2)

        let before = transport.requests.count
        #expect(try await asc.syncScreenshots(localizationID: "loc1", displayType: "APP_IPHONE_61", files: files) == .unchanged)
        #expect(transport.requests[before...].allSatisfy { $0.httpMethod == "GET" })

        let changed = [files[0], AppStoreConnect.LocalScreenshot(fileName: "02.png", data: Data("TWO".utf8))]
        #expect(try await asc.syncScreenshots(localizationID: "loc1", displayType: "APP_IPHONE_61", files: changed) == .replaced(1))  // the first is kept
        #expect(fake.screenshots.count == 2)
    }

    @Test func slowProcessingReportsProgressAndFinishes() async throws {
        let fake = FakeASC()
        fake.processingPolls = 30   // 30 checks x 5s = 2m 30s at Apple
        let lines = LineSink()
        let console = Console(answers: [], sink: { lines.append($0) })
        let client = ASCClient(credentials: testCredentials(), transport: RecordingTransport { try fake.handle($0) }, console: console, dryRun: false, sleep: { _ in })
        let files = (1...4).map { AppStoreConnect.LocalScreenshot(fileName: "0\($0).png", data: Data("\($0)".utf8)) }

        let result = try await AppStoreConnect(client: client, console: console)
            .syncScreenshots(localizationID: "loc1", displayType: "APP_IPHONE_61", files: files, label: "en-GB APP_IPHONE_61")

        #expect(result == .replaced(4))
        #expect(lines.all.contains { $0.contains("en-GB APP_IPHONE_61: uploading 4 screenshots one at a time") })
        #expect(lines.all.contains { $0.contains("en-GB APP_IPHONE_61: 3/4 03.png") })
        #expect(lines.all.contains { $0.contains("… en-GB APP_IPHONE_61 03.png: 0/1 processed by Apple (0s)") })
        #expect(lines.all.contains { $0.contains("(30s)") })
        #expect(lines.all.contains { $0.contains("en-GB APP_IPHONE_61 04.png: processed (2m 30s)") })
    }

    @Test func eachScreenshotIsProcessedBeforeTheNextIsUploaded() async throws {
        let fake = FakeASC()
        fake.processingPolls = 2
        let transport = RecordingTransport { try fake.handle($0) }
        let client = ASCClient(credentials: testCredentials(), transport: transport, console: quietConsole, dryRun: false, sleep: { _ in })
        let files = (1...3).map { AppStoreConnect.LocalScreenshot(fileName: "0\($0).png", data: Data("\($0)".utf8)) }
        _ = try await AppStoreConnect(client: client, console: quietConsole).syncScreenshots(localizationID: "loc1", displayType: "APP_IPHONE_61", files: files)

        // Reserve 1, poll 1 until done, reserve 2, poll 2, … never reserving while one is processing.
        let steps = transport.requests.filter { $0.url!.host == HostPolicy.ascHost }.compactMap { r -> String? in
            let path = r.url!.path
            if r.httpMethod == "POST" && path == "/v1/appScreenshots" { return "reserve" }
            if r.httpMethod == "GET" && path.hasPrefix("/v1/appScreenshots/") { return "poll " + path.dropFirst("/v1/appScreenshots/".count) }
            return nil
        }
        #expect(steps == ["reserve", "poll shot1", "poll shot1", "poll shot1",
                          "reserve", "poll shot2", "poll shot2", "poll shot2",
                          "reserve", "poll shot3", "poll shot3", "poll shot3"])
        #expect(fake.setOrder == ["shot1", "shot2", "shot3"])
    }

    @Test func aRerunKeepsTheScreenshotsThatAreAlreadyRight() async throws {
        let fake = FakeASC()
        let transport = RecordingTransport { try fake.handle($0) }
        let lines = LineSink()
        let console = Console(answers: [], sink: { lines.append($0) })
        let client = ASCClient(credentials: testCredentials(), transport: transport, console: console, dryRun: false, sleep: { _ in })
        let asc = AppStoreConnect(client: client, console: console)
        var files = (1...4).map { AppStoreConnect.LocalScreenshot(fileName: "0\($0).png", data: Data("\($0)".utf8)) }
        _ = try await asc.syncScreenshots(localizationID: "loc1", displayType: "APP_IPHONE_61", files: files)

        files[2] = .init(fileName: "03.png", data: Data("three, reframed".utf8))
        let before = transport.requests.count
        #expect(try await asc.syncScreenshots(localizationID: "loc1", displayType: "APP_IPHONE_61", files: files, label: "en-GB APP_IPHONE_61") == .replaced(2))
        let rerun = transport.requests[before...]
        #expect(rerun.filter { $0.httpMethod == "POST" && $0.url!.path == "/v1/appScreenshots" }.count == 2)
        #expect(rerun.filter { $0.httpMethod == "DELETE" }.map { $0.url!.path } == ["/v1/appScreenshots/shot3", "/v1/appScreenshots/shot4"])
        #expect(fake.setOrder == ["shot1", "shot2", "shot5", "shot6"])
        #expect(lines.all.contains { $0.contains("en-GB APP_IPHONE_61: uploading 2 screenshots one at a time (the first 2 are already there)") })
    }

    @Test func processingTimeoutSaysWhatIsLeftAndHowToResume() async throws {
        let fake = FakeASC()
        fake.processingPolls = 1_000
        let client = ASCClient(credentials: testCredentials(), transport: RecordingTransport { try fake.handle($0) }, console: quietConsole, dryRun: false, sleep: { _ in })
        await #expect {
            try await AppStoreConnect(client: client, console: quietConsole)
                .syncScreenshots(localizationID: "loc1", displayType: "APP_IPHONE_61", files: [.init(fileName: "a.png", data: Data("x".utf8))], label: "fr-FR APP_IPHONE_61")
        } throws: { error in
            "\(error)".contains("fr-FR APP_IPHONE_61 a.png: 1 of 1 screenshot still processing after 30 minutes")
        }
    }

    @Test func jwtGoesOnlyToTheAPIAndNeverToUploads() async throws {
        let fake = FakeASC()
        let transport = RecordingTransport { try fake.handle($0) }
        let client = ASCClient(credentials: testCredentials(), transport: transport, console: quietConsole, dryRun: false, sleep: { _ in })
        _ = try await AppStoreConnect(client: client, console: quietConsole)
            .syncScreenshots(localizationID: "loc1", displayType: "APP_IPHONE_61", files: [.init(fileName: "a.png", data: Data("x".utf8))])
        for r in transport.requests {
            if r.url!.host == HostPolicy.ascHost { #expect(r.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer ") == true) }
            else { #expect(r.value(forHTTPHeaderField: "Authorization") == nil) }
        }
        #expect(transport.requests.contains { $0.url!.host == "store-1.blobstore.apple.com" })
    }

    @Test func refusesUploadsToNonAppleHosts() async throws {
        let client = ASCClient(credentials: testCredentials(), transport: RecordingTransport { _ in (Data(), 200) }, console: quietConsole, dryRun: false)
        let op = ASCClient.UploadOperation(method: "PUT", url: URL(string: "https://evil.example.com/x")!, offset: 0, length: 1, headers: [])
        await #expect(throws: LaunchError.self) { try await client.upload(op, file: Data("x".utf8)) }
    }

    @Test func dryRunReadsButNeverWrites() async throws {
        let transport = RecordingTransport { r in
            if r.url!.path == "/v1/apps/1/appStoreVersions" { return (try (["data": []] as JSONValue).data(), 200) }
            return (try (["data": []] as JSONValue).data(), 200)
        }
        let client = ASCClient(credentials: testCredentials(), transport: transport, console: quietConsole, dryRun: true)
        let asc = AppStoreConnect(client: client, console: quietConsole)
        let v = try await asc.prepareVersion(appID: "1", version: "1.2.0", platform: "IOS", releaseType: "MANUAL")
        #expect(v.id.hasPrefix("dryrun-"))
        try await asc.setPhasedRelease(versionID: v.id, enabled: true)
        _ = try await asc.syncScreenshots(localizationID: "dryrun-loc", displayType: "APP_IPHONE_61", files: [.init(fileName: "a.png", data: Data("x".utf8))])
        #expect(transport.requests.allSatisfy { $0.httpMethod == "GET" })
    }

    @Test func refusesToEditALiveVersion() async throws {
        let transport = RecordingTransport { _ in
            (try (["data": [["id": "v1", "attributes": ["versionString": "1.2.0", "appVersionState": "READY_FOR_DISTRIBUTION"]]]] as JSONValue).data(), 200)
        }
        let asc = AppStoreConnect(client: ASCClient(credentials: testCredentials(), transport: transport, console: quietConsole, dryRun: false), console: quietConsole)
        await #expect(throws: LaunchError.self) { try await asc.prepareVersion(appID: "1", version: "1.2.0", platform: "IOS", releaseType: "MANUAL") }
    }

    @Test func versionCopyOnlyPatchesWhatChanged() async throws {
        let transport = RecordingTransport { r in
            if r.httpMethod == "GET" {
                return (try (["data": [["id": "loc", "attributes": ["locale": "en-GB", "description": "Same", "keywords": "old", "supportUrl": "https://e.com"]]]] as JSONValue).data(), 200)
            }
            return (try (["data": ["id": "loc"]] as JSONValue).data(), 200)
        }
        let asc = AppStoreConnect(client: ASCClient(credentials: testCredentials(), transport: transport, console: quietConsole, dryRun: false), console: quietConsole)
        let m = LocaleMetadata(locale: "en-GB", fields: [.description: "Same", .keywords: "new", .supportURL: "https://e.com", .releaseNotes: "- x"])
        let ids = try await asc.syncVersionLocalizations(versionID: "v", metadata: [m], isFirstVersion: false)
        #expect(ids == ["en-GB": "loc"])
        let patch = try #require(transport.requests.first { $0.httpMethod == "PATCH" })
        let attrs = try JSONValue.parse(patch.httpBody!)["data"]["attributes"]
        #expect(attrs == ["keywords": "new", "whatsNew": "- x"])
    }

    @Test func retriesRateLimits() async throws {
        let counter = Counter()
        let transport = RecordingTransport { _ in
            counter.increment() < 2 ? (Data(), 429) : (try (["data": []] as JSONValue).data(), 200)
        }
        let client = ASCClient(credentials: testCredentials(), transport: transport, console: quietConsole, dryRun: false, sleep: { _ in })
        _ = try await client.get("/v1/apps")
        #expect(transport.requests.count == 3)
    }

    @Test func retriesTimeoutsOnGets() async throws {
        let counter = Counter()
        let transport = RecordingTransport { _ in
            if counter.increment() < 2 { throw URLError(.timedOut) }
            return (try (["data": []] as JSONValue).data(), 200)
        }
        let client = ASCClient(credentials: testCredentials(), transport: transport, console: quietConsole, dryRun: false, sleep: { _ in })
        _ = try await client.getAll("/v1/appStoreVersions/v1/appStoreVersionLocalizations")
        #expect(transport.requests.count == 3)
    }

    @Test func givesUpOnTimeoutsWithAShortMessage() async throws {
        let transport = RecordingTransport { _ in throw URLError(.timedOut) }
        let client = ASCClient(credentials: testCredentials(), transport: transport, console: quietConsole, dryRun: false, sleep: { _ in })
        do {
            _ = try await client.get("/v1/apps")
            Issue.record("expected a failure")
        } catch let error as LaunchError {
            #expect(transport.requests.count == 4)
            #expect(error.description == "App Store Connect: GET /v1/apps failed after 4 tries: The request timed out")
        }
    }

    @Test func doesNotRepeatPostsAfterATimeout() async throws {
        let transport = RecordingTransport { _ in throw URLError(.timedOut) }
        let client = ASCClient(credentials: testCredentials(), transport: transport, console: quietConsole, dryRun: false, sleep: { _ in })
        do {
            try await client.post("/v1/appStoreVersions", ["data": ["type": "appStoreVersions"]])
            Issue.record("expected a failure")
        } catch let error as LaunchError {
            #expect(transport.requests.count == 1)
            #expect(error.description.contains("may have gone through"))
        }
    }

    @Test func doesNotRetryOtherErrors() async throws {
        let transport = RecordingTransport { _ in throw URLError(.serverCertificateUntrusted) }
        let client = ASCClient(credentials: testCredentials(), transport: transport, console: quietConsole, dryRun: false, sleep: { _ in })
        await #expect(throws: URLError.self) { try await client.get("/v1/apps") }
        #expect(transport.requests.count == 1)
    }

    @Test func retriesUploadChunksAfterAConnectionDrop() async throws {
        let counter = Counter()
        let transport = RecordingTransport { _ in
            if counter.increment() < 1 { throw URLError(.networkConnectionLost) }
            return (Data(), 200)
        }
        let client = ASCClient(credentials: testCredentials(), transport: transport, console: quietConsole, dryRun: false, sleep: { _ in })
        let op = ASCClient.UploadOperation(method: "PUT", url: URL(string: "https://upload.example.apple.com/chunk")!, offset: 0, length: 3, headers: [])
        try await client.upload(op, file: Data([1, 2, 3]))
        #expect(transport.requests.count == 2)
    }

    @Test func doesNotFollowNextLinksOffHost() async throws {
        let transport = RecordingTransport { _ in
            (try (["data": [], "links": ["next": "https://evil.example.com/v1/apps?cursor=x"]] as JSONValue).data(), 200)
        }
        let client = ASCClient(credentials: testCredentials(), transport: transport, console: quietConsole, dryRun: false)
        await #expect(throws: LaunchError.self) { try await client.getAll("/v1/apps") }
    }
}

final class Counter: @unchecked Sendable {
    private var n = 0
    private let lock = NSLock()
    func increment() -> Int { lock.lock(); defer { lock.unlock() }; let v = n; n += 1; return v }
}
