import Foundation

/// Publishes the app's support, privacy and accessibility pages to the website repo.
/// The app repo is the source; the website copy is output. Works in a throwaway clone,
/// never in a checkout the person might have open.
public struct WebsiteSync: Sendable {
    let site: WebsiteSection
    let shell: Shell
    let github: GitHub
    let console: Console

    public init(site: WebsiteSection, shell: Shell, console: Console) {
        self.site = site; self.shell = shell; self.github = GitHub(shell: shell); self.console = console
    }

    /// Files under the source folder, as paths relative to it.
    public static func sourceFiles(root: URL, source: String) throws -> [String] {
        let dir = try SafePath.resolve(source, under: root)
        guard let walker = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return [] }
        var out: [String] = []
        for case let url as URL in walker where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            let resolved = url.resolvingSymlinksInPath().path
            guard resolved.hasPrefix(dir.resolvingSymlinksInPath().path + "/") else { continue }
            out.append(String(resolved.dropFirst(dir.resolvingSymlinksInPath().path.count + 1)))
        }
        return out.sorted()
    }

    public enum Outcome: Equatable, Sendable { case unchanged, merged(String), openPR(String) }

    public func publish(appName: String, version: String) throws -> Outcome {
        let files = try Self.sourceFiles(root: shell.root, source: site.source)
        guard !files.isEmpty else { throw LaunchError.precondition("No pages in \(site.source)/ to publish") }
        let branch = "launchseq/\(Config.slug(appName))-\(version)"
        try GitRef.checkBranch(branch)

        let work = FileManager.default.temporaryDirectory.appendingPathComponent("launchseq-site-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: work) }
        console.step("Cloning \(site.repo) into a temporary folder")
        // The clone is read-only work until the push, so it runs even in a dry run.
        try shell.read(["gh", "repo", "clone", site.repo, work.path, "--", "--quiet", "--depth", "1", "--branch", site.branch])

        if let existing = try github.pullRequest(head: branch, cwd: work, repo: site.repo), existing.state == "OPEN" {
            console.ok("Website PR already open: \(existing.url)")
            return try finish(pr: existing.url, cwd: work)
        }

        let dest = try SafePath.resolve(site.folder, under: work)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let src = try SafePath.resolve(site.source, under: shell.root)
        for file in files {
            let to = dest.appendingPathComponent(file)
            try FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: to.path) { try FileManager.default.removeItem(at: to) }
            try FileManager.default.copyItem(at: src.appendingPathComponent(file), to: to)
        }
        let status = try shell.read(["git", "status", "--porcelain", "--", site.folder], cwd: work).trimmed
        if status.isEmpty { console.ok("Website pages already match \(site.source)/"); return .unchanged }
        console.info(status.split(separator: "\n").map { "      \($0)" }.joined(separator: "\n"))

        try console.require("Push these website changes to \(site.repo) and open a PR?")
        try shell.change(["git", "switch", "-c", branch], cwd: work)
        try shell.change(["git", "add", "--", site.folder], cwd: work)
        try shell.change(["git", "commit", "--quiet", "-m", "Update \(appName) pages for \(version)"], cwd: work)
        try shell.change(["git", "push", "--quiet", "-u", "origin", "refs/heads/\(branch):refs/heads/\(branch)"], cwd: work)
        let url = try github.createPullRequest(base: site.branch, head: branch, title: "Update \(appName) pages for \(version)",
                                               body: "Published by launchseq from the \(appName) repo's `\(site.source)/` folder for release \(version).",
                                               cwd: work, repo: site.repo)
        console.ok("Opened \(url.isEmpty ? "website PR" : url)")
        return try finish(pr: url.isEmpty ? branch : url, cwd: work)
    }

    private func finish(pr: String, cwd: URL) throws -> Outcome {
        console.step("Waiting for the website PR's checks")
        guard try github.watchChecks(pr: pr, cwd: cwd, repo: site.repo) else {
            console.warn("Website checks failed; leaving the PR open: \(pr)")
            return .openPR(pr)
        }
        guard try console.confirm("Website checks passed. Merge \(pr) now (rebase and merge)?") else { return .openPR(pr) }
        try github.mergePullRequest(pr: pr, cwd: cwd, repo: site.repo)
        console.ok("Merged website PR")
        return .merged(pr)
    }
}

extension Config {
    static func slug(_ name: String) -> String {
        name.lowercased().replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}
