import SwiftUI
import AppKit

@main
struct HunkApp: App {
    @State private var store = ReviewStore()

    init() { NSApplication.shared.setActivationPolicy(.regular) }

    var body: some Scene {
        WindowGroup {
            ReviewView(store: store)
                .frame(minWidth: 980, minHeight: 680)
                .preferredColorScheme(.dark)
                .task {
                    if store.snapshot == nil { await openInitialSource() }
                    await writeSnapshotIfRequested()
                }
                .onAppear { NSApplication.shared.activate(ignoringOtherApps: true) }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 860)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Repository…") { ReviewView.chooseRepository(store) }.keyboardShortcut("o", modifiers: [.command])
                Button("Open Demo") { Task { await store.openDemo() } }
                Divider()
                Button("Reload Diff") { Task { await store.load() } }.keyboardShortcut("r", modifiers: [.command])
            }
        }
    }

    /// `HUNK_SNAPSHOT=/path.png` saves the window and quits, for docs and visual checks without screen-recording access.
    private func writeSnapshotIfRequested() async {
        guard let path = ProcessInfo.processInfo.environment["HUNK_SNAPSHOT"] else { return }
        if ProcessInfo.processInfo.environment["HUNK_SNAPSHOT_SUMMARY"] != nil {
            store.decide(.accepted); store.decide(.rejected); store.showSummary = true
        }
        try? await Task.sleep(for: .seconds(2))
        if let view = NSApplication.shared.windows.first?.contentView,
           let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
        NSApplication.shared.terminate(nil)
    }

    /// `--repo=<path>` and `--demo` win; otherwise reopen the last repository, falling back to the demo.
    /// A bare path argument can't be used: AppKit treats it as a document to open and suppresses the window.
    private func openInitialSource() async {
        if CommandLine.arguments.contains("--demo") { return await store.openDemo() }
        let requested = CommandLine.arguments.first { $0.hasPrefix("--repo=") }.map { String($0.dropFirst(7)) }
        let saved = UserDefaults.standard.string(forKey: ReviewStore.repositoryKey)
        if let path = (requested ?? saved).map({ ($0 as NSString).expandingTildeInPath }), FileManager.default.fileExists(atPath: path) {
            await store.open(URL(fileURLWithPath: path))
            if !store.isDemo { return }
        }
        await store.load()
    }
}
