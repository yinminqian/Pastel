//
//  pasterApp.swift
//  paster
//
//  Created by yinminqian on 21/8/2026.
//

import SwiftUI
import SwiftData
import Carbon.HIToolbox
import Observation

@main
struct pasterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // The panel itself is an NSPanel owned by AppDelegate — the scene API
        // cannot express a borderless floating window that joins every Space.
        // These two scenes are the parts that genuinely belong to SwiftUI.
        Settings {
            SettingsView(settings: delegate.settings,
                         permissions: delegate.permissions,
                         launchAtLogin: delegate.launchAtLogin,
                         hotKey: delegate.hotKey,
                         mcp: delegate.mcp,
                         onClearHistory: delegate.confirmClearHistory)
        }
        // Otherwise macOS window restoration reopens Settings at every launch
        // just because it was open once — so summoning the panel appears to
        // drag the Settings window along with it. Settings should arrive only
        // when asked for, from the menu bar item.
        .restorationBehavior(.disabled)

        // A menu bar item alongside the Dock icon, not instead of it. It is
        // where pausing belongs: reaching for it must not require summoning the
        // panel first, because the moment you want capture off is the moment
        // before you copy something private.
        MenuBarExtra("paster", systemImage: delegate.settings.isPaused
                     ? "doc.on.clipboard.fill"
                     : "doc.on.clipboard") {
            Button(delegate.settings.isPaused ? "Resume Capture" : "Pause Capture") {
                delegate.settings.isPaused.toggle()
            }
            Divider()
            Button("Show Clipboard") { delegate.showPanel() }
            Button("Clear History…") { delegate.confirmClearHistory() }
            Divider()
            SettingsLink { Text("Settings…") }
            Button("Quit paster") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
    }
}

/// `@Observable` because the scene graph reads `hotKey` and `mcp`, and both are
/// built in `applicationDidFinishLaunching` — after the scenes exist. Without
/// observation SwiftUI reads them once, sees nil, and never looks again: the
/// Shortcut pane stayed on "Still starting up" and the MCP pane showed no
/// address and a disabled Copy button, for the whole life of the process.
@Observable
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var container: ModelContainer?
    private var panelController: PanelController?
    private var clipboardMonitor: ClipboardMonitor?
    /// Also built at launch, for the same reason as `hotKey`.
    private(set) var mcp: MCPService?

    /// Built lazily in `applicationDidFinishLaunching` because firing it needs
    /// the panel controller, which needs the store.
    private(set) var hotKey: HotKeyBinding?

    /// Created here, not inside the view, so each lives exactly once for the
    /// process and its notification observers are registered exactly once.
    let permissions = PermissionsService()
    let launchAtLogin = LaunchAtLogin()
    let settings = AppSettings()

    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let container = makeContainer() else { return }
        self.container = container

        // Before anything reads a payload, so a store written by an older
        // build has its clippings folded into the new shape first.
        PayloadBackfill.run(in: container.mainContext)

        let controller = PanelController(container: container,
                                        permissions: permissions,
                                        launchAtLogin: launchAtLogin)
        panelController = controller

        // Starts before the panel is shown so history accumulates whether or
        // not the user has ever opened the panel.
        let monitor = ClipboardMonitor(context: container.mainContext, settings: settings)
        monitor.start()
        clipboardMonitor = monitor

        let hotKey = HotKeyBinding(settings: settings, permissions: permissions) {
            MainActor.assumeIsolated { controller.toggle() }
        }
        hotKey.apply()
        self.hotKey = hotKey

        // Applied, not started: `apply` is a no-op unless the user has switched
        // the endpoint on, which is how it stays off by default across launches.
        let mcp = MCPService(context: container.mainContext,
                             paste: controller.pasteService,
                             settings: settings)
        mcp.apply()
        self.mcp = mcp

        // Show once at launch, otherwise a fresh install looks like it did
        // nothing at all.
        controller.show()
    }

    @MainActor
    func showPanel() {
        panelController?.show()
    }

    /// Asks, then clears.
    ///
    /// Confirmed rather than undoable: there is nothing to undo a bulk delete
    /// with here, and a clipboard history is exactly the thing someone clears
    /// *because* they want it gone — an undo affordance sitting around
    /// afterwards would defeat the purpose. Pinned clippings are kept, since
    /// they were marked as worth keeping on purpose.
    @MainActor
    func confirmClearHistory() {
        guard let context = container?.mainContext else { return }
        let tally = ClipboardHistory.tally(in: context, keepingPinned: true)
        guard tally.deletable > 0 else {
            NSSound.beep()
            return
        }

        let clippings = "\(tally.deletable.formatted()) clipping"
            + (tally.deletable == 1 ? "" : "s")
        let kept = tally.pinned > 0
            ? ", and \(tally.pinned.formatted()) pinned clipping"
                + (tally.pinned == 1 ? " kept" : "s kept")
            : ""

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Clear clipboard history?"
        alert.informativeText = """
        \(clippings) will be deleted\(kept). The system clipboard is emptied too, \
        so nothing is left to paste.

        This cannot be undone.
        """
        let clear = alert.addButton(withTitle: "Clear History")
        clear.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        // Escape has to reach Cancel, or a dismissing keypress lands on the
        // destructive button.
        alert.buttons.last?.keyEquivalent = "\u{1b}"

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        ClipboardHistory.clear(in: context, keepingPinned: true)
    }

    /// `paster://` deep links, so capture can be driven from a script, a
    /// Shortcut, or a launcher without opening the panel first.
    ///
    /// Pausing is the one that matters: the moment you want capture off is
    /// usually the moment you are about to share a screen, and reaching for a
    /// menu is one step too many. Note that writing the preference directly
    /// with `defaults write` does NOT work on a running app — cfprefsd caches
    /// per process — which is exactly why this exists.
    @MainActor
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "paster" {
            switch url.host?.lowercased() {
            case "pause": settings.isPaused = true
            case "resume": settings.isPaused = false
            case "toggle": settings.isPaused.toggle()
            case "show": showPanel()
            default: break
            }
        }
    }

    /// Clicking the Dock icon reopens the panel.
    ///
    /// This is the entry point that cannot fail. The hotkey can be taken by
    /// another app, and without a second way in the app would be a pasteboard
    /// poller with no reachable UI.
    @MainActor
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows: Bool) -> Bool {
        panelController?.show()
        return true
    }

    // MARK: - Store

    /// Built from the versioned schema rather than a hand-written type list.
    ///
    /// The two had drifted: the container was listing V1's models while the
    /// migration plan targeted a V2 schema with a model the container never
    /// registered, so no migration ran and the new table simply did not exist.
    /// Deriving both from one declaration makes that class of bug impossible.
    private static var schema: Schema {
        Schema(versionedSchema: ClipSchema.self)
    }

    private static var storeURL: URL {
        URL.applicationSupportDirectory.appending(path: "default.store")
    }

    @MainActor
    private func makeContainer() -> ModelContainer? {
        do {
            return try ModelContainer(for: Self.schema)
        } catch {
            return recoverFromStoreFailure(error)
        }
    }

    /// Surfaces the failure and *offers* to set the store aside.
    ///
    /// Deliberately never resets automatically: the most likely cause of a
    /// failed open is a migration going wrong, which is precisely when silently
    /// discarding the store would destroy history the user cannot recover. The
    /// old file is moved, never deleted, for the same reason.
    @MainActor
    private func recoverFromStoreFailure(_ error: Error) -> ModelContainer? {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Could not open the clipboard store"
        alert.informativeText = """
        \(error.localizedDescription)

        \(Self.storeURL.path)
        """
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Move Store Aside and Retry")

        guard alert.runModal() == .alertSecondButtonReturn else {
            NSApp.terminate(nil)
            return nil
        }

        let stamp = Int(Date().timeIntervalSince1970)
        let base = Self.storeURL
        // The -wal and -shm siblings have to move too, or SQLite reopens the
        // journal of a store that is no longer there.
        for suffix in ["", "-wal", "-shm"] {
            let source = URL(fileURLWithPath: base.path + suffix)
            let destination = URL(fileURLWithPath: source.path + ".moved-\(stamp)")
            try? FileManager.default.moveItem(at: source, to: destination)
        }

        do {
            return try ModelContainer(for: Self.schema)
        } catch {
            let failure = NSAlert()
            failure.alertStyle = .critical
            failure.messageText = "Still could not open a clipboard store"
            failure.informativeText = error.localizedDescription
            failure.runModal()
            NSApp.terminate(nil)
            return nil
        }
    }
}
