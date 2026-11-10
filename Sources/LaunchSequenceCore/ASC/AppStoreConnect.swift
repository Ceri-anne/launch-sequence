import CryptoKit
import Foundation

/// The App Store Connect operations liftoff needs. Each one reads first and only
/// changes what differs, so running liftoff again after a failure is safe.
public struct AppStoreConnect: Sendable {
    public let client: ASCClient
    let console: Console

    public init(client: ASCClient, console: Console) {
        self.client = client; self.console = console
    }

    // MARK: App

    public func appID(bundleID: String, configured: String?) async throws -> String {
        let apps = try await client.getAll("/v1/apps", query: [("filter[bundleId]", bundleID), ("fields[apps]", "bundleId,name")])
        guard let app = apps.first(where: { $0["attributes"]["bundleId"].string == bundleID }), let id = app["id"].string else {
            throw LaunchError.api("No app with bundle ID \(bundleID) in this App Store Connect account")
        }
        if let configured, configured != id {
            throw LaunchError.config("`app_store.app_id` is \(configured) but \(bundleID) is app \(id)")
        }
        return id
    }

    // MARK: Version

    static let editableStates: Set<String> = ["PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED", "METADATA_REJECTED", "INVALID_BINARY"]

    public struct Version: Sendable {
        public var id: String
        public var versionString: String
        public var state: String
        /// In a dry run the new version doesn't exist yet. App Store Connect copies the latest
        /// version's localizations into a new one, so the preview compares against those.
        public var previewFrom: String? = nil
    }

    static func state(of v: JSONValue) -> String {
        v["attributes"]["appVersionState"].string ?? v["attributes"]["appStoreState"].string ?? "UNKNOWN"
    }

    /// Finds the version, reuses an editable one, or creates it.
    public func prepareVersion(appID: String, version: String, platform: String, releaseType: String) async throws -> Version {
        let versions = try await client.getAll("/v1/apps/\(appID)/appStoreVersions", query: [("filter[platform]", platform)])
        if let existing = versions.first(where: { $0["attributes"]["versionString"].string == version }), let id = existing["id"].string {
            let state = Self.state(of: existing)
            guard Self.editableStates.contains(state) else {
                throw LaunchError.precondition("Version \(version) already exists in App Store Connect in state \(state), so it can't be edited")
            }
            console.ok("Using existing App Store version \(version) (\(state))")
            if existing["attributes"]["releaseType"].string != releaseType {
                try await client.patch("/v1/appStoreVersions/\(id)", ["data": ["type": "appStoreVersions", "id": .string(id), "attributes": ["releaseType": .string(releaseType)]]])
            }
            return Version(id: id, versionString: version, state: state)
        }
        if let other = versions.first(where: { Self.editableStates.contains(Self.state(of: $0)) }), let id = other["id"].string {
            let old = other["attributes"]["versionString"].string ?? "?"
            try console.require("App Store Connect already has an editable version \(old). Rename it to \(version)?")
            try await client.patch("/v1/appStoreVersions/\(id)", ["data": ["type": "appStoreVersions", "id": .string(id), "attributes": ["versionString": .string(version), "releaseType": .string(releaseType)]]])
            return Version(id: id, versionString: version, state: Self.state(of: other))
        }
        let created = try await client.post("/v1/appStoreVersions", [
            "data": [
                "type": "appStoreVersions",
                "attributes": ["platform": .string(platform), "versionString": .string(version), "releaseType": .string(releaseType)],
                "relationships": ["app": ["data": ["type": "apps", "id": .string(appID)]]],
            ],
        ])
        guard let id = created["data"]["id"].string else { throw LaunchError.api("Creating version \(version) returned no ID") }
        if client.dryRun {
            func semver(_ v: JSONValue) -> SemVer { SemVer(marketing: v["attributes"]["versionString"].string ?? "") ?? SemVer(0, 0, 0) }
            let latest = versions.max { semver($0) < semver($1) }?["id"].string
            return Version(id: id, versionString: version, state: "PREPARE_FOR_SUBMISSION", previewFrom: latest)
        }
        console.ok("Created App Store version \(version)")
        return Version(id: id, versionString: version, state: "PREPARE_FOR_SUBMISSION")
    }

    public func setPhasedRelease(versionID: String, enabled: Bool) async throws {
        let current = try await client.get("/v1/appStoreVersions/\(versionID)/appStoreVersionPhasedRelease")
        let existingID = current["data"]["id"].string
        switch (enabled, existingID) {
        case (true, nil):
            try await client.post("/v1/appStoreVersionPhasedReleases", [
                "data": [
                    "type": "appStoreVersionPhasedReleases",
                    "attributes": ["phasedReleaseState": "INACTIVE"],
                    "relationships": ["appStoreVersion": ["data": ["type": "appStoreVersions", "id": .string(versionID)]]],
                ],
            ])
            console.ok("Phased release on")
        case (false, let id?):
            try await client.delete("/v1/appStoreVersionPhasedReleases/\(id)")
            console.ok("Phased release off")
        default:
            console.ok("Phased release already \(enabled ? "on" : "off")")
        }
    }

    // MARK: Copy

    /// Updates version-level copy (description, keywords, what's new, promo text, URLs).
    /// Returns the localization ID for each locale, for screenshots.
    public func syncVersionLocalizations(versionID: String, metadata: [LocaleMetadata], isFirstVersion: Bool, readFrom: String? = nil) async throws -> [String: String] {
        let existing = try await client.getAll("/v1/appStoreVersions/\(readFrom ?? versionID)/appStoreVersionLocalizations")
        var ids: [String: String] = [:]
        for m in metadata {
            var attrs: [String: JSONValue] = [:]
            func set(_ key: String, _ field: LocaleMetadata.Field) { if let v = m[field] { attrs[key] = .string(v) } }
            set("description", .description)
            set("keywords", .keywords)
            set("promotionalText", .promotionalText)
            set("supportUrl", .supportURL)
            set("marketingUrl", .marketingURL)
            if !isFirstVersion { set("whatsNew", .releaseNotes) }

            if let loc = existing.first(where: { $0["attributes"]["locale"].string == m.locale }), let id = loc["id"].string {
                ids[m.locale] = id
                let changed = attrs.filter { loc["attributes"][$0.key] != $0.value }
                if changed.isEmpty { console.ok("\(m.locale): version copy already up to date"); continue }
                try await client.patch("/v1/appStoreVersionLocalizations/\(id)", ["data": ["type": "appStoreVersionLocalizations", "id": .string(id), "attributes": .object(changed)]])
                console.ok("\(m.locale): updated \(changed.keys.sorted().joined(separator: ", "))")
            } else {
                attrs["locale"] = .string(m.locale)
                let created = try await client.post("/v1/appStoreVersionLocalizations", [
                    "data": [
                        "type": "appStoreVersionLocalizations",
                        "attributes": .object(attrs),
                        "relationships": ["appStoreVersion": ["data": ["type": "appStoreVersions", "id": .string(versionID)]]],
                    ],
                ])
                ids[m.locale] = created["data"]["id"].string
                console.ok("\(m.locale): added localization")
            }
        }
        return ids
    }

    /// Updates app-level copy (name, subtitle, privacy URL) on the editable App Info.
    public func syncAppInfoLocalizations(appID: String, metadata: [LocaleMetadata]) async throws {
        let infos = try await client.getAll("/v1/apps/\(appID)/appInfos")
        let liveStates: Set<String> = ["READY_FOR_DISTRIBUTION", "READY_FOR_SALE", "REPLACED_WITH_NEW_INFO"]
        let editable = infos.first(where: { !liveStates.contains($0["attributes"]["state"].string ?? $0["attributes"]["appStoreState"].string ?? "") })
        // A dry run hasn't created the version, so there's no editable App Info yet: preview against the live one.
        guard let info = editable ?? (client.dryRun ? infos.first : nil), let infoID = info["id"].string else {
            throw LaunchError.api("No editable App Info found. It usually appears once a new version has been created.")
        }
        let existing = try await client.getAll("/v1/appInfos/\(infoID)/appInfoLocalizations")
        for m in metadata {
            var attrs: [String: JSONValue] = [:]
            if let v = m[.name] { attrs["name"] = .string(v) }
            if let v = m[.subtitle] { attrs["subtitle"] = .string(v) }
            if let v = m[.privacyURL] { attrs["privacyPolicyUrl"] = .string(v) }
            if let loc = existing.first(where: { $0["attributes"]["locale"].string == m.locale }), let id = loc["id"].string {
                let changed = attrs.filter { loc["attributes"][$0.key] != $0.value }
                if changed.isEmpty { continue }
                try await client.patch("/v1/appInfoLocalizations/\(id)", ["data": ["type": "appInfoLocalizations", "id": .string(id), "attributes": .object(changed)]])
                console.ok("\(m.locale): updated \(changed.keys.sorted().joined(separator: ", "))")
            } else {
                attrs["locale"] = .string(m.locale)
                try await client.post("/v1/appInfoLocalizations", [
                    "data": [
                        "type": "appInfoLocalizations",
                        "attributes": .object(attrs),
                        "relationships": ["appInfo": ["data": ["type": "appInfos", "id": .string(infoID)]]],
                    ],
                ])
                console.ok("\(m.locale): added app info localization")
            }
        }
    }

    // MARK: Screenshots

    public struct LocalScreenshot: Sendable {
        public var fileName: String
        public var data: Data
        public var md5: String { Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined() }
        public init(fileName: String, data: Data) { self.fileName = fileName; self.data = data }
    }

    public enum ScreenshotResult: Equatable, Sendable { case unchanged, replaced(Int) }

    /// Makes the set for one localization × display type match `files` exactly, in order.
    /// If it already matches (same file names and checksums, all processed), nothing changes.
    public func syncScreenshots(localizationID: String, displayType: String, files: [LocalScreenshot], label: String? = nil) async throws -> ScreenshotResult {
        let label = label ?? displayType
        let sets = try await client.getAll("/v1/appStoreVersionLocalizations/\(localizationID)/appScreenshotSets")
        var setID = sets.first(where: { $0["attributes"]["screenshotDisplayType"].string == displayType })?["id"].string
        var keptIDs: [String] = []
        if let setID {
            let current = try await client.getAll("/v1/appScreenshotSets/\(setID)/appScreenshots")
            // Keep the screenshots at the start that are already right, so a run that stopped
            // partway carries on from where it got to. Everything after them is replaced.
            let kept = zip(current, files).prefix { remote, local in
                remote["attributes"]["fileName"].string == local.fileName
                    && remote["attributes"]["sourceFileChecksum"].string?.lowercased() == local.md5
                    && remote["attributes"]["assetDeliveryState"]["state"].string == "COMPLETE"
            }.count
            if kept == files.count && current.count == files.count { return .unchanged }
            keptIDs = current.prefix(kept).compactMap { $0["id"].string }
            for shot in current.dropFirst(kept) { if let id = shot["id"].string { try await client.delete("/v1/appScreenshots/\(id)") } }
        } else {
            let created = try await client.post("/v1/appScreenshotSets", [
                "data": [
                    "type": "appScreenshotSets",
                    "attributes": ["screenshotDisplayType": .string(displayType)],
                    "relationships": ["appStoreVersionLocalization": ["data": ["type": "appStoreVersionLocalizations", "id": .string(localizationID)]]],
                ],
            ])
            setID = created["data"]["id"].string
        }
        guard let setID else { throw LaunchError.api("No screenshot set ID for \(displayType)") }

        // One at a time: each screenshot is uploaded and processed by Apple before the next starts.
        var uploadedIDs = keptIDs
        let toUpload = files.count - keptIDs.count
        console.step("\(label): uploading \(toUpload) screenshot\(toUpload == 1 ? "" : "s") one at a time\(keptIDs.isEmpty ? "" : " (the first \(keptIDs.count) are already there)")")
        for (n, file) in files.enumerated().dropFirst(keptIDs.count) {
            console.info("\(label): \(n + 1)/\(files.count) \(file.fileName)")
            let reserved = try await client.post("/v1/appScreenshots", [
                "data": [
                    "type": "appScreenshots",
                    "attributes": ["fileName": .string(file.fileName), "fileSize": .number(Double(file.data.count))],
                    "relationships": ["appScreenshotSet": ["data": ["type": "appScreenshotSets", "id": .string(setID)]]],
                ],
            ])
            guard let shotID = reserved["data"]["id"].string else { throw LaunchError.api("Reserving \(file.fileName) returned no ID") }
            for op in try ASCClient.uploadOperations(reserved["data"]["attributes"]) {
                try await client.upload(op, file: file.data)
            }
            try await client.patch("/v1/appScreenshots/\(shotID)", [
                "data": ["type": "appScreenshots", "id": .string(shotID), "attributes": ["uploaded": true, "sourceFileChecksum": .string(file.md5)]],
            ])
            if !client.dryRun { try await waitForScreenshots([shotID], label: "\(label) \(file.fileName)") }
            uploadedIDs.append(shotID)
        }
        try await client.patch("/v1/appScreenshotSets/\(setID)/relationships/appScreenshots", [
            "data": .array(uploadedIDs.map { ["type": "appScreenshots", "id": .string($0)] }),
        ])
        return .replaced(toUpload)
    }

    /// Apple has taken 10-15 minutes to process a set of screenshots, so this waits up to
    /// `timeoutMinutes` and says how far it has got every `progressEvery` seconds.
    func waitForScreenshots(_ ids: [String], label: String, timeoutMinutes: Int = 30, pollSeconds: Double = 5, progressEvery: Double = 30) async throws {
        var pending = ids
        var elapsed: Double = 0
        var lastReport: Double = 0
        while true {
            var stillPending: [String] = []
            for id in pending {
                let shot = try await client.get("/v1/appScreenshots/\(id)", query: [("fields[appScreenshots]", "assetDeliveryState,fileName")])
                let state = shot["data"]["attributes"]["assetDeliveryState"]["state"].string ?? ""
                if state == "COMPLETE" { continue }
                if state == "FAILED" {
                    let errors = shot["data"]["attributes"]["assetDeliveryState"]["errors"].array.compactMap { $0["description"].string }
                    throw LaunchError.api("Screenshot \(shot["data"]["attributes"]["fileName"].string ?? id) failed processing: \(errors.joined(separator: "; "))")
                }
                stillPending.append(id)
            }
            pending = stillPending
            if pending.isEmpty {
                if elapsed > 0 { console.info("\(label): \(ids.count == 1 ? "" : "all \(ids.count) ")processed (\(Self.duration(elapsed)))") }
                return
            }
            if elapsed >= Double(timeoutMinutes * 60) {
                throw LaunchError.api("\(label): \(pending.count) of \(ids.count) screenshot\(ids.count == 1 ? "" : "s") still processing after \(timeoutMinutes) minutes. Wait for Apple to finish, then run liftoff again: screenshots that have finished are left alone.")
            }
            if elapsed - lastReport >= progressEvery || elapsed == 0 {
                console.info("… \(label): \(ids.count - pending.count)/\(ids.count) processed by Apple (\(Self.duration(elapsed)))")
                lastReport = elapsed
            }
            await client.sleep(pollSeconds)
            elapsed += pollSeconds
        }
    }

    static func duration(_ seconds: Double) -> String {
        let s = Int(seconds)
        return s < 60 ? "\(s)s" : "\(s / 60)m \(s % 60)s"
    }

    // MARK: Build

    public struct BuildInfo: Sendable { public var id: String; public var number: String; public var usesNonExemptEncryption: Bool? }

    /// Polls until a processed (VALID) build of `version` uploaded after `since` appears.
    public func waitForBuild(appID: String, version: String, since: Date, timeoutMinutes: Int) async throws -> BuildInfo? {
        let deadline = Date().addingTimeInterval(Double(timeoutMinutes) * 60)
        var announced = false
        while true {
            let builds = try await client.getAll("/v1/builds", query: [
                ("filter[app]", appID),
                ("filter[preReleaseVersion.version]", version),
                ("sort", "-uploadedDate"),
                ("fields[builds]", "version,uploadedDate,processingState,expired,usesNonExemptEncryption"),
            ])
            let formatter = ISO8601DateFormatter()
            let fresh = builds.filter { b in
                guard let s = b["attributes"]["uploadedDate"].string, let d = formatter.date(from: s) else { return false }
                return d >= since.addingTimeInterval(-300) && b["attributes"]["expired"].bool != true
            }
            if let valid = fresh.first(where: { $0["attributes"]["processingState"].string == "VALID" }), let id = valid["id"].string {
                return BuildInfo(id: id, number: valid["attributes"]["version"].string ?? "?", usesNonExemptEncryption: valid["attributes"]["usesNonExemptEncryption"].bool)
            }
            if let bad = fresh.first(where: { ["FAILED", "INVALID"].contains($0["attributes"]["processingState"].string ?? "") }) {
                throw LaunchError.api("Build \(bad["attributes"]["version"].string ?? "?") of \(version) failed processing (\(bad["attributes"]["processingState"].string ?? ""))")
            }
            if client.dryRun { return nil }
            guard Date() < deadline else {
                throw LaunchError.api("No processed build of \(version) after \(timeoutMinutes) minutes. Check the Xcode Cloud Release workflow, then run liftoff again.")
            }
            if !announced {
                console.step(fresh.isEmpty ? "Waiting for Xcode Cloud to upload build \(version)…" : "Build uploaded, waiting for App Store Connect to process it…")
                announced = true
            }
            await client.sleep(60)
        }
    }

    public func attachBuild(versionID: String, buildID: String) async throws {
        let current = try await client.get("/v1/appStoreVersions/\(versionID)/relationships/build")
        if current["data"]["id"].string == buildID { console.ok("Build already attached"); return }
        try await client.patch("/v1/appStoreVersions/\(versionID)/relationships/build", ["data": ["type": "builds", "id": .string(buildID)]])
        console.ok("Attached build")
    }

    /// Sets TestFlight "What to Test" for each locale.
    public func setWhatToTest(buildID: String, notes: [String: String]) async throws {
        let existing = try await client.getAll("/v1/builds/\(buildID)/betaBuildLocalizations")
        for (locale, text) in notes.sorted(by: { $0.key < $1.key }) {
            if let loc = existing.first(where: { $0["attributes"]["locale"].string == locale }), let id = loc["id"].string {
                if loc["attributes"]["whatsNew"].string == text { continue }
                try await client.patch("/v1/betaBuildLocalizations/\(id)", ["data": ["type": "betaBuildLocalizations", "id": .string(id), "attributes": ["whatsNew": .string(text)]]])
            } else {
                try await client.post("/v1/betaBuildLocalizations", [
                    "data": [
                        "type": "betaBuildLocalizations",
                        "attributes": ["locale": .string(locale), "whatsNew": .string(text)],
                        "relationships": ["build": ["data": ["type": "builds", "id": .string(buildID)]]],
                    ],
                ])
            }
        }
        console.ok("TestFlight What to Test set for \(notes.count) locale\(notes.count == 1 ? "" : "s")")
    }

    /// Whether any version has been released before (What's New can't be set on a first version).
    public func hasReleasedVersion(appID: String, platform: String) async throws -> Bool {
        let versions = try await client.getAll("/v1/apps/\(appID)/appStoreVersions", query: [("filter[platform]", platform)])
        return versions.contains { ["READY_FOR_SALE", "READY_FOR_DISTRIBUTION", "REMOVED_FROM_SALE", "DEVELOPER_REMOVED_FROM_SALE", "REPLACED_WITH_NEW_VERSION"].contains(Self.state(of: $0)) }
    }
}
