//
//  HotKeyMonitor.swift
//  paster
//
//  Created by yinminqian on 21/8/2026.
//

import AppKit
import Carbon.HIToolbox

/// A single system-wide hotkey, registered through Carbon.
///
/// The alternative, `NSEvent.addGlobalMonitorForEvents(matching: .keyDown)`,
/// was rejected on two counts: it needs Accessibility permission, and it can
/// only *observe* the keystroke — the frontmost app still receives it, so ⌘⇧V
/// would fire this panel and paste-and-match-style at the same time.
/// `RegisterEventHotKey` claims the combination exclusively and needs no
/// permission at all.
///
/// Note that claiming ⌘⇧V does take it away from every other app for as long
/// as this one runs; that combination is paste-and-match-style in most editors.
@MainActor
final class HotKeyMonitor {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private let onFire: () -> Void

    /// `noErr` when the combination is ours. Registration fails with
    /// `eventHotKeyExistsErr` if another app already owns it, and since the
    /// hotkey is a primary way into this app, a silent failure would leave a
    /// pasteboard-polling process with no visible UI at all.
    private(set) var registrationStatus: OSStatus = noErr

    var isRegistered: Bool { hotKeyRef != nil && registrationStatus == noErr }

    /// - Parameters:
    ///   - keyCode: a `kVK_*` virtual key code.
    ///   - modifiers: Carbon modifier mask, e.g. `cmdKey | shiftKey`.
    init(keyCode: UInt32, modifiers: UInt32, onFire: @escaping () -> Void) {
        self.onFire = onFire

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        // The Carbon callback is a bare C function pointer and cannot capture,
        // so `self` travels through userData instead.
        let context = Unmanaged.passUnretained(self).toOpaque()

        InstallEventHandler(GetEventDispatcherTarget(), { _, _, userData in
            guard let userData else { return OSStatus(eventNotHandledErr) }
            Unmanaged<HotKeyMonitor>.fromOpaque(userData)
                .takeUnretainedValue()
                .onFire()
            return noErr
        }, 1, &spec, context, &eventHandler)

        registrationStatus = RegisterEventHotKey(keyCode,
                                                modifiers,
                                                EventHotKeyID(signature: OSType(0x50535452), id: 1),
                                                GetEventDispatcherTarget(),
                                                0,
                                                &hotKeyRef)
    }

    /// `isolated deinit` because the Carbon handles are not `Sendable` and a
    /// plain nonisolated deinit may run on any thread — releasing an event
    /// handler off the main thread is exactly the kind of thing that works
    /// until it does not.
    isolated deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }
}
