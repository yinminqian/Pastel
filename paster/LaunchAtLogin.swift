//
//  LaunchAtLogin.swift
//  paster
//
//  Created by yinminqian on 21/8/2026.
//

import Observation
import ServiceManagement

/// Launch-at-login through `SMAppService`.
///
/// No bundled login-item helper and no plist in `~/Library/LaunchAgents`:
/// registering the main app is the whole story on macOS 14+. The status is read
/// back from the service rather than mirrored into a preference, because the
/// user can revoke it in System Settings > Login Items and a cached flag would
/// then be lying.
@MainActor
@Observable
final class LaunchAtLogin {
    private(set) var isEnabled = false
    private(set) var lastError: String?

    init() {
        refresh()
    }

    func refresh() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            lastError = nil
        } catch {
            // Surfaced rather than swallowed: registration genuinely fails for
            // unsigned or quarantined builds, and silently reverting the toggle
            // looks like a bug in our UI instead of a signing problem.
            lastError = error.localizedDescription
        }
        refresh()
    }
}
