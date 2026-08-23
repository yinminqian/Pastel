//
//  AppSettings.swift
//  paster
//
//  Created by yinminqian on 21/8/2026.
//

import Foundation
import Observation

/// User-visible settings, backed by `UserDefaults`.
///
/// Values live in defaults rather than in the store so they survive the store
/// being reset, and so they can be inspected and scripted with
/// `defaults read com.minqian.paster`.
@MainActor
@Observable
final class AppSettings {
    /// Stops capture without quitting. The single most important privacy
    /// control in a clipboard manager: there is always something a user is
    /// about to copy that they do not want kept.
    var isPaused: Bool {
        didSet { defaults.set(isPaused, forKey: Key.isPaused) }
    }

    /// Newest N clippings are kept.
    var historyLimit: Int {
        didSet { defaults.set(historyLimit, forKey: Key.historyLimit) }
    }

    /// Nothing older than this is kept, whatever the count.
    var retentionDays: Int {
        didSet { defaults.set(retentionDays, forKey: Key.retentionDays) }
    }

    /// The combination that summons the panel.
    ///
    /// Configurable because every app in this category makes it configurable,
    /// and because the previous fixed default is a poor one to be stuck with:
    /// ⌘⇧V is paste-and-match-style in most editors and the default of two
    /// other clipboard managers, so anyone whose IDE already owns it could not
    /// use the app at all.
    var shortcut: Shortcut {
        didSet {
            guard let data = try? JSONEncoder().encode(shortcut) else { return }
            defaults.set(data, forKey: Key.shortcut)
        }
    }

    /// Bundle-identifier fragments the user never wants captured, on top of the
    /// built-in password-manager list. Additive only — the built-ins are not
    /// removable here, because a setting that can switch off password
    /// protection is a setting that eventually gets switched off by accident.
    var excludedApps: [String] {
        didSet { defaults.set(excludedApps, forKey: Key.excludedApps) }
    }

    /// Whether the panel is hidden from screen sharing, recording and
    /// screenshots.
    ///
    /// **Off** by default, which is a reversal. The panel used to be excluded
    /// unconditionally in release builds, on the reasoning that a window showing
    /// everything you have recently copied is the last thing that should appear
    /// on a shared screen. True, and the cost turned out to be higher than the
    /// benefit: `NSWindow.SharingType.none` blocks *screenshots* too, so nobody
    /// — not the author, not anyone filing a bug — can produce a picture of the
    /// panel. It cost two round trips of "here is a screenshot" / "that
    /// screenshot contains no panel" before the penny dropped. Paste, the app
    /// this one is measured against, does not exclude itself either.
    ///
    /// So it becomes a choice, and the default matches the reference app. The
    /// panel is only on screen while deliberately summoned, which is the narrow
    /// window this was protecting.
    var hidesFromScreenCapture: Bool {
        didSet { defaults.set(hidesFromScreenCapture, forKey: Key.hidesFromScreenCapture) }
    }

    /// Whether the local MCP endpoint runs.
    ///
    /// Off by default, and there is no plan to change that. What it exposes is
    /// every password reset link, address and half-written message the user has
    /// copied recently, so it has to be something they chose.
    var mcpEnabled: Bool {
        didSet { defaults.set(mcpEnabled, forKey: Key.mcpEnabled) }
    }

    /// Configurable because a fixed port is a port some other tool already has,
    /// and the failure mode is a server that silently does not start.
    var mcpPort: Int {
        didSet { defaults.set(mcpPort, forKey: Key.mcpPort) }
    }

    /// The bearer token the endpoint requires.
    ///
    /// In defaults rather than the Keychain, and the trade-off is deliberate:
    /// any process running as this user can read the preferences file, so the
    /// token defends against a web page reaching loopback and against other
    /// users on the machine, not against local code already running as you.
    /// The Keychain would raise that bar; it would also mean an authorisation
    /// prompt on the path that starts the server, which is a poor trade for a
    /// feature that is off by default and loopback-only. Stated here so nobody
    /// has to guess what it is worth.
    var mcpToken: String {
        didSet { defaults.set(mcpToken, forKey: Key.mcpToken) }
    }

    private let defaults: UserDefaults

    private enum Key {
        static let isPaused = "is-paused"
        static let historyLimit = "history-limit"
        static let retentionDays = "retention-days"
        static let excludedApps = "user-excluded-apps"
        static let shortcut = "panel-shortcut"
        static let hidesFromScreenCapture = "hides-from-screen-capture"
        static let mcpEnabled = "mcp-enabled"
        static let mcpPort = "mcp-port"
        static let mcpToken = "mcp-token"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Registered rather than read-with-fallback so `defaults read` shows
        // only what the user actually changed.
        defaults.register(defaults: [
            Key.historyLimit: 500,
            Key.retentionDays: 30,
            // Not a registered IANA port and not one a development server
            // reaches for, so it is unlikely to collide with something already
            // running. Changeable regardless.
            Key.mcpPort: 4257,
        ])
        self.isPaused = defaults.bool(forKey: Key.isPaused)
        self.historyLimit = defaults.integer(forKey: Key.historyLimit)
        self.retentionDays = defaults.integer(forKey: Key.retentionDays)
        self.excludedApps = defaults.stringArray(forKey: Key.excludedApps) ?? []
        self.hidesFromScreenCapture = defaults.bool(forKey: Key.hidesFromScreenCapture)
        self.mcpEnabled = defaults.bool(forKey: Key.mcpEnabled)
        self.mcpPort = defaults.integer(forKey: Key.mcpPort)
        self.mcpToken = defaults.string(forKey: Key.mcpToken) ?? ""
        self.shortcut = (defaults.data(forKey: Key.shortcut)
            .flatMap { try? JSONDecoder().decode(Shortcut.self, from: $0) })
            ?? .commandShiftV
    }

    var maxAge: TimeInterval { TimeInterval(retentionDays) * 24 * 60 * 60 }
}
