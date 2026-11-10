import Foundation

/// The parts of the App Store Connect Xcode Cloud API liftoff uses: find a workflow,
/// see whether it has built a commit, and start a build of a branch.
public struct XcodeCloud: Sendable {
    let client: ASCClient

    public init(client: ASCClient) { self.client = client }

    public struct Workflow: Sendable, Equatable { public var id: String; public var name: String; public var isEnabled: Bool }
    public struct BuildRun: Sendable, Equatable { public var id: String; public var number: Int?; public var progress: String }

    /// The app's workflow called `name`, or nil if it has none by that name.
    public func workflow(appID: String, named name: String) async throws -> Workflow? {
        let product = try await client.get("/v1/apps/\(appID)/ciProduct")
        guard let productID = product["data"]["id"].string else {
            throw LaunchError.api("This app has no Xcode Cloud product in App Store Connect")
        }
        let workflows = try await client.getAll("/v1/ciProducts/\(productID)/workflows")
        guard let w = workflows.first(where: { $0["attributes"]["name"].string == name }), let id = w["id"].string else { return nil }
        return Workflow(id: id, name: name, isEnabled: w["attributes"]["isEnabled"].bool ?? true)
    }

    /// The workflow's most recent build of `commit`, if it has one.
    public func buildRun(workflowID: String, commit: String) async throws -> BuildRun? {
        let runs = try await client.getAll("/v1/ciWorkflows/\(workflowID)/buildRuns")
        let matching = runs.filter { $0["attributes"]["sourceCommit"]["commitSha"].string == commit }
        guard let run = matching.max(by: { ($0["attributes"]["number"].int ?? 0) < ($1["attributes"]["number"].int ?? 0) }),
              let id = run["id"].string else { return nil }
        return BuildRun(id: id, number: run["attributes"]["number"].int, progress: run["attributes"]["executionProgress"].string ?? "PENDING")
    }

    /// Starts `workflow` on the tip of `branch`. Returns the new run.
    public func startBuild(workflow: Workflow, branch: String) async throws -> BuildRun {
        let repo = try await client.get("/v1/ciWorkflows/\(workflow.id)/repository")
        guard let repoID = repo["data"]["id"].string else { throw LaunchError.api("The \(workflow.name) workflow has no repository") }
        let refs = try await client.getAll("/v1/scmRepositories/\(repoID)/gitReferences")
        guard let ref = refs.first(where: { $0["attributes"]["canonicalName"].string == "refs/heads/\(branch)" && $0["attributes"]["isDeleted"].bool != true }),
              let refID = ref["id"].string else {
            throw LaunchError.api("Xcode Cloud can't see a branch called \(branch) in the workflow's repository")
        }
        let run = try await client.post("/v1/ciBuildRuns", [
            "data": [
                "type": "ciBuildRuns",
                "attributes": ["clean": false],
                "relationships": [
                    "workflow": ["data": ["type": "ciWorkflows", "id": .string(workflow.id)]],
                    "sourceBranchOrTag": ["data": ["type": "scmGitReferences", "id": .string(refID)]],
                ],
            ],
        ])
        return BuildRun(id: run["data"]["id"].string ?? "?", number: run["data"]["attributes"]["number"].int, progress: "PENDING")
    }
}
