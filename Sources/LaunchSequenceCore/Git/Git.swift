import Foundation

/// Thin wrappers over `git` and `gh`. Every value is passed as its own argument,
/// and refs are validated before use.
public struct Git: Sendable {
    let shell: Shell

    public init(shell: Shell) { self.shell = shell }

    public func isClean() throws -> Bool {
        try shell.read(["git", "status", "--porcelain"]).trimmed.isEmpty
    }

    /// Every changed, staged or untracked path, relative to the repo root. Both sides of a rename are listed.
    public func dirtyPaths() throws -> [String] {
        let out = try shell.read(["git", "status", "--porcelain=v1", "-z", "--untracked-files=all"]).stdout
        return Self.parsePorcelain(out)
    }

    static func parsePorcelain(_ out: String) -> [String] {
        var paths: [String] = []
        var entries = out.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)[...]
        while let entry = entries.popFirst() {
            guard entry.count > 3 else { continue }
            let status = entry.prefix(2)
            paths.append(String(entry.dropFirst(3)))
            // A rename or copy is followed by its original path.
            if status.contains("R") || status.contains("C"), let original = entries.popFirst() { paths.append(original) }
        }
        return paths
    }

    public func branchExists(_ name: String) throws -> Bool {
        try GitRef.checkBranch(name)
        return try shell.read(["git", "rev-parse", "--verify", "--quiet", "refs/heads/\(name)"], allowFailure: true).status == 0
    }

    public func switchBranch(_ name: String) throws {
        try GitRef.checkBranch(name)
        try shell.change(["git", "switch", name])
    }

    public func currentBranch() throws -> String {
        try shell.read(["git", "rev-parse", "--abbrev-ref", "HEAD"]).trimmed
    }

    public func gitDir() throws -> URL {
        let path = try shell.read(["git", "rev-parse", "--absolute-git-dir"]).trimmed
        return URL(fileURLWithPath: path)
    }

    public func fetch(remote: String = "origin") throws {
        try shell.read(["git", "fetch", "--tags", "--prune", "--", remote])
    }

    public func tags() throws -> [String] {
        try shell.read(["git", "tag", "--list"]).stdout.split(separator: "\n").map(String.init)
    }

    public func revParse(_ ref: String) throws -> String {
        try shell.read(["git", "rev-parse", "--verify", "--quiet", "\(ref)^{commit}"]).trimmed
    }

    public func tagExists(_ tag: String) throws -> Bool {
        try shell.read(["git", "rev-parse", "--verify", "--quiet", "refs/tags/\(tag)"], allowFailure: true).status == 0
    }

    /// Commit subjects in `from..to`, oldest first, merges left out.
    public func subjects(from: String?, to: String) throws -> [String] {
        let range = from.map { "\($0)..\(to)" } ?? to
        return try shell.read(["git", "log", "--no-merges", "--reverse", "--format=%s", range, "--"]).stdout
            .split(separator: "\n").map(String.init)
    }

    public func changedFiles(from: String, to: String) throws -> [String] {
        try shell.read(["git", "diff", "--name-only", "\(from)..\(to)", "--"]).stdout
            .split(separator: "\n").map(String.init)
    }

    /// File contents at a ref, or nil if it didn't exist there.
    public func show(_ ref: String, path: String) throws -> String? {
        let result = try shell.read(["git", "show", "\(ref):\(path)"], allowFailure: true)
        return result.status == 0 ? result.stdout : nil
    }

    public func isAncestor(_ commit: String, of ref: String) throws -> Bool {
        try shell.read(["git", "merge-base", "--is-ancestor", commit, ref], allowFailure: true).status == 0
    }

    public func checkoutNewBranch(_ name: String, from start: String) throws {
        try GitRef.checkBranch(name)
        try shell.change(["git", "switch", "-c", name, start])
    }

    public func add(_ paths: [String]) throws {
        try shell.change(["git", "add", "--"] + paths)
    }

    public func hasStagedChanges() throws -> Bool {
        try shell.read(["git", "diff", "--cached", "--quiet"], allowFailure: true).status != 0
    }

    public func commit(message: String) throws {
        try shell.change(["git", "commit", "--quiet", "-m", message])
    }

    public func push(branch: String, setUpstream: Bool = true) throws {
        try GitRef.checkBranch(branch)
        try shell.change(["git", "push", "--quiet"] + (setUpstream ? ["-u"] : []) + ["origin", "refs/heads/\(branch):refs/heads/\(branch)"])
    }

    public func createAnnotatedTag(_ tag: String, at commit: String, message: String) throws {
        try shell.change(["git", "tag", "-a", tag, "-m", message, commit])
    }

    public func pushTag(_ tag: String) throws {
        try shell.change(["git", "push", "--quiet", "origin", "refs/tags/\(tag):refs/tags/\(tag)"])
    }
}

public struct GitHub: Sendable {
    let shell: Shell
    public init(shell: Shell) { self.shell = shell }

    public struct PullRequest: Decodable, Sendable {
        public var number: Int
        public var url: String
        public var state: String
        public var mergeCommit: MergeCommit?
        public struct MergeCommit: Decodable, Sendable { public var oid: String }
    }

    public func authStatus() throws -> Bool {
        try shell.read(["gh", "auth", "status"], allowFailure: true).status == 0
    }

    /// owner/name of the repo in `cwd`.
    public func repoName(cwd: URL? = nil) throws -> String {
        try shell.read(["gh", "repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner"], cwd: cwd).trimmed
    }

    public func pullRequest(head branch: String, cwd: URL? = nil, repo: String? = nil) throws -> PullRequest? {
        var args = ["gh", "pr", "list", "--head", branch, "--state", "all", "--json", "number,url,state,mergeCommit", "--limit", "1"]
        if let repo { args += ["--repo", repo] }
        let out = try shell.read(args, cwd: cwd).stdout
        return try JSONDecoder().decode([PullRequest].self, from: Data(out.utf8)).first
    }

    public func createPullRequest(base: String, head: String, title: String, body: String, cwd: URL? = nil, repo: String? = nil) throws -> String {
        var args = ["gh", "pr", "create", "--base", base, "--head", head, "--title", title, "--body", body]
        if let repo { args += ["--repo", repo] }
        return try shell.change(args, cwd: cwd).trimmed
    }

    /// The state of a PR's checks. `.none` means none have registered yet.
    public func prChecks(pr: String, cwd: URL? = nil, repo: String? = nil) throws -> CheckState {
        var args = ["gh", "pr", "checks", pr, "--json", "name,bucket"]
        if let repo { args += ["--repo", repo] }
        let result = try shell.read(args, cwd: cwd, allowFailure: true)
        if result.trimmed.hasPrefix("[") { return try Self.summarise(prChecksJSON: Data(result.trimmed.utf8)) }
        if (result.stderr + result.stdout).contains("no checks reported") { return .none }
        throw LaunchError.command("`\(Shell.display(args))` failed (\(result.status)):\n\(result.stderr)")
    }

    static func summarise(prChecksJSON data: Data) throws -> CheckState {
        struct Check: Decodable { var name: String; var bucket: String }
        let checks = try JSONDecoder().decode([Check].self, from: data)
        if checks.isEmpty { return .none }
        let failed = checks.filter { ["fail", "cancel"].contains($0.bucket) }
        if !failed.isEmpty { return .failed(failed.map { "\($0.name) (\($0.bucket))" }) }
        let pending = checks.filter { $0.bucket == "pending" }
        if !pending.isEmpty { return .pending(pending.map(\.name)) }
        return .passed(checks.count)
    }

    public func mergePullRequest(pr: String, cwd: URL? = nil, repo: String? = nil) throws {
        var args = ["gh", "pr", "merge", pr, "--rebase", "--delete-branch"]
        if let repo { args += ["--repo", repo] }
        try shell.change(args, cwd: cwd)
    }

    public enum CheckState: Equatable, Sendable { case passed(Int), pending([String]), failed([String]), none }

    /// Summarises GitHub check runs on a commit (Xcode Cloud reports there).
    public func checks(repo: String, commit: String) throws -> CheckState {
        let out = try shell.read(["gh", "api", "repos/\(repo)/commits/\(commit)/check-runs?per_page=100"]).stdout
        return try Self.summarise(checkRunsJSON: Data(out.utf8))
    }

    static func summarise(checkRunsJSON data: Data) throws -> CheckState {
        struct Response: Decodable { var check_runs: [Run] }
        struct Run: Decodable { var name: String; var status: String; var conclusion: String? }
        let runs = try JSONDecoder().decode(Response.self, from: data).check_runs
        if runs.isEmpty { return .none }
        let failed = runs.filter { $0.status == "completed" && !["success", "neutral", "skipped"].contains($0.conclusion ?? "") }
        if !failed.isEmpty { return .failed(failed.map { "\($0.name) (\($0.conclusion ?? "?"))" }) }
        let pending = runs.filter { $0.status != "completed" }
        if !pending.isEmpty { return .pending(pending.map(\.name)) }
        return .passed(runs.count)
    }

    public func releaseExists(_ tag: String) throws -> Bool {
        try shell.read(["gh", "release", "view", tag, "--json", "tagName"], allowFailure: true).status == 0
    }

    public func createDraftRelease(tag: String, notes: String) throws {
        try shell.change(["gh", "release", "create", tag, "--draft", "--verify-tag", "--title", tag, "--notes", notes, "--generate-notes"])
    }

    public func publishRelease(tag: String) throws {
        try shell.change(["gh", "release", "edit", tag, "--draft=false", "--latest"])
    }
}
