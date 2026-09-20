import Foundation
import CryptoKit

extension UUID {
    /// Stable identity so decisions survive reloads of the same diff.
    init(hashing text: String) {
        let d = Array(SHA256.hash(data: Data(text.utf8)))
        self.init(uuid: (d[0], d[1], d[2], d[3], d[4], d[5], d[6], d[7],
                         d[8], d[9], d[10], d[11], d[12], d[13], d[14], d[15]))
    }
}

enum GitScope: String, Codable, CaseIterable, Sendable, Identifiable {
    case workingTree, staged, branch
    var id: String { rawValue }
    var label: String {
        switch self {
        case .workingTree: "Working tree"
        case .staged: "Staged"
        case .branch: "Branch vs base"
        }
    }
    /// Only unstaged work can be staged or discarded hunk by hunk.
    var appliesDecisions: Bool { self == .workingTree }
}

struct GitRepository: Sendable {
    let root: URL
    private static let executable = URL(fileURLWithPath: "/usr/bin/git")

    static func discover(from url: URL) async throws -> GitRepository {
        let probe = GitRepository(root: url)
        let output = try await probe.git(["rev-parse", "--show-toplevel"], allowFailure: true)
        guard output.status == 0 else { throw HunkError("\(url.path) is not inside a Git repository.") }
        let path = output.text.trimmingCharacters(in: .newlines)
        return GitRepository(root: URL(fileURLWithPath: path, isDirectory: true))
    }

    @discardableResult
    func git(_ arguments: [String], stdin: Data? = nil, allowFailure: Bool = false) async throws -> ProcessOutput {
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        let output = try await ProcessRunner.run(Self.executable, ["-c", "core.quotepath=off", "-c", "color.ui=never"] + arguments,
                                                 cwd: root, stdin: stdin, environment: environment, timeout: 120)
        if !allowFailure, output.status != 0 {
            let detail = output.errorText.isEmpty ? "exit code \(output.status)" : output.errorText
            throw HunkError("git \(arguments.first ?? "") failed: \(detail)")
        }
        return output
    }

    func line(_ arguments: [String]) async -> String? {
        guard let output = try? await git(arguments, allowFailure: true), output.status == 0 else { return nil }
        let text = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

struct GitChangeProvider: ChangeProvider {
    let repository: GitRepository
    let scope: GitScope
    static let maxUntrackedFiles = 200
    static let maxUntrackedBytes = 512 * 1024

    func loadSnapshot() async throws -> ReviewSnapshot {
        let branch: String
        if let name = await repository.line(["symbolic-ref", "--short", "-q", "HEAD"]) { branch = name }
        else { branch = await repository.line(["rev-parse", "--short", "HEAD"]).map { "detached @ \($0)" } ?? "—" }
        let head = await repository.line(["rev-parse", "-q", "--verify", "HEAD"]) ?? "unborn"
        var warnings: [String] = []
        var title = scope.label

        let format = ["--no-ext-diff", "--no-textconv", "--src-prefix=a/", "--dst-prefix=b/"]
        var arguments: [String]
        switch scope {
        case .workingTree: arguments = ["diff"] + format
        case .staged: arguments = ["diff", "--cached", "-M"] + format
        case .branch:
            guard let base = await baseBranch() else {
                throw HunkError("Couldn’t find a base branch (origin/HEAD, main, or master) to compare against.")
            }
            guard let mergeBase = await repository.line(["merge-base", base, "HEAD"]) else {
                throw HunkError("\(branch) shares no history with \(base).")
            }
            arguments = ["diff", "-M"] + format + [mergeBase, "HEAD"]
            title = "\(branch) vs \(base)"
        }
        let diff = try await repository.git(arguments).stdout
        var hasher = SHA256()
        hasher.update(data: Data("\(scope.rawValue)\n\(head)\n".utf8))
        hasher.update(data: diff)

        var patches = DiffParser.parse(diff).flatMap(Self.patches(for:))
        if scope == .workingTree {
            patches += try await untrackedPatches(&hasher, &warnings)
        }
        let revision = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return ReviewSnapshot(repository: repository.root.lastPathComponent, branch: branch, revision: revision,
                              changes: patches.map(Self.ungrouped), title: title, scope: scope.rawValue,
                              rootPath: repository.root.path, warnings: warnings)
    }

    private func baseBranch() async -> String? {
        if let remote = await repository.line(["symbolic-ref", "--short", "-q", "refs/remotes/origin/HEAD"]) { return remote }
        for candidate in ["main", "master", "develop"] {
            if await repository.line(["rev-parse", "-q", "--verify", "refs/heads/\(candidate)"]) != nil { return candidate }
        }
        return nil
    }

    static func patches(for file: ParsedFile) -> [FilePatch] {
        let wholeFile = file.isBinary || file.isSubmodule || file.hunks.isEmpty || file.hunks.contains { $0.text == nil }
        let path = file.path
        if wholeFile {
            let note: String? = file.isBinary ? "Binary file · no text diff available."
                : file.isSubmodule ? "Submodule pointer change."
                : file.hunks.isEmpty ? (file.isRename ? "Renamed from \(file.oldPath ?? "?") without content changes." : "Mode or metadata change only.")
                : "Contains bytes that are not valid UTF-8, so it can only be taken as a whole file."
            let symbol = file.isRename ? "renamed from \(file.oldPath ?? "?")" : file.isNew ? "new file" : file.isDeleted ? "deleted file" : "whole file"
            return [FilePatch(id: UUID(hashing: "file\n" + file.header), path: path, symbol: symbol,
                              lines: file.hunks.flatMap(\.lines), note: note,
                              source: PatchSource(fileHeader: file.header, hunkText: "", oldStart: 0, wholeFile: true, untracked: false))]
        }
        return file.hunks.map { hunk in
            let text = hunk.text ?? ""
            let last = (hunk.lines.last?.newNumber ?? hunk.lines.last?.oldNumber) ?? hunk.newStart
            var symbol = hunk.context.trimmingCharacters(in: .whitespaces)
            if symbol.isEmpty {
                symbol = file.isNew ? "new file" : file.isDeleted ? "deleted file" : "lines \(max(hunk.newStart, 1))–\(last)"
            }
            if file.isRename { symbol += " · renamed from \(file.oldPath ?? "?")" }
            return FilePatch(id: UUID(hashing: "hunk\n\(path)\n\(text)"), path: path, symbol: symbol, lines: hunk.lines,
                             source: PatchSource(fileHeader: file.header, hunkText: text, oldStart: hunk.oldStart, wholeFile: false, untracked: false))
        }
    }

    /// One change per patch until an agent groups them.
    static func ungrouped(_ patch: FilePatch) -> SemanticChange {
        let name = (patch.path as NSString).lastPathComponent
        var symbol = patch.symbol
        if symbol.count > 60 { symbol = String(symbol.prefix(59)) + "…" }
        return SemanticChange(id: UUID(hashing: "change\n\(patch.id.uuidString)"), title: "\(name) · \(symbol)",
                              summary: "\(patch.path)", patches: [patch])
    }

    private func untrackedPatches(_ hasher: inout SHA256, _ warnings: inout [String]) async throws -> [FilePatch] {
        let listing = try await repository.git(["ls-files", "--others", "--exclude-standard", "-z"]).stdout
        let names = listing.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }.filter { !$0.hasSuffix("/") }
        if names.count > Self.maxUntrackedFiles {
            warnings.append("\(names.count - Self.maxUntrackedFiles) untracked files were left out of this review. Add them to .gitignore or stage them to narrow the scope.")
        }
        return names.prefix(Self.maxUntrackedFiles).map { name in
            let url = repository.root.appendingPathComponent(name)
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            var lines: [DiffLine] = []
            var note: String?
            if size > Self.maxUntrackedBytes {
                note = "Untracked file · \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)), too large to preview."
                hasher.update(data: Data("untracked\n\(name)\n\(size)\n".utf8))
            } else {
                let data = (try? Data(contentsOf: url)) ?? Data()
                hasher.update(data: Data("untracked\n\(name)\n".utf8)); hasher.update(data: data)
                if !data.contains(0), let text = String(data: data, encoding: .utf8) {
                    var rows = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                    if rows.last == "" { rows.removeLast() }
                    lines = rows.enumerated().map { DiffLine(.addition, nil, $0.offset + 1, $0.element.hasSuffix("\r") ? String($0.element.dropLast()) : $0.element) }
                    if lines.isEmpty { note = "Untracked empty file." }
                } else { note = "Untracked binary file." }
            }
            return FilePatch(id: UUID(hashing: "untracked\n\(name)\n\(size)"), path: name, symbol: "untracked file", lines: lines, note: note,
                             source: PatchSource(fileHeader: "", hunkText: "", oldStart: 0, wholeFile: true, untracked: true))
        }
    }
}

/// Stages accepted patches and, only when asked, discards rejected ones from the working tree.
struct GitDecisionApplier: DecisionApplier {
    let provider: GitChangeProvider
    private var repository: GitRepository { provider.repository }

    func apply(_ snapshot: ReviewSnapshot, options: ApplyOptions) async throws -> ApplyResult {
        guard provider.scope.appliesDecisions else {
            throw HunkError("Decisions can only be applied when reviewing the working tree.")
        }
        guard try await provider.loadSnapshot().revision == snapshot.revision else {
            throw HunkError("The working tree changed since this review was loaded. Reload and review the new diff before applying.")
        }
        func patches(_ decision: ReviewDecision) -> [FilePatch] {
            snapshot.changes.filter { $0.decision == decision }.flatMap(\.patches).filter { $0.source != nil }
        }
        let accepted = options.stageAccepted ? patches(.accepted) : []
        let rejected = options.discardRejected ? patches(.rejected) : []
        let stagePatch = Self.combinedPatch(accepted)
        let discardPatch = Self.combinedPatch(rejected)

        // Check everything before touching anything so a bad hunk can't leave a half-applied review.
        if !stagePatch.isEmpty {
            try await check(["apply", "--cached", "--check", "-"], stagePatch, "stage the accepted changes")
        }
        if !discardPatch.isEmpty {
            try await check(["apply", "-R", "--check", "-"], discardPatch, "discard the rejected changes")
        }

        var result = ApplyResult()
        if !rejected.isEmpty { result.backupPath = try await backup(rejected, discardPatch) }
        if !stagePatch.isEmpty { try await repository.git(["apply", "--cached", "-"], stdin: Data(stagePatch.utf8)) }
        let wholeAccepted = accepted.filter { $0.source?.wholeFile == true }.map(\.path)
        if !wholeAccepted.isEmpty { try await repository.git(["add", "-A", "--"] + wholeAccepted) }
        result.staged = accepted.count

        if !discardPatch.isEmpty { try await repository.git(["apply", "-R", "-"], stdin: Data(discardPatch.utf8)) }
        for patch in rejected where patch.source?.wholeFile == true {
            if patch.source?.untracked == true {
                // The Trash keeps untracked work recoverable; git has no copy of it.
                try FileManager.default.trashItem(at: repository.root.appendingPathComponent(patch.path), resultingItemURL: nil)
            } else {
                try await repository.git(["restore", "--worktree", "--", patch.path])
            }
        }
        result.discarded = rejected.count
        return result
    }

    private func check(_ arguments: [String], _ patch: String, _ action: String) async throws {
        let output = try await repository.git(arguments, stdin: Data(patch.utf8), allowFailure: true)
        guard output.status == 0 else {
            throw HunkError("Git can’t \(action) cleanly, so nothing was changed.\n\n\(output.errorText)")
        }
    }

    private func backup(_ rejected: [FilePatch], _ patch: String) async throws -> String {
        var data = Data(patch.utf8)
        let tracked = rejected.filter { $0.source?.wholeFile == true && $0.source?.untracked == false }.map(\.path)
        if !tracked.isEmpty { data.append(try await repository.git(["diff", "--binary", "--"] + tracked).stdout) }
        let relative = await repository.line(["rev-parse", "--git-path", "hunk-backups"]) ?? ".git/hunk-backups"
        let directory = URL(fileURLWithPath: relative, relativeTo: repository.root)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyyMMdd-HHmmss"
        let url = directory.appendingPathComponent("discarded-\(formatter.string(from: Date())).patch")
        try data.write(to: url, options: .atomic)
        return url.path
    }

    /// One patch with each file header once and that file's hunks in line order.
    static func combinedPatch(_ patches: [FilePatch]) -> String {
        var order: [String] = []
        var hunks: [String: [PatchSource]] = [:]
        for source in patches.compactMap(\.source) where !source.wholeFile {
            if hunks[source.fileHeader] == nil { order.append(source.fileHeader) }
            hunks[source.fileHeader, default: []].append(source)
        }
        return order.map { header in
            header + hunks[header]!.sorted { $0.oldStart < $1.oldStart }.map(\.hunkText).joined()
        }.joined()
    }
}
