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
    /// Long-running work that blocks decisions, such as grouping or applying.
    private(set) var activity: String?
    /// Outcome of the last grouping or apply, shown until dismissed.
    var notice: String?
    var showSummary = false
    private(set) var repositoryURL: URL?
    private(set) var scope: GitScope = .workingTree
    private(set) var backend: AgentBackend
    private var provider: any ChangeProvider
    private var agent: any AgentClient
    private var grouper: (any ChangeGrouper)?
    private var applier: (any DecisionApplier)?
    private var archive: (any SessionArchive)?

    static let backendKey = "agentBackend"
    static let repositoryKey = "lastRepository"

    init(provider: any ChangeProvider = MockChangeProvider(), agent: any AgentClient = MockAgentClient(),
         grouper: (any ChangeGrouper)? = nil, applier: (any DecisionApplier)? = nil, archive: (any SessionArchive)? = nil) {
        self.provider = provider; self.agent = agent
        self.grouper = grouper; self.applier = applier; self.archive = archive
        backend = UserDefaults.standard.string(forKey: Self.backendKey).flatMap(AgentBackend.init) ?? .claude
    }

    var changes: [SemanticChange] { snapshot?.changes ?? [] }
    var selected: SemanticChange? { changes.first { $0.id == selectedID } }
    var selectedIndex: Int { changes.firstIndex { $0.id == selectedID } ?? 0 }
    var reviewed: Int { changes.filter { $0.decision != .pending }.count }
    var accepted: Int { changes.filter { $0.decision == .accepted }.count }
    var rejected: Int { changes.filter { $0.decision == .rejected }.count }
    var progress: Double { changes.isEmpty ? 0 : Double(reviewed) / Double(changes.count) }
    var isBusy: Bool { busyChangeID != nil || activity != nil }
    var isDemo: Bool { repositoryURL == nil }
    var agentName: String { agent.displayName }
    var canGroup: Bool { grouper != nil && !changes.isEmpty }
    var canApply: Bool { applier != nil && scope.appliesDecisions }
    private var archiveKey: String? { repositoryURL.map { "\($0.path)\n\(scope.rawValue)" } }

    /// Points the store at a real repository. Accept and reject stay decisions until explicitly applied.
    func open(_ url: URL, scope: GitScope? = nil, archive: (any SessionArchive)? = FileSessionArchive()) async {
        guard !isBusy, !isLoading else { return }
        do {
            let repository = try await GitRepository.discover(from: url)
            repositoryURL = repository.root
            if let scope { self.scope = scope }
            self.archive = archive
            UserDefaults.standard.set(repository.root.path, forKey: Self.repositoryKey)
            configure(repository)
            await load()
        } catch { notice = error.localizedDescription }
    }

    func openDemo() async {
        guard !isBusy, !isLoading else { return }
        repositoryURL = nil; archive = nil; grouper = nil; applier = nil
        provider = MockChangeProvider(); agent = MockAgentClient()
        await load()
    }

    func setScope(_ scope: GitScope) async {
        guard scope != self.scope, !isBusy, !isLoading, let repositoryURL else { return }
        self.scope = scope
        configure(GitRepository(root: repositoryURL))
        await load()
    }

    func setBackend(_ backend: AgentBackend) {
        guard backend != self.backend, !isBusy else { return }
        self.backend = backend
        UserDefaults.standard.set(backend.rawValue, forKey: Self.backendKey)
        if let repositoryURL { configure(GitRepository(root: repositoryURL)) }
    }

    private func configure(_ repository: GitRepository) {
        let git = GitChangeProvider(repository: repository, scope: scope)
        provider = git
        applier = GitDecisionApplier(provider: git)
        agent = CLIAgentClient(backend: backend)
        grouper = CLIChangeGrouper(backend: backend)
    }

    func load() async {
        guard !isLoading, !isBusy else { return }
        isLoading = true; error = nil
        defer { isLoading = false }
        do {
            let loaded = try await provider.loadSnapshot()
            history = []; conversations = [:]; showSummary = false
            // Same fingerprint means the same diff, so earlier decisions and grouping still describe it.
            if let key = archiveKey, let record = archive?.load(key: key), record.snapshot.revision == loaded.revision {
                snapshot = record.snapshot; history = record.history; conversations = record.conversations
            } else { snapshot = loaded }
            selectedID = (changes.first { $0.decision == .pending } ?? changes.first)?.id
        } catch { snapshot = nil; self.error = error.localizedDescription }
    }

    private func persist() {
        guard let key = archiveKey, let snapshot else { return }
        archive?.save(SessionRecord(snapshot: snapshot, history: history, conversations: conversations), key: key)
    }

    func select(_ id: UUID) { selectedID = id; showSummary = false }

    func move(_ offset: Int) {
        guard !changes.isEmpty else { return }
        select(changes[min(max(selectedIndex + offset, 0), changes.count - 1)].id)
    }

    /// Decisions record review intent only. They never apply or discard files.
    func decide(_ decision: ReviewDecision) {
        guard decision != .pending, !isBusy, !showSummary,
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
        persist()
    }

    func undo() {
        guard !isBusy, let event = history.popLast(),
              let index = changes.firstIndex(where: { $0.id == event.changeID }) else { return }
        snapshot?.changes[index].decision = event.previous
        select(event.changeID)
        persist()
    }

    func ask(_ message: String) async {
        let message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, !isBusy, let change = selected,
              let revision = snapshot?.revision else { return }
        busyChangeID = change.id
        let earlier = conversations[change.id] ?? []
        conversations[change.id, default: []].append(.init(isUser: true, text: message))
        defer { busyChangeID = nil; persist() }
        do {
            let reply = try await agent.respond(to: AgentRequest(revision: revision, change: change, message: message,
                                                                 history: earlier, rootPath: snapshot?.rootPath))
            conversations[change.id, default: []].append(.init(isUser: false, text: reply.text))
        } catch {
            conversations[change.id, default: []].append(.init(isUser: false, text: "Request failed: \(error.localizedDescription). You can try again."))
        }
    }

    /// Regrouping redefines what a change is, so earlier decisions can't carry over.
    func group() async {
        guard !isBusy, !isLoading, let grouper, let current = snapshot, !current.changes.isEmpty else { return }
        activity = "Grouping \(current.changes.flatMap(\.patches).count) hunks with \(agentName)…"
        defer { activity = nil }
        do {
            let grouped = try await grouper.group(current)
            guard snapshot?.revision == current.revision else { return }
            snapshot = grouped; history = []; conversations = [:]; showSummary = false
            selectedID = grouped.changes.first?.id
            notice = "\(agentName) grouped \(grouped.changes.flatMap(\.patches).count) hunks into \(grouped.changes.count) changes."
            persist()
        } catch { notice = error.localizedDescription }
    }

    func applyDecisions(_ options: ApplyOptions) async {
        guard !isBusy, !isLoading, let applier, let current = snapshot else { return }
        activity = "Applying decisions…"
        do {
            let result = try await applier.apply(current, options: options)
            var parts: [String] = []
            if options.stageAccepted { parts.append("Staged \(result.staged) \(result.staged == 1 ? "hunk" : "hunks").") }
            if options.discardRejected { parts.append("Discarded \(result.discarded) from the working tree.") }
            if let backup = result.backupPath { parts.append("Backup patch: \(backup)") }
            activity = nil
            await load()
            notice = parts.joined(separator: " ")
        } catch { activity = nil; notice = error.localizedDescription }
    }

    func reportData() throws -> Data {
        guard let snapshot else { throw CocoaError(.fileReadUnknown) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(ReviewReport(schemaVersion: 2, exportedAt: Date(), snapshot: snapshot, history: history))
    }
}
