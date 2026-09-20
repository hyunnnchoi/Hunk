import Foundation
import Observation

@MainActor @Observable
final class ReviewStore {
    private(set) var snapshot: ReviewSnapshot?
    var selectedID: UUID?
    private(set) var isLoading = false
    private(set) var error: String?
    private(set) var history: [DecisionEvent] = []
    private(set) var conversations: [UUID: [ConversationMessage]] = [:]
    private(set) var busyChangeID: UUID?
    var showSummary = false
    private let provider: any ChangeProvider
    private let agent: any AgentClient

    init(provider: any ChangeProvider = MockChangeProvider(), agent: any AgentClient = MockAgentClient()) {
        self.provider = provider; self.agent = agent
    }

    var changes: [SemanticChange] { snapshot?.changes ?? [] }
    var selected: SemanticChange? { changes.first { $0.id == selectedID } }
    var selectedIndex: Int { changes.firstIndex { $0.id == selectedID } ?? 0 }
    var reviewed: Int { changes.filter { $0.decision != .pending }.count }
    var accepted: Int { changes.filter { $0.decision == .accepted }.count }
    var rejected: Int { changes.filter { $0.decision == .rejected }.count }
    var progress: Double { changes.isEmpty ? 0 : Double(reviewed) / Double(changes.count) }

    func load() async {
        guard !isLoading, busyChangeID == nil else { return }
        isLoading = true; error = nil
        defer { isLoading = false }
        do {
            let loaded = try await provider.loadSnapshot()
            snapshot = loaded; selectedID = loaded.changes.first?.id
            history = []; conversations = [:]; showSummary = false
        } catch { self.error = error.localizedDescription }
    }

    func select(_ id: UUID) { selectedID = id; showSummary = false }

    func move(_ offset: Int) {
        guard !changes.isEmpty else { return }
        select(changes[min(max(selectedIndex + offset, 0), changes.count - 1)].id)
    }

    /// Decisions record review intent only. They never apply or discard files.
    func decide(_ decision: ReviewDecision) {
        guard decision != .pending, busyChangeID == nil,
              let index = changes.firstIndex(where: { $0.id == selectedID }) else { return }
        let before = changes[index]
        guard before.decision != decision else { return }
        history.append(DecisionEvent(id: UUID(), changeID: before.id,
                                     previous: before.decision, decision: decision, date: Date()))
        snapshot?.changes[index].decision = decision
        let order = Array(changes.indices.dropFirst(index + 1)) + Array(changes.indices.prefix(index + 1))
        if let next = order.first(where: { changes[$0].decision == .pending }) {
            select(changes[next].id)
        } else { showSummary = true }
    }

    func undo() {
        guard busyChangeID == nil, let event = history.popLast(),
              let index = changes.firstIndex(where: { $0.id == event.changeID }) else { return }
        snapshot?.changes[index].decision = event.previous
        select(event.changeID)
    }

    func ask(_ message: String) async {
        let message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, busyChangeID == nil, let change = selected,
              let revision = snapshot?.revision else { return }
        busyChangeID = change.id
        conversations[change.id, default: []].append(.init(isUser: true, text: message))
        defer { busyChangeID = nil }
        do {
            let reply = try await agent.respond(to: AgentRequest(revision: revision, change: change, message: message))
            conversations[change.id, default: []].append(.init(isUser: false, text: reply.text))
        } catch {
            conversations[change.id, default: []].append(.init(isUser: false, text: "Request failed: \(error.localizedDescription). You can try again."))
        }
    }

    func reportData() throws -> Data {
        guard let snapshot else { throw CocoaError(.fileReadUnknown) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(ReviewReport(schemaVersion: 1, exportedAt: Date(), snapshot: snapshot, history: history))
    }
}
