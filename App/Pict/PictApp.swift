import AppKit
import PictKit
import SwiftUI

@main
struct PictApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Pict", id: "editor") {
            IconsView(model: appDelegate.model)
                .frame(minWidth: 560, minHeight: 420)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

/// Holds the model across the app's lifetime and receives deep links.
///
/// A regular app rather than a menu-bar agent: Pict is something you open, use and
/// close. The three utilities it serves are all `LSUIElement` agents, which is the
/// right shape for something that is always there — and the wrong shape for an
/// editor you visit twice a year.
final class AppDelegate: NSObject, NSApplicationDelegate {

    let model = IconEditorModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Carry a Zap installation's existing icons across, once, before anything
        // reads the store. Cheap on every later launch: the old directory has been
        // renamed, so this is a `fileExists` and a return.
        ZapManifestImport.run(into: model.store)
        model.start()
    }

    /// Deep links from Zap, Jetty and Top Drawer — `pict://edit?target=…`.
    ///
    /// `application(_:open:)` rather than the Apple-Event handler: this is the
    /// supported route for a URL scheme in an AppKit app and it arrives after
    /// launch as well as with it.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard case .edit(let key)? = PictURL.command(from: url) else { continue }
            model.select(key)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Closing the window quits. There is nothing to keep running — the store is on
    /// disk and the other apps watch it themselves.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
