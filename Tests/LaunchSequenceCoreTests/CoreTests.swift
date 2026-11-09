import CryptoKit
import Foundation
import Testing
@testable import LaunchSequenceCore

func fixture(_ name: String) throws -> String {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
    return try String(contentsOf: url, encoding: .utf8)
}

func tempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("launchseq-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite("Versions")
struct VersionTests {
    @Test func parsesOnlyStrictSemver() {
        #expect(SemVer("1.2.3") == SemVer(1, 2, 3))
        #expect(SemVer("1.1") == nil)
        #expect(SemVer("v1.2.3") == nil)
        #expect(SemVer("01.2.3") == nil)
        #expect(SemVer("1.2.3-beta") == nil)
    }

    @Test func latestTagIgnoresTwoPartTags() {
        #expect(SemVer.latest(in: ["1.1", "1.1.0", "1.0.4", "notes"]) == SemVer(1, 1, 0))
        #expect(SemVer.latest(in: ["1.1"]) == nil)
    }

    @Test(arguments: [(SemVer.Bump.major, "2.0.0"), (.minor, "1.3.0"), (.patch, "1.2.4")])
    func bumps(_ bump: SemVer.Bump, expected: String) {
        #expect(SemVer(1, 2, 3).bumped(bump).description == expected)
    }

    @Test func minorBumpFromLatestTag() throws {
        let d = try VersionPlan.bump(.minor).decide(latestTag: SemVer(1, 1, 0), fileVersion: SemVer(1, 1, 0))
        #expect(d.version == SemVer(1, 2, 0))
        #expect(d.notes.isEmpty)
    }

    @Test func fileAheadOfTagWins() throws {
        let d = try VersionPlan.bump(.patch).decide(latestTag: SemVer(1, 1, 0), fileVersion: SemVer(1, 2, 0))
        #expect(d.version == SemVer(1, 2, 0))
        #expect(d.notes.count == 1)
    }

    @Test func explicitMustBeNewer() {
        #expect(throws: LaunchError.self) { try VersionPlan.explicit(SemVer(1, 1, 0)).decide(latestTag: SemVer(1, 1, 0), fileVersion: nil) }
    }

    @Test func rewritesEveryOccurrenceInProjectYML() throws {
        let yml = """
        targets:
          A:
            settings:
              MARKETING_VERSION: "1.2"
          B:
            settings:
              MARKETING_VERSION: 1.2
        """
        let out = try VersionFile.write(yml, key: "MARKETING_VERSION", version: SemVer(1, 3, 0))
        #expect(VersionFile.read(out, key: "MARKETING_VERSION") == ["1.3.0", "1.3.0"])
        #expect(!out.contains("1.2"))
    }

    @Test func rewritesPbxproj() throws {
        let out = try VersionFile.write("MARKETING_VERSION = 1.0;", key: "MARKETING_VERSION", version: SemVer(2, 0, 0))
        #expect(out == "MARKETING_VERSION = 2.0.0;")
    }

    @Test func missingKeyThrows() {
        #expect(throws: LaunchError.self) { try VersionFile.write("nothing", key: "MARKETING_VERSION", version: SemVer(1, 0, 0)) }
    }
}

@Suite("Config")
struct ConfigTests {
    @Test func parsesExample() throws {
        let config = try Config.parse(try fixture("launchseq.yml"))
        #expect(config.app.slug == "prime-time")
        #expect(config.languages.compactMap(\.ascLocale) == ["en-GB", "fr-FR"])
        #expect(config.appStore.releaseType == "MANUAL")
        #expect(config.appStore.phasedRelease)
        #expect(config.screenshots?.devices.first?.acceptedSizes.contains([1206, 2622]) == true)
        #expect(config.test.simulator.destination == "platform=iOS Simulator,name=iPhone 17 Pro,OS=27.2")
    }

    @Test func rejectsUnknownKeys() throws {
        let yaml = try fixture("launchseq.yml").replacingOccurrences(of: "  primary_locale: en-GB", with: "  primary_locale: en-GB\n  primary_locle: x")
        #expect { try Config.parse(yaml) } throws: { error in
            "\(error)".contains("primary_locle")
        }
    }

    @Test func rejectsPathsOutsideTheRepo() throws {
        let yaml = try fixture("launchseq.yml").replacingOccurrences(of: "raw_dir: AppStoreAssets/Screenshots/Raw", with: "raw_dir: ../../etc")
        #expect(throws: LaunchError.self) { try Config.parse(yaml) }
    }

    @Test func rejectsUnsafeNames() throws {
        let yaml = try fixture("launchseq.yml").replacingOccurrences(of: "name: 01-decide", with: "name: \"../x\"")
        #expect(throws: LaunchError.self) { try Config.parse(yaml) }
    }

    @Test func primaryLocaleMustBeListed() throws {
        let yaml = try fixture("launchseq.yml").replacingOccurrences(of: "primary_locale: en-GB", with: "primary_locale: en-US")
        #expect(throws: LaunchError.self) { try Config.parse(yaml) }
    }

    @Test func resolveRefusesSymlinkEscape() throws {
        let root = try tempDir()
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("out"), withDestinationURL: URL(fileURLWithPath: "/tmp"))
        #expect(throws: LaunchError.self) { try SafePath.resolve("out/x", under: root) }
    }
}

@Suite("App Store copy")
struct MetadataTests {
    func write(_ root: URL, _ files: [String: String]) throws {
        for (path, text) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    @Test func loadsSharedURLsAndValidates() throws {
        let root = try tempDir()
        try write(root, [
            "m/support_url.txt": "https://example.com/support\n",
            "m/en-GB/name.txt": "Prime Time: Is it Prime?\n",
            "m/en-GB/description.txt": "A game.",
            "m/en-GB/keywords.txt": "prime,number",
            "m/en-GB/release_notes.txt": "- New settings",
        ])
        let all = try Metadata.load(root: root, metadataDir: "m", locales: ["en-GB"])
        #expect(all[0][.supportURL] == "https://example.com/support")
        #expect(all[0][.name] == "Prime Time: Is it Prime?")
        #expect(Metadata.validate(all).isEmpty)
    }

    @Test func catchesLimitsTodoAndKeywordSpacing() {
        let m = LocaleMetadata(locale: "fr-FR", fields: [
            .name: String(repeating: "x", count: 31),
            .description: "d",
            .keywords: "a, b",
            .supportURL: "http://insecure.example.com",
            .releaseNotes: "TODO: translate",
        ])
        let problems = Metadata.validate([m])
        #expect(problems.contains { $0.contains("name.txt is 31 characters") })
        #expect(problems.contains { $0.contains("spaces after commas") })
        #expect(problems.contains { $0.contains("https") })
        #expect(problems.contains { $0.contains("TODO") })
    }

    @Test func importsMarkdown() throws {
        let english = """
        # App Store Copy

        ## App Name (max 30)
        ```
        Prime Time: Is it Prime?
        ```
        (24 chars)

        ## Promotional Text (max 170 — editable anytime without a new build)
        ```
        A number flashes on screen.
        ```

        ## Category
        Games
        """
        let localized = """
        ## en — What's New (max 4000)

        ```
        - Settings
        ```

        ## fr — French (France)

        ### Subtitle (max 30)
        ```
        Premier ou pas ?
        ```
        """
        #expect(MarkdownCopy.parse(english, defaultLanguage: "en") == ["en": [.name: "Prime Time: Is it Prime?", .promotionalText: "A number flashes on screen."]])
        #expect(MarkdownCopy.parse(localized, defaultLanguage: nil) == ["en": [.releaseNotes: "- Settings"], "fr": [.subtitle: "Premier ou pas ?"]])
    }
}

@Suite("Release notes")
struct ReleaseNotesTests {
    @Test func draftDropsHousekeeping() {
        let draft = ReleaseNotesDraft.draft(subjects: [
            "Show the app version in Settings",
            "Merge pull request #3",
            "docs: tidy README",
            "Update AGENTS.md",
            "Show the app version in Settings",
            "Ask for a rating after a new best streak",
        ], ignore: ["AGENTS"])
        #expect(draft == "- Show the app version in Settings\n- Ask for a rating after a new best streak")
    }

    @Test func emptyDraftHasPlaceholder() {
        #expect(ReleaseNotesDraft.draft(subjects: ["ci: x"], ignore: []) == "- Bug fixes and improvements")
    }

    @Test func translatorSendsKeyOnlyToAnthropic() async throws {
        let transport = RecordingTransport { request in
            let body: JSONValue = ["stop_reason": "end_turn", "content": [["type": "thinking", "thinking": ""], ["type": "text", "text": "- Réglages\n"]]]
            return (try body.data(), 200)
        }
        let translator = try #require(ClaudeTranslator(environment: ["ANTHROPIC_API_KEY": "sk-test"], model: "claude-opus-5-5", transport: transport))
        let out = try await translator.translate("- Settings", to: "fr-FR", toneReference: "Décidez", limit: 4000)
        #expect(out == "- Réglages")
        let request = try #require(transport.requests.first)
        #expect(request.url?.host == "api.anthropic.com")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "sk-test")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2026-10-21")
        let sent = try JSONValue.parse(try #require(request.httpBody))
        #expect(sent["model"].string == "claude-opus-5-5")
        #expect(sent["temperature"].isNull)
        #expect(sent["messages"].array.first?["content"].string?.contains("Décidez") == true)
    }

    @Test func translatorRefusalThrows() async throws {
        let transport = RecordingTransport { _ in (try (["stop_reason": "refusal", "content": []] as JSONValue).data(), 200) }
        let translator = try #require(ClaudeTranslator(environment: ["ANTHROPIC_API_KEY": "k"], model: "m", transport: transport))
        await #expect(throws: LaunchError.self) { try await translator.translate("x", to: "fr-FR", toneReference: nil, limit: 10) }
    }

    @Test func noKeyNoTranslator() {
        #expect(ClaudeTranslator(environment: [:], model: "m") == nil)
    }
}

@Suite("Small pieces")
struct SmallTests {
    @Test func pngSize() {
        var data = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13])
        data += Data("IHDR".utf8)
        data += Data([0, 0, 0x04, 0xB6, 0, 0, 0x0A, 0x3E])  // 1206 × 2622
        let size = PNG.size(of: data)
        #expect(size?.width == 1206 && size?.height == 2622)
        #expect(PNG.size(of: Data("nope".utf8)) == nil)
    }

    @Test func displaySizesAcceptLandscape() {
        #expect(DisplayTypes.accepts([[1206, 2622]], width: 2622, height: 1206))
        #expect(!DisplayTypes.accepts([[1206, 2622]], width: 1179, height: 2556))
    }

    @Test(arguments: [
        ("Sources/Services/**", "Sources/Services/Sync/A.swift", true),
        ("Sources/Services/**", "Sources/Views/A.swift", false),
        ("**/*.entitlements", "PrimeTime.entitlements", true),
        ("*.plist", "Sources/Info.plist", false),
    ])
    func glob(_ pattern: String, _ path: String, _ expected: Bool) {
        #expect(Glob.matches(pattern, path) == expected)
    }

    @Test func hostPolicy() {
        #expect(HostPolicy.isASC(URL(string: "https://api.appstoreconnect.apple.com/v1/apps")!))
        #expect(!HostPolicy.isASC(URL(string: "http://api.appstoreconnect.apple.com/v1/apps")!))
        #expect(!HostPolicy.isASC(URL(string: "https://api.appstoreconnect.apple.com.evil.com/v1")!))
        #expect(HostPolicy.isAppleUpload(URL(string: "https://store-032.blobstore.apple.com/x")!))
        #expect(!HostPolicy.isAppleUpload(URL(string: "https://apple.com.evil.com/x")!))
        #expect(!HostPolicy.isAppleUpload(URL(string: "https://evilapple.com/x")!))
    }

    @Test func checkRunSummary() throws {
        func runs(_ items: [(String, String, String?)]) throws -> GitHub.CheckState {
            let json: JSONValue = ["check_runs": .array(items.map { ["name": .string($0.0), "status": .string($0.1), "conclusion": $0.2.map(JSONValue.string) ?? .null] })]
            return try GitHub.summarise(checkRunsJSON: try json.data())
        }
        #expect(try runs([]) == .none)
        #expect(try runs([("Main", "completed", "success"), ("Lint", "completed", "skipped")]) == .passed(2))
        #expect(try runs([("Main", "in_progress", nil)]) == .pending(["Main"]))
        #expect(try runs([("Main", "completed", "failure"), ("B", "queued", nil)]) == .failed(["Main (failure)"]))
    }

    @Test func findsSimulatorByRuntime() throws {
        let json = """
        {"devices": {
          "com.apple.CoreSimulator.SimRuntime.iOS-26-4": [{"name": "iPhone 17 Pro", "udid": "OLD", "isAvailable": true}],
          "com.apple.CoreSimulator.SimRuntime.iOS-27-2": [{"name": "iPhone 17 Pro", "udid": "NEW", "isAvailable": true}]
        }}
        """
        #expect(try Simulators.find(Simulator(name: "iPhone 17 Pro", os: "27.2"), in: Data(json.utf8))?.udid == "NEW")
        #expect(try Simulators.find(Simulator(name: "iPhone 17 Pro", os: "28.0"), in: Data(json.utf8)) == nil)
    }

    @Test func displayQuotesForReadingOnly() {
        #expect(Shell.display(["git", "commit", "-m", "it's done"]) == "git commit -m 'it'\\''s done'")
    }

    @Test func runnerPassesArgumentsVerbatim() throws {
        let result = try ProcessRunner().run(["printf", "%s|", "$(whoami)", "; rm -rf /", "a b"], cwd: nil, environment: [:], mode: .capture)
        #expect(result.stdout == "$(whoami)|; rm -rf /|a b|")
    }

    @Test func runStateRoundTrips() throws {
        let dir = try tempDir()
        var state = RunState(version: "1.2.0")
        state.mark("tests", "abc")
        try state.save(gitDir: dir, dryRun: false)
        #expect(RunState.load(gitDir: dir, version: "1.2.0").done["tests"] == "abc")
        #expect(RunState.load(gitDir: dir, version: "1.3.0").done.isEmpty)
    }
}

@Suite("Credentials")
struct CredentialTests {
    @Test func tokenVerifiesWithPublicKey() throws {
        let key = P256.Signing.PrivateKey()
        let creds = ASCCredentials(keyID: "ABC123DEF4", issuerID: "issuer-uuid", privateKey: key)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let token = try ASCToken.make(creds, now: now)
        let parts = token.split(separator: ".").map(String.init)
        #expect(parts.count == 3)
        func decode(_ s: String) -> Data {
            var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            while b.count % 4 != 0 { b += "=" }
            return Data(base64Encoded: b)!
        }
        let header = try JSONValue.parse(decode(parts[0]))
        let payload = try JSONValue.parse(decode(parts[1]))
        #expect(header["alg"].string == "ES256" && header["kid"].string == "ABC123DEF4")
        #expect(payload["aud"].string == "appstoreconnect-v1" && payload["iss"].string == "issuer-uuid")
        #expect(payload["exp"].int! - payload["iat"].int! <= 20 * 60)
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: decode(parts[2]))
        #expect(key.publicKey.isValidSignature(signature, for: Data("\(parts[0]).\(parts[1])".utf8)))
    }

    @Test func refusesWorldReadableKeyFiles() throws {
        let dir = try tempDir()
        let file = dir.appendingPathComponent("credentials")
        try "key_id = ABC123DEF4\nissuer_id = x\nkey_path = \(dir.path)/k.p8\n".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        #expect { try ASCCredentials.load(environment: [:], file: file) } throws: { "\($0)".contains("chmod 600") }
    }

    @Test func loadsFromFileAndKeyPath() throws {
        let dir = try tempDir()
        let key = P256.Signing.PrivateKey()
        let p8 = dir.appendingPathComponent("AuthKey.p8")
        try key.pemRepresentation.write(to: p8, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: p8.path)
        let file = dir.appendingPathComponent("credentials")
        try "# comment\nkey_id = ABC123DEF4\nissuer_id = \"issuer\"\nkey_path = \(p8.path)\n".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let creds = try ASCCredentials.load(environment: [:], file: file)
        #expect(creds.keyID == "ABC123DEF4" && creds.issuerID == "issuer")
    }
}
