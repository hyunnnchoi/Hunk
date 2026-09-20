import SwiftUI
import AppKit
import UniformTypeIdentifiers

private enum Palette {
    static let background = Color(red: 0.055, green: 0.067, blue: 0.085)
    static let panel = Color(red: 0.083, green: 0.098, blue: 0.12)
    static let accent = Color(red: 0.63, green: 0.84, blue: 0.66)
    static let muted = Color(red: 0.55, green: 0.60, blue: 0.67)
    static let line = Color.white.opacity(0.075)
}

struct ReviewView: View {
    @Bindable var store: ReviewStore
    @State private var showAgent = false
    @State private var exportError: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Palette.line)
            HStack(spacing: 0) {
                sidebar.frame(width: 252)
                Rectangle().fill(Palette.line).frame(width: 1)
                VStack(spacing: 0) {
                    if store.isLoading {
                        Spacer(); ProgressView("Loading changes…"); Spacer()
                    } else if let error = store.error {
                        ContentUnavailableView {
                            Label("Couldn’t load changes", systemImage: "exclamationmark.triangle")
                        } description: { Text(error) } actions: {
                            Button("Try again") { Task { await store.load() } }
                        }
                    } else if store.showSummary {
                        summary
                    } else if let change = store.selected {
                        changeHeader(change)
                        ScrollView {
                            VStack(alignment: .leading, spacing: 24) {
                                rationale(change)
                                ForEach(change.patches) { patch in PatchView(patch: patch) }
                                Label(change.risk, systemImage: "exclamationmark.circle")
                                    .font(.system(size: 12)).foregroundStyle(Palette.muted)
                                DisclosureGroup("Suggested verification · not run") {
                                    Text(change.validation).font(.system(size: 12))
                                        .foregroundStyle(Palette.muted).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                                }.font(.system(size: 12)).tint(Palette.muted)
                            }.padding(32).frame(maxWidth: 1100)
                                .frame(maxWidth: .infinity)
                        }
                        actions(change)
                    } else {
                        ContentUnavailableView("No changes to review", systemImage: "checkmark.circle", description: Text("Your review queue is empty."))
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Palette.background)
        .tint(Palette.accent)
        .sheet(isPresented: $showAgent) { AgentSheet(store: store) }
        .alert("Couldn’t export review", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("OK") { exportError = nil }
        } message: { Text(exportError ?? "") }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "square.stack.3d.up.fill").foregroundStyle(Palette.accent).font(.system(size: 20))
            Text("hunk").font(.system(size: 17, weight: .semibold, design: .rounded))
            Rectangle().fill(Palette.line).frame(width: 1, height: 18).padding(.horizontal, 8)
            Text(store.snapshot?.repository ?? "Review workspace").foregroundStyle(Palette.muted)
            Spacer()
            Label(store.snapshot?.branch ?? "—", systemImage: "arrow.triangle.branch").foregroundStyle(Palette.muted)
            Text("MOCK SESSION").font(.system(size: 9, weight: .bold, design: .monospaced))
                .tracking(1).padding(.horizontal, 9).padding(.vertical, 6)
                .background(Palette.accent.opacity(0.10), in: Capsule()).foregroundStyle(Palette.accent)
        }.font(.system(size: 12)).padding(.horizontal, 24).padding(.top, 30).padding(.bottom, 18)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("REVIEW QUEUE").font(.system(size: 10, weight: .semibold)).tracking(1.8).foregroundStyle(Palette.muted)
                .padding(.top, 28).padding(.bottom, 16)
            Text("Make caching reliable").font(.system(size: 18, weight: .semibold)).padding(.bottom, 8)
            Text("One intention at a time.").font(.system(size: 12)).foregroundStyle(Palette.muted)
            HStack {
                Text("\(store.reviewed) of \(store.changes.count) reviewed")
                Spacer(); Text("\(Int(store.progress * 100))%")
            }.font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.muted).padding(.top, 26)
            ProgressView(value: store.progress).tint(Palette.accent).padding(.top, 8).padding(.bottom, 24)
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(Array(store.changes.enumerated()), id: \.element.id) { index, change in
                        Button { store.select(change.id) } label: {
                            HStack(alignment: .top, spacing: 12) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 7).fill(statusColor(change).opacity(0.12)).frame(width: 27, height: 27)
                                    if change.decision == .pending {
                                        Text(String(format: "%02d", index + 1)).font(.system(size: 10, weight: .medium, design: .monospaced))
                                    } else { Image(systemName: change.decision == .accepted ? "checkmark" : "xmark").font(.system(size: 10, weight: .bold)) }
                                }.foregroundStyle(statusColor(change))
                                VStack(alignment: .leading, spacing: 7) {
                                    Text(change.title).font(.system(size: 12, weight: .medium)).multilineTextAlignment(.leading).lineSpacing(3)
                                    Text("\(change.patches.count) \(change.patches.count == 1 ? "file" : "files") · \(change.decision.rawValue)")
                                        .font(.system(size: 10)).foregroundStyle(Palette.muted)
                                }
                                Spacer(minLength: 0)
                            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                .background(store.selectedID == change.id && !store.showSummary ? Color.white.opacity(0.055) : .clear, in: RoundedRectangle(cornerRadius: 10))
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(store.selectedID == change.id && !store.showSummary ? Palette.accent.opacity(0.25) : .clear))
                        }.buttonStyle(.plain)
                    }
                }.padding(1)
            }
            Spacer(minLength: 20)
            Button { store.showSummary = true } label: {
                Label("Review summary", systemImage: "chart.bar.doc.horizontal").font(.system(size: 12))
            }.buttonStyle(.plain).foregroundStyle(Palette.muted).padding(.bottom, 18)
            Divider().overlay(Palette.line)
            HStack(spacing: 7) {
                Circle().fill(Palette.accent).frame(width: 5, height: 5)
                Text("Local demo · no agent connected").font(.system(size: 10)).foregroundStyle(Palette.muted)
            }.padding(.vertical, 20)
        }.padding(.horizontal, 18).background(Palette.panel.opacity(0.45))
    }

    private func statusColor(_ change: SemanticChange) -> Color {
        change.decision == .accepted ? Palette.accent : change.decision == .rejected ? .red.opacity(0.8) : Palette.muted
    }

    private func changeHeader(_ change: SemanticChange) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("CHANGE \(String(format: "%02d", store.selectedIndex + 1)) / \(String(format: "%02d", store.changes.count))")
                    .font(.system(size: 10, weight: .medium, design: .monospaced)).tracking(1.8).foregroundStyle(Palette.accent)
                Spacer()
                Button { store.move(-1) } label: { Image(systemName: "chevron.left") }
                    .disabled(store.selectedIndex == 0).help("Previous change")
                Button { store.move(1) } label: { Image(systemName: "chevron.right") }
                    .disabled(store.selectedIndex == store.changes.count - 1).help("Next change")
            }.buttonStyle(.borderless)
            Text(change.title).font(.system(size: 29, weight: .semibold)).tracking(-0.7)
            Text(change.summary).font(.system(size: 13)).foregroundStyle(Palette.muted).lineSpacing(4)
            HStack(spacing: 14) {
                Label("\(change.patches.count) \(change.patches.count == 1 ? "file" : "files")", systemImage: "doc")
                Text("+\(change.added)").foregroundStyle(Palette.accent)
                Text("−\(change.removed)").foregroundStyle(.red.opacity(0.8))
                Text("·").foregroundStyle(Palette.muted)
                Text(change.decision.rawValue.capitalized).foregroundStyle(statusColor(change))
            }.font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.muted).padding(.top, 4)
        }.padding(32).frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) { Rectangle().fill(Palette.line).frame(height: 1) }
    }

    private func rationale(_ change: SemanticChange) -> some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: "sparkle").foregroundStyle(Palette.accent).padding(.top, 2)
            VStack(alignment: .leading, spacing: 8) {
                Text("WHY THIS CHANGE").font(.system(size: 9, weight: .bold)).tracking(1.5).foregroundStyle(Palette.accent)
                Text(change.rationale).font(.system(size: 12)).foregroundStyle(Color.white.opacity(0.78)).lineSpacing(5)
            }
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.accent.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.accent.opacity(0.13)))
    }

    private func actions(_ change: SemanticChange) -> some View {
        HStack(spacing: 12) {
            Button { store.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(store.history.isEmpty || store.busyChangeID != nil)
                .keyboardShortcut("z", modifiers: [.command]).help("Undo last decision (⌘Z)")
            Text("Decisions only · files stay untouched").font(.system(size: 10)).foregroundStyle(Palette.muted)
            Spacer(minLength: 8)
            Button { showAgent = true } label: { Label("Ask Agent", systemImage: "sparkle") }
                .keyboardShortcut("k", modifiers: [.command])
            Button { store.decide(.rejected) } label: { Label("Reject", systemImage: "xmark") }
                .keyboardShortcut(.delete, modifiers: [.command]).disabled(change.decision == .rejected || store.busyChangeID != nil)
            Button { store.decide(.accepted) } label: { Label("Accept", systemImage: "checkmark") }
                .buttonStyle(.borderedProminent).tint(Palette.accent).foregroundStyle(Palette.background)
                .keyboardShortcut(.return, modifiers: [.command]).disabled(change.decision == .accepted || store.busyChangeID != nil)
        }.buttonStyle(.bordered).controlSize(.large).padding(22)
            .background(Palette.panel.opacity(0.5))
            .overlay(alignment: .top) { Rectangle().fill(Palette.line).frame(height: 1) }
    }

    private var summary: some View {
        VStack(spacing: 22) {
            Spacer()
            Image(systemName: store.reviewed == store.changes.count ? "checkmark.seal" : "square.stack.3d.up")
                .font(.system(size: 44, weight: .light)).foregroundStyle(Palette.accent)
            Text(store.reviewed == store.changes.count ? "Every change, considered." : "Your review so far.")
                .font(.system(size: 30, weight: .semibold))
            Text("\(store.accepted) accepted    ·    \(store.rejected) rejected    ·    \(store.changes.count - store.reviewed) pending")
                .font(.system(size: 13, design: .monospaced)).foregroundStyle(Palette.muted)
            Text("Export your decisions or revisit any change.\nThis demo does not modify files, run tests, or create commits.")
                .font(.system(size: 13)).foregroundStyle(Palette.muted).multilineTextAlignment(.center).lineSpacing(6)
            HStack(spacing: 12) {
                Button("Undo last decision") { store.undo() }.disabled(store.history.isEmpty)
                Button("Export review…") { exportReport() }.buttonStyle(.borderedProminent)
            }.controlSize(.large).padding(.top, 8)
            Button("Start a fresh demo") { Task { await store.load() } }
                .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Palette.muted).padding(.top, 12)
            Spacer()
        }.frame(maxWidth: .infinity).padding(32)
    }

    private func exportReport() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "hunk-review.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try store.reportData().write(to: url, options: .atomic) }
        catch { exportError = error.localizedDescription }
    }
}

private struct PatchView: View {
    let patch: FilePatch
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "doc.text").foregroundStyle(Palette.muted)
                Text(patch.path).font(.system(size: 11, weight: .medium, design: .monospaced)).textSelection(.enabled)
                Spacer()
                Text("SWIFT").font(.system(size: 8, weight: .medium)).tracking(1).foregroundStyle(Palette.muted)
            }.padding(15).background(Color.white.opacity(0.025))
            Text(patch.symbol).font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.muted)
                .padding(.horizontal, 15).padding(.vertical, 11)
            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(patch.lines) { line in
                        HStack(spacing: 0) {
                            Text(line.oldNumber.map(String.init) ?? "").frame(width: 36, alignment: .trailing)
                            Text(line.newNumber.map(String.init) ?? "").frame(width: 36, alignment: .trailing).padding(.trailing, 12)
                            Text(line.kind.prefix).frame(width: 22).foregroundStyle(lineColor(line))
                            Text(line.text.isEmpty ? " " : line.text).foregroundStyle(lineColor(line)).padding(.trailing, 20)
                            Spacer(minLength: 0)
                        }.font(.system(size: 12, design: .monospaced)).foregroundStyle(Palette.muted.opacity(0.65))
                            .padding(.vertical, 6).frame(minWidth: 640, alignment: .leading)
                            .background(line.kind == .addition ? Palette.accent.opacity(0.075) : line.kind == .deletion ? Color.red.opacity(0.075) : .clear)
                    }
                }.fixedSize(horizontal: true, vertical: false).textSelection(.enabled).padding(.bottom, 12)
            }
        }.background(Palette.panel.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.line))
    }

    private func lineColor(_ line: DiffLine) -> Color {
        line.kind == .addition ? Palette.accent : line.kind == .deletion ? Color(red: 0.91, green: 0.55, blue: 0.56) : Color.white.opacity(0.73)
    }
}

private struct AgentSheet: View {
    @Bindable var store: ReviewStore
    @Environment(\.dismiss) private var dismiss
    @State private var message = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("Ask Agent", systemImage: "sparkle").font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text(store.selected?.title ?? "Change").font(.system(size: 13)).foregroundStyle(Palette.accent)
            Text("Mock conversation · responses are simulated; no code is edited.")
                .font(.system(size: 11)).foregroundStyle(Palette.muted)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let id = store.selectedID {
                        ForEach(store.conversations[id] ?? []) { item in
                            VStack(alignment: .leading, spacing: 7) {
                                Text(item.isUser ? "YOU" : "MOCK AGENT").font(.system(size: 9, weight: .bold)).tracking(1)
                                    .foregroundStyle(item.isUser ? Palette.muted : Palette.accent)
                                Text(item.text).font(.system(size: 13)).lineSpacing(4).textSelection(.enabled)
                            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                                .background(Palette.panel, in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                    if store.busyChangeID != nil { ProgressView("Thinking…").font(.caption) }
                }
            }.frame(minHeight: 180)
            HStack {
                ForEach(["Explain the tradeoffs", "What could go wrong?", "Suggest a simpler approach"], id: \.self) { prompt in
                    Button(prompt) { message = prompt }.font(.system(size: 10))
                }
            }
            TextField("Ask a question or request a revision…", text: $message, axis: .vertical)
                .lineLimit(3...5).textFieldStyle(.plain).padding(12)
                .background(Palette.panel, in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Text("The change stays pending until you decide.").font(.system(size: 11)).foregroundStyle(Palette.muted)
                Spacer()
                Button("Send request") {
                    let text = message; message = ""
                    Task { await store.ask(text) }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.return, modifiers: [.command])
                    .disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.busyChangeID != nil)
            }
        }.padding(26).frame(width: 610, height: 560).background(Palette.background)
    }
}
