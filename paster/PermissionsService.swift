//
//  PermissionsService.swift
//  paster
//
//  Created by yinminqian on 21/8/2026.
//

import AppKit
import Observation

/// Owns the app's two permission questions and the settings deep links.
///
/// TCC grant state is not readable from userland — the TCC database refuses
/// access even read-only — so state has to be inferred from the APIs and
/// re-checked whenever we come back to the foreground, because the user grants
/// it in System Settings, outside our process.
@MainActor
@Observable
final class PermissionsService {
    /// Whether we may synthesise the paste keystroke. Optional by design: the
    /// app is fully usable without it, it just stops at "copied".
    private(set) var canPasteDirectly = false

    /// Whether macOS will let us read the pasteboard without alerting on every
    /// copy. `.ask` is the default and is the state that makes a clipboard
    /// manager unusable, so it needs surfacing.
    private(set) var pasteboardAccess: NSPasteboard.AccessBehavior = .default

    /// Set when the global hotkey could not be registered because another app
    /// already owns the combination. Not a permission, but it lands in the same
    /// "something needs your attention" banner, and a silently dead hotkey on
    /// an app whose window is normally summoned by it is worse than any
    /// permission problem.
    var hotKeyConflict = false

    /// No `deinit` unregistering this. The service is created once in
    /// `AppDelegate` and injected into the panel, so it lives for the process
    /// and never deinitialises. That ownership is the whole justification —
    /// default-initialising it inside the `View` struct instead would register
    /// a fresh observer for every view instance, so it is deliberately not
    /// done that way.
    private var activationObserver: NSObjectProtocol?

    init() {
        refresh()
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func refresh() {
        // Deliberately the non-prompting check. `AXIsProcessTrustedWithOptions`
        // with the prompt option shows Apple's own dialog, which we cannot word
        // or time; asking in our own UI and then deep-linking is clearer.
        canPasteDirectly = AXIsProcessTrusted()
        pasteboardAccess = NSPasteboard.general.accessBehavior
    }

    /// True when the pasteboard pane needs the user's attention. `.default`
    /// counts as fine: the app has not yet tripped an alert, and until it does
    /// it will not even be listed in System Settings.
    var needsPasteboardAttention: Bool {
        pasteboardAccess == .ask || pasteboardAccess == .alwaysDeny
    }

    func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    func openPasteboardSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Pasteboard")
    }

    private func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
