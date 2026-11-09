import Foundation

/// Thin wrappers over `git` and `gh`. Every value is passed as its own argument,
/// and refs are validated before use.
public struct Git: Sendable {
    let shell: Shell

    public init(shell: Shell) { self.shell = shell }

    public func isClean() throws -> Bool {
        try shell.read(["git", "status", "--porcelain"]).trimmed.isEmpty
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

    /// Waits for the PR's checks to finish. Returns false if any failed.
    public func watchChecks(pr: String, cwd: URL? = nil, repo: String? = nil) throws -> Bool {
        var args = ["gh", "pr", "checks", pr, "--watch", "--interval", "20"]
        if let repo { args += ["--repo", repo] }
        if shell.dryRun { shell.console.dry(Shell.display(args)); return true }
        return try shell.runner.run(args, cwd: cwd ?? shell.root, environment: [:], mode: .interactive).status == 0
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
