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
/// only *observe* the keystroke — the frontmost app still receives it, so the
/// combination would fire this panel and whatever it means in the front app at
/// the same time. `RegisterEventHotKey` claims it exclusively and needs no
/// permission at all.
///
/// Note that claiming a combination takes it away from every other app for as
/// long as this one runs, which is why the user gets to choose which one.
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

    init(onFire: @escaping () -> Void) {
        self.onFire = onFire
    }

    /// Registers `shortcut`, replacing whatever was registered before.
    ///
    /// Tears the old registration down first: Carbon will happily hold two hot
    /// keys at once, and the panel would then still answer to a combination the
    /// user thought they had changed.
    @discardableResult
    func register(_ shortcut: Shortcut) -> OSStatus {
        unregister()

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

        registrationStatus = RegisterEventHotKey(shortcut.keyCode,
                                                 shortcut.carbonModifiers,
                                                 EventHotKeyID(signature: OSType(0x50535452),
                                                               id: 1),
                                                 GetEventDispatcherTarget(),
                                                 0,
                                                 &hotKeyRef)
        return registrationStatus
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
        registrationStatus = noErr
    }

    /// `isolated deinit` because the Carbon handles are not `Sendable` and a
    /// plain nonisolated deinit may run on any thread — releasing an event
    /// handler off the main thread is exactly the kind of thing that works
    /// until it does not.
    isolated deinit {
        unregister()
    }
}
