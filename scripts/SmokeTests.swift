import Foundation

@main
struct SmokeTests {
    @MainActor static func main() async throws {
        let store = ReviewStore()
        await store.load()
        precondition(store.changes.count == 4)
        let first = store.selectedID!
        store.decide(.accepted)
        precondition(store.accepted == 1 && store.selectedID != first)
        store.undo()
        precondition(store.reviewed == 0 && store.selectedID == first)
        store.select(store.changes[3].id)
        store.decide(.rejected)
        precondition(store.selectedID == first)
        let pendingRequest = Task { await store.ask("Explain the tradeoffs") }
        // Wait for request startup, then navigate while the reply is in flight.
        while store.busyChangeID == nil { await Task.yield() }
        store.move(1)
        store.decide(.accepted)
        precondition(store.reviewed == 1, "Decisions must be disabled while the agent is busy")
        await pendingRequest.value
        precondition(store.conversations[first]?.count == 2)
        precondition(store.conversations[store.selectedID!] == nil)
        precondition(store.reviewed == 1)
        for _ in 0..<3 { store.decide(.accepted) }
        precondition(store.showSummary && store.accepted == 3 && store.rejected == 1)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let report = try decoder.decode(ReviewReport.self, from: store.reportData())
        precondition(report.snapshot.revision == "mock-v1" && report.history.count == 4)
        store.undo()
        precondition(!store.showSummary && store.reviewed == 3)
        await store.load()
        precondition(store.history.isEmpty && store.conversations.isEmpty && store.reviewed == 0)
        precondition(store.changes[2].patches.count == 2)
        let failing = ReviewStore(provider: BrokenProvider())
        await failing.load()
        precondition(failing.error != nil && !failing.isLoading)
        try DiffSmokeTests.run()
        try await GitSmokeTests.run()
        print("PASS: navigation, decisions, undo, wraparound, in-flight agent isolation, export, reset, multi-file grouping, loading failure")
    }
}

enum DiffSmokeTests {
    static func run() throws {
        let diff = "diff --git a/my file.txt b/my file.txt\nindex 1..2 100644\n--- a/my file.txt\t\n+++ b/my file.txt\t\n@@ -1,2 +1,2 @@ func demo()\n one\r\n-diff --git a/x b/x\r\n+two\r\n\\ No newline at end of file\n"
            + "diff --git a/logo.png b/logo.png\nindex 3..4 100644\nBinary files a/logo.png and b/logo.png differ\n"
            + "diff --git \"a/caf\\303\\251.txt\" \"b/caf\\303\\251.txt\"\nold mode 100644\nnew mode 100755\n"
        let files = DiffParser.parse(Data(diff.utf8))
        precondition(files.count == 3, "A deleted line that looks like a diff header must not split the file")
        precondition(files[0].path == "my file.txt" && files[0].hunks.count == 1)
        let hunk = files[0].hunks[0]
        precondition(hunk.context == "func demo()" && hunk.lines.map(\.text) == ["one", "diff --git a/x b/x", "two"])
        precondition(hunk.text!.hasSuffix("+two\r\n\\ No newline at end of file\n"), "Raw hunk text must stay byte-exact")
        precondition(files[1].isBinary && files[1].path == "logo.png")
        precondition(files[2].path == "café.txt" && files[2].hunks.isEmpty)
        precondition(GitChangeProvider.patches(for: files[1])[0].source?.wholeFile == true)
        print("PASS: diff parsing (CRLF, header-like content, no-newline marker, binary, quoted paths)")
    }
}

enum GitSmokeTests {
    @MainActor static func run() async throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("hunk-smoke-\(UUID().uuidString)")
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        let repo = GitRepository(root: root)
        let file = root.appendingPathComponent("notes.txt")
        let original = (1...40).map { "line \($0)" }
        try original.joined(separator: "\n").appending("\n").write(to: file, atomically: true, encoding: .utf8)
        for arguments in [["init", "-q", "-b", "main"], ["add", "."],
                          ["-c", "user.name=Hunk", "-c", "user.email=hunk@example.com", "commit", "-q", "-m", "base"]] {
            try await repo.git(arguments)
        }
        var edited = original
        edited[1] = "line 2 accepted"; edited[37] = "line 38 rejected"
        try edited.joined(separator: "\n").appending("\n").write(to: file, atomically: true, encoding: .utf8)
        try "brand new\n".write(to: root.appendingPathComponent("new file.txt"), atomically: true, encoding: .utf8)

        let archive = FileSessionArchive(directory: root.appendingPathComponent(".git/hunk-test-sessions"))
        let store = ReviewStore()
        await store.open(root, archive: archive)
        precondition(store.error == nil && store.notice == nil, store.error ?? store.notice ?? "")
        precondition(store.changes.count == 3, "Expected two hunks and one untracked file, got \(store.changes.count)")
        precondition(store.changes.map(\.patches[0].path) == ["notes.txt", "notes.txt", "new file.txt"])
        store.decide(.accepted); store.decide(.rejected)
        precondition(store.reviewed == 2 && store.canApply)

        // A second store restores the same decisions because the diff fingerprint is unchanged.
        let reopened = ReviewStore()
        await reopened.open(root, archive: archive)
        precondition(reopened.accepted == 1 && reopened.rejected == 1 && reopened.history.count == 2)
        precondition(reopened.selected?.patches[0].path == "new file.txt", "Reopening should land on the first pending change")
        reopened.decide(.accepted)

        // Grouping validation: unknown and repeated ids are dropped, leftovers stay reviewable.
        let plan = CLIChangeGrouper.Plan(changes: [.init(title: "Both edits", summary: "s", rationale: "r", risk: "k", validation: "v",
                                                         hunks: ["h1", "H2", "h2", "h99"])])
        let grouped = try CLIChangeGrouper.regroup(reopened.snapshot!, plan: plan)
        precondition(grouped.grouped && grouped.changes.count == 2 && grouped.changes[0].patches.count == 2)
        precondition(grouped.changes[0].fileCount == 1 && grouped.changes[1].patches[0].path == "new file.txt")
        _ = try CLIChangeGrouper.decodePlan("Here you go:\n```json\n{\"changes\":[]}\n```")

        await reopened.applyDecisions(ApplyOptions(stageAccepted: true, discardRejected: true))
        let staged = try await repo.git(["diff", "--cached"]).text
        precondition(staged.contains("+line 2 accepted") && !staged.contains("rejected"), "Only the accepted hunk is staged")
        precondition(staged.contains("new file.txt"), "Accepted untracked files are staged")
        let working = try String(contentsOf: file, encoding: .utf8)
        precondition(working.contains("line 2 accepted") && working.contains("line 38\n"), "The rejected hunk is reverted on disk")
        let backups = try manager.contentsOfDirectory(atPath: root.appendingPathComponent(".git/hunk-backups").path)
        precondition(backups.count == 1, "Discarding keeps a backup patch")
        precondition(reopened.changes.isEmpty && reopened.notice?.contains("Staged 2") == true, reopened.notice ?? "no notice")

        // Applying against a diff that changed after loading must refuse.
        edited[20] = "line 21 late edit"
        try edited.joined(separator: "\n").appending("\n").write(to: file, atomically: true, encoding: .utf8)
        await reopened.load()
        reopened.decide(.accepted)
        try "line 1 moved\n".write(to: file, atomically: true, encoding: .utf8)
        await reopened.applyDecisions(ApplyOptions())
        precondition(reopened.notice?.contains("changed since") == true, reopened.notice ?? "no notice")
        let afterRefusal = try await repo.git(["diff", "--cached"]).text
        precondition(!afterRefusal.contains("late edit"), "A stale review must not stage anything")

        await reopened.setScope(.staged)
        precondition(reopened.changes.count == 2 && !reopened.canApply, "Staged scope is review-only")
        print("PASS: git provider, stable ids, session restore, regroup validation, stage/discard with backup, stale refusal, scopes")
    }
}

private struct BrokenProvider: ChangeProvider {
    func loadSnapshot() async throws -> ReviewSnapshot { throw CocoaError(.fileReadNoSuchFile) }
}
