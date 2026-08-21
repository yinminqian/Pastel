//
//  pasterApp.swift
//  paster
//
//  Created by yinminqian on 21/8/2026.
//

import SwiftUI
import SwiftData
import Carbon.HIToolbox

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
                         launchAtLogin: delegate.launchAtLogin)
        }

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
            Divider()
            SettingsLink { Text("Settings…") }
            Button("Quit paster") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var container: ModelContainer?
    private var panelController: PanelController?
    private var clipboardMonitor: ClipboardMonitor?
    private var hotKey: HotKeyMonitor?

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

        let hotKey = HotKeyMonitor(keyCode: UInt32(kVK_ANSI_V),
                                   modifiers: UInt32(cmdKey | shiftKey)) {
            MainActor.assumeIsolated { controller.toggle() }
        }
        self.hotKey = hotKey
        permissions.hotKeyConflict = !hotKey.isRegistered

        // Show once at launch, otherwise a fresh install looks like it did
        // nothing at all.
        controller.show()
    }

    @MainActor
    func showPanel() {
        panelController?.show()
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
