//
//  PasteService.swift
//  paster
//
//  Created by yinminqian on 21/8/2026.
//

import AppKit
import Carbon.HIToolbox
import SwiftData

/// Puts a stored clipping back on the pasteboard and, when allowed, pastes it
/// into whatever the user was doing before the panel opened.
///
/// The keystroke route is deliberate: synthesising Cmd-V via `CGEvent` leaves
/// the destination app to interpret the paste with its own logic, whereas
/// writing directly to the focused element's accessibility value bypasses that
/// and breaks undo, formatting and validation. Inspecting Paste.app confirmed
/// it takes the same route.
@MainActor
final class PasteService {
    /// Writes the clipping, then attempts the keystroke. Callers get the
    /// graceful degradation for free: if the keystroke cannot be delivered the
    /// content is already on the pasteboard, so the user just presses Cmd-V —
    /// which is exactly the "no focused field" fallback, with no need to
    /// inspect the focused element at all.
    /// - Parameter plainTextOnly: strips every flavour except plain text.
    ///   Wanted often enough to be a first-class option: pasting a styled
    ///   fragment into a document usually drags the source's fonts and colours
    ///   along with it.
    func paste(_ item: ClipItem,
               into target: NSRunningApplication?,
               plainTextOnly: Bool = false) {
        write(item, plainTextOnly: plainTextOnly)
        // Pasting a clipping moves it to the front, as copying it again would:
        // the row is newest-first, and what you just used is what you are
        // likeliest to want next. The same rule `ClipboardMonitor` applies to a
        // repeat copy — which this paste itself will not register as, because
        // the write carries the own-source marker.
        let now = Date()
        item.copiedAt = now
        item.lastPastedAt = now
        // Explicit, like every other user-driven change: autosave timing is
        // unpredictable, and the move should survive a quit right after.
        try? item.modelContext?.save()

        guard AXIsProcessTrusted(), let target, !target.isTerminated else { return }
        activate(target) { [weak self] in self?.postCommandV() }
    }

    /// Puts a clipping on the pasteboard and stops there.
    ///
    /// Separate from `paste` because the MCP tools must not synthesise a
    /// keystroke: an agent copying something has no idea which app is frontmost
    /// or whether a text field has focus, and typing into a document the user is
    /// not looking at is not a thing to do on a model's behalf.
    func copy(_ item: ClipItem, plainTextOnly: Bool = false) {
        write(item, plainTextOnly: plainTextOnly)
    }

    /// Puts literal text on the pasteboard, stamped as our own write.
    ///
    /// Stamped so the poller does not record it: an agent's own output showing
    /// up in the history attributed to whatever app happened to be frontmost
    /// would be a wrong answer to "where did this come from".
    func copy(text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let entry = NSPasteboardItem()
        entry.setString(text, forType: .string)
        entry.setString(ClipboardMonitor.ownSourceMarker, forType: ClipboardMonitor.sourceType)
        pasteboard.writeObjects([entry])
    }

    private var activationObserver: NSObjectProtocol?
    private var pendingPaste: (() -> Void)?
    private var pendingTarget: pid_t?

    /// Whether the keystroke half can work at all. Posting events into another
    /// app is gated on Accessibility trust; without it this degrades to a copy.
    var canSynthesiseKeystrokes: Bool { AXIsProcessTrusted() }

    // MARK: - Pasteboard

    private func write(_ item: ClipItem, plainTextOnly: Bool) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        // Every representation onto a single item, so the destination app picks
        // its own best fit — this is what keeps a rich-text paste rich instead
        // of collapsing it to plain text.
        let entry = NSPasteboardItem()
        let plainText = NSPasteboard.PasteboardType.string.rawValue
        for representation in item.representations
        where !plainTextOnly || representation.typeIdentifier == plainText {
            entry.setData(representation.data,
                          forType: NSPasteboard.PasteboardType(representation.typeIdentifier))
        }
        // Stamp ourselves so ClipboardMonitor recognises this as our own write
        // and does not record it as something the user copied.
        entry.setString(ClipboardMonitor.ownSourceMarker, forType: ClipboardMonitor.sourceType)

        pasteboard.writeObjects([entry])
    }

    // MARK: - Focus handover

    /// Waits for the app to actually become active before typing into it.
    ///
    /// A fixed delay is the usual shortcut here, but it is a race: too short
    /// and the keystroke lands in our own panel, too long and it feels
    /// sluggish. The activation notification is the real signal; the timeout
    /// only exists so an app that never activates cannot leave the observer
    /// registered forever.
    ///
    /// State lives on the instance rather than in captured locals so both
    /// callbacks touch main-actor-isolated storage. Sharing a mutable local
    /// between a notification block and a dispatched block is a data race the
    /// compiler is right to reject, and only one paste is ever in flight
    /// because the panel dismisses first.
    private func activate(_ app: NSRunningApplication, then work: @escaping () -> Void) {
        // Already frontmost: the activation notification will never arrive,
        // so waiting for it would burn the whole timeout and then silently
        // give up.
        if app.isActive {
            work()
            return
        }

        pendingPaste = work
        pendingTarget = app.processIdentifier

        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let activated = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let pid = activated?.processIdentifier
            MainActor.assumeIsolated { self?.activationObserved(pid: pid) }
        }

        app.activate()

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            MainActor.assumeIsolated { self?.finishActivation(run: false) }
        }
    }

    private func activationObserved(pid: pid_t?) {
        guard pid == pendingTarget else { return }
        finishActivation(run: true)
    }

    private func finishActivation(run: Bool) {
        guard let work = pendingPaste else { return }
        pendingPaste = nil
        pendingTarget = nil
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
            self.activationObserver = nil
        }
        if run { work() }
    }

    private func postCommandV() {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        let v = CGKeyCode(kVK_ANSI_V)
        let down = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cgSessionEventTap)
        up?.post(tap: .cgSessionEventTap)
    }
}
