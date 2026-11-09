import Foundation

public enum LaunchError: Error, CustomStringConvertible, Equatable {
    case config(String)
    case precondition(String)
    case command(String)
    case api(String)
    case validation([String])
    case aborted(String)

    public var description: String {
        switch self {
        case .config(let m): return "Config error: \(m)"
        case .precondition(let m): return m
        case .command(let m): return m
        case .api(let m): return "App Store Connect: \(m)"
        case .validation(let problems): return "Validation failed:\n" + problems.map { "  • \($0)" }.joined(separator: "\n")
        case .aborted(let m): return "Stopped: \(m)"
        }
    }
}

// MARK: - Strict decoding

struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int?
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { self.stringValue = String(intValue); self.intValue = intValue }
}

extension Decoder {
    /// Fails if the keyed container at this position has keys `Keys` doesn't declare.
    func rejectUnknownKeys<Keys: CodingKey & CaseIterable>(_: Keys.Type) throws {
        let container = try self.container(keyedBy: AnyKey.self)
        let known = Set(Keys.allCases.map(\.stringValue))
        let unknown = container.allKeys.map(\.stringValue).filter { !known.contains($0) }.sorted()
        guard unknown.isEmpty else {
            let at = codingPath.isEmpty ? "top level" : codingPath.map(\.stringValue).joined(separator: ".")
            throw LaunchError.config("Unknown key\(unknown.count > 1 ? "s" : "") \(unknown.map { "`\($0)`" }.joined(separator: ", ")) at \(at). Allowed: \(known.sorted().joined(separator: ", "))")
        }
    }
}

// MARK: - Input safety

/// Names that become file or folder names (languages, devices, scenes).
enum SafeName {
    static func check(_ value: String, field: String) throws {
        guard value.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil, !value.contains("..") else {
            throw LaunchError.config("`\(field)` value \"\(value)\" may only contain letters, digits, '.', '_' and '-'")
        }
    }
}

/// Paths from config must stay inside the repo they're relative to.
public enum SafePath {
    public static func checkRelative(_ path: String, field: String) throws {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("~"), !parts.contains(".."), !path.contains("\0") else {
            throw LaunchError.config("`\(field)` must be a relative path inside the repo, not \"\(path)\"")
        }
    }

    /// Resolves `relative` under `root`, refusing anything that escapes it (including via symlinks).
    public static func resolve(_ relative: String, under root: URL) throws -> URL {
        try checkRelative(relative, field: "path")
        let base = root.standardizedFileURL.resolvingSymlinksInPath()
        let url = base.appendingPathComponent(relative).standardizedFileURL
        // `resolvingSymlinksInPath` only resolves parts that exist, so resolve the deepest
        // existing ancestor and add the rest back on.
        var existing = url
        var rest: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path) && existing.path != "/" {
            rest.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        let resolved = rest.reduce(existing.resolvingSymlinksInPath()) { $0.appendingPathComponent($1) }
        guard resolved.path == base.path || resolved.path.hasPrefix(base.path + "/") else {
            throw LaunchError.precondition("\(relative) resolves outside \(base.path)")
        }
        return url
    }
}

public enum GitRef {
    /// A conservative subset of `git check-ref-format`, so values are never mistaken for options.
    public static func checkBranch(_ name: String) throws {
        let ok = name.range(of: #"^[A-Za-z0-9][A-Za-z0-9._/-]*$"#, options: .regularExpression) != nil
            && !name.contains("..") && !name.hasSuffix("/") && !name.hasSuffix(".lock") && !name.contains("//")
        guard ok else { throw LaunchError.config("\"\(name)\" isn't a safe git branch name") }
    }
}

// MARK: - Screenshot display types

public enum DisplayTypes {
    /// Accepted pixel sizes (portrait; landscape is the same pair swapped) for common
    /// App Store Connect screenshot display types. A device's `sizes` in config overrides this,
    /// and is required for any display type not listed here.
    public static let knownSizes: [String: [[Int]]] = [
        "APP_IPHONE_67": [[1290, 2796], [1320, 2868], [1260, 2736]],
        "APP_IPHONE_65": [[1284, 2778], [1242, 2688]],
        "APP_IPHONE_61": [[1179, 2556], [1206, 2622]],
        "APP_IPHONE_58": [[1170, 2532], [1125, 2436], [1080, 2340]],
        "APP_IPHONE_55": [[1242, 2208]],
        "APP_IPAD_PRO_3GEN_129": [[2048, 2732], [2064, 2752]],
        "APP_WATCH_ULTRA": [[410, 502], [422, 514]],
        "APP_WATCH_SERIES_10": [[416, 496], [374, 446]],
    ]

    public static func accepts(_ sizes: [[Int]], width: Int, height: Int) -> Bool {
        sizes.contains { ($0[0] == width && $0[1] == height) || ($0[0] == height && $0[1] == width) }
    }
}

// MARK: - Files

extension FileManager {
    func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    /// Regular files directly inside `url`, sorted by name.
    func files(in url: URL, withExtension ext: String? = nil) -> [URL] {
        let items = (try? contentsOfDirectory(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])) ?? []
        return items
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .filter { ext == nil || $0.pathExtension.lowercased() == ext }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
