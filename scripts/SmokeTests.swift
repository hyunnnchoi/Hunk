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
        print("PASS: navigation, decisions, undo, wraparound, in-flight agent isolation, export, reset, multi-file grouping, loading failure")
    }
}

private struct BrokenProvider: ChangeProvider {
    func loadSnapshot() async throws -> ReviewSnapshot { throw CocoaError(.fileReadNoSuchFile) }
}
