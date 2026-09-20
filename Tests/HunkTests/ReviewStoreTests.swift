import XCTest
@testable import Hunk

@MainActor
final class ReviewStoreTests: XCTestCase {
    func testDecisionsAdvanceAndUndoRestoresPreviousChange() async throws {
        let store = ReviewStore()
        await store.load()
        let first = try XCTUnwrap(store.selectedID)
        store.decide(.accepted)
        XCTAssertNotEqual(store.selectedID, first)
        XCTAssertEqual(store.accepted, 1)
        store.undo()
        XCTAssertEqual(store.selectedID, first)
        XCTAssertEqual(store.reviewed, 0)
        XCTAssertEqual(store.selected?.decision, .pending)
    }

    func testWrapAroundFindsEarlierPendingChangeAndCompletes() async {
        let store = ReviewStore()
        await store.load()
        let first = store.changes[0].id
        store.select(store.changes[3].id)
        store.decide(.rejected)
        XCTAssertEqual(store.selectedID, first)
        for _ in 0..<3 { store.decide(.accepted) }
        XCTAssertTrue(store.showSummary)
        XCTAssertEqual(store.progress, 1)
        XCTAssertEqual(store.rejected, 1)
        store.undo()
        XCTAssertFalse(store.showSummary)
        XCTAssertEqual(store.reviewed, 3)
    }

    func testAgentReplyStaysWithOriginalChangeDuringNavigation() async throws {
        let store = ReviewStore(agent: ImmediateAgent())
        await store.load()
        let first = try XCTUnwrap(store.selectedID)
        await store.ask("Explain this")
        store.move(1)
        XCTAssertEqual(store.conversations[first]?.count, 2)
        XCTAssertNil(store.conversations[try XCTUnwrap(store.selectedID)])
        XCTAssertEqual(store.reviewed, 0)
        await store.ask("   ")
        XCTAssertNil(store.conversations[try XCTUnwrap(store.selectedID)])
    }

    func testExportContainsRevisionAndDecisions() async throws {
        let store = ReviewStore()
        await store.load()
        store.decide(.accepted)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let report = try decoder.decode(ReviewReport.self, from: store.reportData())
        XCTAssertEqual(report.snapshot.revision, "mock-v1")
        XCTAssertEqual(report.snapshot.changes.first?.decision, .accepted)
        XCTAssertEqual(report.history.count, 1)
        XCTAssertEqual(report.schemaVersion, 1)
    }

    func testReloadClearsSessionAndFailureIsVisible() async {
        let store = ReviewStore()
        await store.load()
        store.decide(.rejected)
        await store.load()
        XCTAssertEqual(store.reviewed, 0)
        XCTAssertTrue(store.history.isEmpty)
        let failing = ReviewStore(provider: FailingProvider())
        await failing.load()
        XCTAssertNotNil(failing.error)
        XCTAssertFalse(failing.isLoading)
    }

    func testMultiFileChangeAndLineNumbers() async {
        let store = ReviewStore()
        await store.load()
        XCTAssertEqual(store.changes[2].patches.count, 2)
        for line in store.changes.flatMap(\.patches).flatMap(\.lines) {
            if line.kind == .addition { XCTAssertNil(line.oldNumber); XCTAssertNotNil(line.newNumber) }
            if line.kind == .deletion { XCTAssertNotNil(line.oldNumber); XCTAssertNil(line.newNumber) }
        }
    }
}

private struct ImmediateAgent: AgentClient {
    func respond(to request: AgentRequest) async throws -> AgentReply { .init(text: request.message) }
}

private struct FailingProvider: ChangeProvider {
    func loadSnapshot() async throws -> ReviewSnapshot { throw CocoaError(.fileReadNoSuchFile) }
}
