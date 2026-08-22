//
//  HotKeyBinding.swift
//  paster
//
//  Created by yinminqian on 22/8/2026.
//

import Observation

/// Keeps the stored shortcut, the live Carbon registration and the conflict
/// warning in agreement.
///
/// Exists so no view has to know that changing the shortcut is three steps in a
/// required order. Doing it in a `Toggle`'s setter worked right up until the
/// registration failed, and then the UI showed a shortcut the app did not
/// actually answer to.
@MainActor
@Observable
final class HotKeyBinding {
    private let monitor: HotKeyMonitor
    private let settings: AppSettings
    private let permissions: PermissionsService

    /// True while a recorder is waiting for a key press.
    ///
    /// Observable because the recorder's placeholder text and the surrounding
    /// hint both depend on it, and because the registration has to be released
    /// for exactly that span.
    private(set) var isRecording = false

    var shortcut: Shortcut { settings.shortcut }
    var isDefault: Bool { settings.shortcut == .commandShiftV }

    init(settings: AppSettings,
         permissions: PermissionsService,
         onFire: @escaping () -> Void) {
        self.settings = settings
        self.permissions = permissions
        self.monitor = HotKeyMonitor(onFire: onFire)
    }

    /// Claims the stored combination, or reports that something else owns it.
    func apply() {
        monitor.register(settings.shortcut)
        permissions.hotKeyConflict = monitor.isRegistered
            ? nil
            : settings.shortcut.displayString
    }

    func record(_ shortcut: Shortcut) {
        settings.shortcut = shortcut
        apply()
    }

    func resetToDefault() {
        record(.commandShiftV)
    }

    /// Releases the registration for the duration of a recording.
    ///
    /// Carbon claims a combination exclusively, so while the current one is
    /// registered its key press never reaches the app as a key event — the
    /// panel appears instead. Without this, the shortcut a user is most likely
    /// to want to re-record is the one shortcut they cannot type.
    func setRecording(_ recording: Bool) {
        guard recording != isRecording else { return }
        isRecording = recording
        if recording {
            monitor.unregister()
        } else {
            apply()
        }
    }
}
