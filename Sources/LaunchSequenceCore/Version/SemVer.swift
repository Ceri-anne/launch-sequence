import Foundation

/// A strict `MAJOR.MINOR.PATCH` version. Tags use this exact form, with no `v` prefix.
public struct SemVer: Comparable, Hashable, Sendable, CustomStringConvertible {
    public var major: Int
    public var minor: Int
    public var patch: Int

    public init(_ major: Int, _ minor: Int, _ patch: Int) {
        self.major = major; self.minor = minor; self.patch = patch
    }

    /// Parses exactly `X.Y.Z` (no leading zeros, no prefix, no suffix).
    public init?(_ string: String) {
        guard string.range(of: #"^(0|[1-9]\d{0,5})\.(0|[1-9]\d{0,5})\.(0|[1-9]\d{0,5})$"#, options: .regularExpression) != nil else { return nil }
        let parts = string.split(separator: ".").compactMap { Int($0) }
        self.init(parts[0], parts[1], parts[2])
    }

    /// Parses a marketing version as Xcode allows it: `X`, `X.Y` or `X.Y.Z`, missing parts as 0.
    public init?(marketing string: String) {
        guard string.range(of: #"^\d{1,6}(\.\d{1,6}){0,2}$"#, options: .regularExpression) != nil else { return nil }
        var parts = string.split(separator: ".").compactMap { Int($0) }
        while parts.count < 3 { parts.append(0) }
        self.init(parts[0], parts[1], parts[2])
    }

    public var description: String { "\(major).\(minor).\(patch)" }

    public static func < (a: SemVer, b: SemVer) -> Bool {
        (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch)
    }

    public enum Bump: String, CaseIterable, Sendable { case major, minor, patch }

    public func bumped(_ bump: Bump) -> SemVer {
        switch bump {
        case .major: return SemVer(major + 1, 0, 0)
        case .minor: return SemVer(major, minor + 1, 0)
        case .patch: return SemVer(major, minor, patch + 1)
        }
    }

    /// The highest strict-semver tag. Other tags (like a two-part `1.1`) are ignored.
    public static func latest(in tags: [String]) -> SemVer? {
        tags.compactMap { SemVer($0.trimmingCharacters(in: .whitespaces)) }.max()
    }
}

/// How the next version is chosen.
public enum VersionPlan: Equatable, Sendable {
    case bump(SemVer.Bump)
    case explicit(SemVer)

    public struct Decision: Equatable, Sendable {
        public var version: SemVer
        public var notes: [String]
    }

    /// Picks the next version. The latest tag is the source of truth; if the version file is
    /// already ahead of the bumped tag (bumped by hand), the larger is used so nothing is skipped
    /// or reused, and a note says so.
    public func decide(latestTag: SemVer?, fileVersion: SemVer?) throws -> Decision {
        var notes: [String] = []
        let base = latestTag ?? SemVer(0, 0, 0)
        if latestTag == nil { notes.append("No X.Y.Z tag found; treating the last release as 0.0.0.") }
        switch self {
        case .explicit(let v):
            guard v > base else { throw LaunchError.precondition("--version \(v) must be greater than the latest tag \(base)") }
            return Decision(version: v, notes: notes)
        case .bump(let bump):
            var next = base.bumped(bump)
            if let fileVersion, fileVersion > next {
                notes.append("The version file says \(fileVersion), ahead of \(base) bumped (\(next)); using \(fileVersion).")
                next = fileVersion
            }
            return Decision(version: next, notes: notes)
        }
    }
}

/// Reads and rewrites `KEY: value` build settings (XcodeGen `project.yml`) or `KEY = value;` (`.pbxproj`).
public enum VersionFile {
    static func pattern(_ key: String) -> String {
        #"(\b"# + key + #"\s*[:=]\s*)"?([0-9][0-9.]*)"?"#
    }

    public static func read(_ text: String, key: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern(key)) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 2)) }
    }

    /// Replaces every occurrence. Throws if there are none.
    public static func write(_ text: String, key: String, version: SemVer) throws -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern(key)) else { throw LaunchError.config("Bad version key") }
        let range = NSRange(location: 0, length: (text as NSString).length)
        guard regex.numberOfMatches(in: text, range: range) > 0 else {
            throw LaunchError.precondition("No \(key) setting found to update")
        }
        // A value with a ":" separator is YAML, so keep it quoted.
        var result = ""
        var last = text.startIndex
        for match in regex.matches(in: text, range: range) {
            let whole = Range(match.range, in: text)!
            let prefix = String(text[Range(match.range(at: 1), in: text)!])
            result += text[last..<whole.lowerBound]
            result += prefix.contains(":") ? "\(prefix)\"\(version)\"" : "\(prefix)\(version)"
            last = whole.upperBound
        }
        result += text[last...]
        return result
    }
}
