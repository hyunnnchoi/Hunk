import Foundation

/// Opt-in check that really calls an agent CLI: `bash scripts/agent-live-check.sh claude|codex`.
@main
struct AgentLiveCheck {
    static func main() async throws {
        guard let backend = CommandLine.arguments.dropFirst().first.flatMap(AgentBackend.init) else {
            print("usage: AgentLiveCheck claude|codex"); exit(2)
        }
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("hunk-live-\(UUID().uuidString)")
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        let repo = GitRepository(root: root)
        let client = root.appendingPathComponent("Client.swift"), model = root.appendingPathComponent("FeedModel.swift")
        try "struct Client {\n    func fetch(_ path: String) -> String {\n        return load(path)\n    }\n\n\n\n\n\n\n\n\n    func log(_ text: String) {\n        print(text)\n    }\n}\n".write(to: client, atomically: true, encoding: .utf8)
        try "struct FeedModel {\n    let client = Client()\n    func refresh() -> String {\n        client.fetch(\"/feed\")\n    }\n}\n".write(to: model, atomically: true, encoding: .utf8)
        for arguments in [["init", "-q", "-b", "main"], ["add", "."],
                          ["-c", "user.name=Hunk", "-c", "user.email=hunk@example.com", "commit", "-q", "-m", "base"]] {
            try await repo.git(arguments)
        }
        try "struct Client {\n    func fetch(_ path: String, forceRefresh: Bool = false) -> String {\n        return load(path, bypassCache: forceRefresh)\n    }\n\n\n\n\n\n\n\n\n    func log(_ text: String) {\n        print(\"[client] \\(text)\")\n    }\n}\n".write(to: client, atomically: true, encoding: .utf8)
        try "struct FeedModel {\n    let client = Client()\n    func refresh() -> String {\n        client.fetch(\"/feed\", forceRefresh: true)\n    }\n}\n".write(to: model, atomically: true, encoding: .utf8)

        let snapshot = try await GitChangeProvider(repository: repo, scope: .workingTree).loadSnapshot()
        precondition(snapshot.changes.count == 3, "fixture should produce three hunks")
        let started = Date()
        let grouped = try await CLIChangeGrouper(backend: backend).group(snapshot)
        print("\(backend.label) grouped 3 hunks into \(grouped.changes.count) changes in \(Int(Date().timeIntervalSince(started)))s")
        for change in grouped.changes {
            print("- \(change.title) [\(change.patches.map(\.path).joined(separator: ", "))]\n  why: \(change.rationale)\n  risk: \(change.risk)")
        }
        precondition(grouped.changes.flatMap(\.patches).count == 3, "every hunk must survive grouping")
        let reply = try await CLIAgentClient(backend: backend).respond(to: AgentRequest(
            revision: grouped.revision, change: grouped.changes[0], message: "Answer in one sentence: which file defines Client?", rootPath: root.path))
        print("reply: \(reply.text)")
        let status = try await repo.git(["status", "--porcelain"]).text
        precondition(status.split(separator: "\n").count == 2, "the agent must not modify the repository:\n\(status)")
        print("PASS: \(backend.label) live grouping and question")
    }
}
