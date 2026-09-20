import Foundation

enum ReviewDecision: String, Codable, CaseIterable, Sendable {
    case pending, accepted, rejected
}

enum DiffKind: String, Codable, Sendable {
    case context, addition, deletion
    var prefix: String { self == .addition ? "+" : self == .deletion ? "−" : " " }
}

struct DiffLine: Identifiable, Codable, Sendable {
    let id: UUID
    let kind: DiffKind
    let oldNumber: Int?
    let newNumber: Int?
    let text: String

    init(_ kind: DiffKind, _ old: Int?, _ new: Int?, _ text: String) {
        self.id = UUID(); self.kind = kind
        self.oldNumber = old; self.newNumber = new; self.text = text
    }
}

struct FilePatch: Identifiable, Codable, Sendable {
    let id: UUID
    let path: String
    let symbol: String
    let lines: [DiffLine]
    init(path: String, symbol: String, lines: [DiffLine]) {
        id = UUID(); self.path = path; self.symbol = symbol; self.lines = lines
    }
}

/// A semantic unit may span several files; it is deliberately not a file or a hunk.
struct SemanticChange: Identifiable, Codable, Sendable {
    let id: UUID
    let title: String
    let summary: String
    let rationale: String
    let risk: String
    let validation: String
    let patches: [FilePatch]
    var decision: ReviewDecision = .pending
    var added: Int { patches.flatMap(\.lines).filter { $0.kind == .addition }.count }
    var removed: Int { patches.flatMap(\.lines).filter { $0.kind == .deletion }.count }

    init(title: String, summary: String, rationale: String, risk: String,
         validation: String, patches: [FilePatch]) {
        id = UUID(); self.title = title; self.summary = summary
        self.rationale = rationale; self.risk = risk
        self.validation = validation; self.patches = patches
    }
}

struct ReviewSnapshot: Codable, Sendable {
    let repository: String
    let branch: String
    /// Git providers should use an immutable diff/content fingerprint here.
    let revision: String
    var changes: [SemanticChange]
}

protocol ChangeProvider: Sendable {
    func loadSnapshot() async throws -> ReviewSnapshot
}

struct AgentRequest: Sendable {
    let revision: String
    let change: SemanticChange
    let message: String
}

struct AgentReply: Sendable {
    let text: String
}

protocol AgentClient: Sendable {
    func respond(to request: AgentRequest) async throws -> AgentReply
}

struct ConversationMessage: Identifiable {
    let id = UUID()
    let isUser: Bool
    let text: String
}

struct DecisionEvent: Identifiable, Codable {
    let id: UUID
    let changeID: UUID
    let previous: ReviewDecision
    let decision: ReviewDecision
    let date: Date
}

struct ReviewReport: Codable {
    let schemaVersion: Int
    let exportedAt: Date
    let snapshot: ReviewSnapshot
    let history: [DecisionEvent]
}
