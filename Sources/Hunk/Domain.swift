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

/// How a provider-backed patch maps onto the repository. Mock patches carry none.
struct PatchSource: Codable, Sendable, Equatable {
    /// Raw `diff --git` header up to the first hunk, newline-terminated.
    let fileHeader: String
    /// Raw hunk text including its `@@` line, newline-terminated. Empty for whole-file patches.
    let hunkText: String
    let oldStart: Int
    /// Binary, untracked, mode-only, and similar entries can only be taken or left as a file.
    let wholeFile: Bool
    let untracked: Bool
}

struct FilePatch: Identifiable, Codable, Sendable {
    let id: UUID
    let path: String
    let symbol: String
    let lines: [DiffLine]
    /// Shown instead of lines when there is nothing textual to render.
    let note: String?
    let source: PatchSource?

    init(id: UUID = UUID(), path: String, symbol: String, lines: [DiffLine],
         note: String? = nil, source: PatchSource? = nil) {
        self.id = id; self.path = path; self.symbol = symbol; self.lines = lines
        self.note = note; self.source = source
    }

    var added: Int { lines.filter { $0.kind == .addition }.count }
    var removed: Int { lines.filter { $0.kind == .deletion }.count }
    var language: String {
        let ext = (path as NSString).pathExtension
        return ext.isEmpty ? "FILE" : ext.uppercased()
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
    var added: Int { patches.reduce(0) { $0 + $1.added } }
    var removed: Int { patches.reduce(0) { $0 + $1.removed } }
    var fileCount: Int { Set(patches.map(\.path)).count }

    init(id: UUID = UUID(), title: String, summary: String, rationale: String = "", risk: String = "",
         validation: String = "", patches: [FilePatch]) {
        self.id = id; self.title = title; self.summary = summary
        self.rationale = rationale; self.risk = risk
        self.validation = validation; self.patches = patches
    }
}

struct ReviewSnapshot: Codable, Sendable {
    let repository: String
    let branch: String
    /// Git providers use an immutable diff/content fingerprint here.
    let revision: String
    var changes: [SemanticChange]
    var title: String = "Review"
    var scope: String = ""
    /// Absolute repository root for provider-backed sessions.
    var rootPath: String?
    /// True once an agent has grouped hunks into semantic changes.
    var grouped = false
    /// Provider notices such as skipped files. Never silently dropped.
    var warnings: [String] = []
}

protocol ChangeProvider: Sendable {
    func loadSnapshot() async throws -> ReviewSnapshot
}

struct ConversationMessage: Identifiable, Codable, Sendable {
    var id = UUID()
    let isUser: Bool
    let text: String
}

struct AgentRequest: Sendable {
    let revision: String
    let change: SemanticChange
    let message: String
    var history: [ConversationMessage] = []
    var rootPath: String?
}

struct AgentReply: Sendable {
    let text: String
}

protocol AgentClient: Sendable {
    var displayName: String { get }
    func respond(to request: AgentRequest) async throws -> AgentReply
}

/// Regroups a snapshot's patches into semantic changes. Must assign every patch exactly once.
protocol ChangeGrouper: Sendable {
    func group(_ snapshot: ReviewSnapshot) async throws -> ReviewSnapshot
}

struct ApplyOptions: Sendable {
    var stageAccepted = true
    var discardRejected = false
}

struct ApplyResult: Sendable {
    var staged = 0
    var discarded = 0
    var backupPath: String?
}

/// Turns recorded decisions into repository effects. Kept apart from reviewing on purpose.
protocol DecisionApplier: Sendable {
    func apply(_ snapshot: ReviewSnapshot, options: ApplyOptions) async throws -> ApplyResult
}

struct DecisionEvent: Identifiable, Codable, Sendable {
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

/// What the store persists between launches for a repository and scope.
struct SessionRecord: Codable, Sendable {
    let snapshot: ReviewSnapshot
    let history: [DecisionEvent]
    let conversations: [UUID: [ConversationMessage]]
}

protocol SessionArchive: Sendable {
    func load(key: String) -> SessionRecord?
    func save(_ record: SessionRecord, key: String)
}

struct HunkError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
