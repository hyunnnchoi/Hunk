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
                .task { if store.snapshot == nil { await store.load() } }
                .onAppear { NSApplication.shared.activate(ignoringOtherApps: true) }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 860)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
    }
}
