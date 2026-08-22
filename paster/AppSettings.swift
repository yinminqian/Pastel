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

    private let defaults: UserDefaults

    private enum Key {
        static let isPaused = "is-paused"
        static let historyLimit = "history-limit"
        static let retentionDays = "retention-days"
        static let excludedApps = "user-excluded-apps"
        static let shortcut = "panel-shortcut"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Registered rather than read-with-fallback so `defaults read` shows
        // only what the user actually changed.
        defaults.register(defaults: [
            Key.historyLimit: 500,
            Key.retentionDays: 30,
        ])
        self.isPaused = defaults.bool(forKey: Key.isPaused)
        self.historyLimit = defaults.integer(forKey: Key.historyLimit)
        self.retentionDays = defaults.integer(forKey: Key.retentionDays)
        self.excludedApps = defaults.stringArray(forKey: Key.excludedApps) ?? []
        self.shortcut = (defaults.data(forKey: Key.shortcut)
            .flatMap { try? JSONDecoder().decode(Shortcut.self, from: $0) })
            ?? .commandShiftV
    }

    var maxAge: TimeInterval { TimeInterval(retentionDays) * 24 * 60 * 60 }
}
