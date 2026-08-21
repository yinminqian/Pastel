//
//  PanelController.swift
//  paster
//
//  Created by yinminqian on 21/8/2026.
//

import AppKit
import SwiftData
import SwiftUI

/// A borderless `NSPanel` can host controls, but only if it is allowed to
/// become key — the default for borderless windows is `false`, which would
/// leave every toggle and stepper in the panel dead.
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }

    var onCancel: (() -> Void)?

    /// Esc, via the responder chain. Overriding it on the window rather than
    /// using SwiftUI's `.onExitCommand` means it fires wherever focus happens
    /// to be inside the panel, instead of only when a view holds focus.
    ///
    /// Note this is deliberately not a `HotKeyMonitor`: Esc registered as a
    /// global hotkey would be taken away from every other app.
    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

/// Owns the floating panel that the global hotkey shows and hides.
///
/// This is deliberately AppKit rather than a SwiftUI `Window` scene: the scene
/// API has no equivalent for `level = .floating`, for `canJoinAllSpaces` (so
/// the panel appears over full-screen apps and on whatever Space is current),
/// or for suppressing the traffic lights outright.
@MainActor
final class PanelController {
    private var panel: NSPanel?
    private let presentation = PanelPresentation()
    private let container: ModelContainer
    private let permissions: PermissionsService
    private let launchAtLogin: LaunchAtLogin
    private let pasteService = PasteService()

    /// Whoever was frontmost before the panel took focus. Captured at show
    /// time because by the time a card is clicked we are frontmost ourselves,
    /// and pasting needs to hand focus back to where the user actually was.
    private(set) var previousApp: NSRunningApplication?

    init(container: ModelContainer,
         permissions: PermissionsService,
         launchAtLogin: LaunchAtLogin) {
        self.container = container
        self.permissions = permissions
        self.launchAtLogin = launchAtLogin
    }

    func toggle() {
        if panel?.isVisible == true { hide() } else { show() }
    }

    func show() {
        let panel = panel ?? makePanel()
        self.panel = panel
        panel.center()
        // Before activating, not after: activation makes us frontmost.
        //
        // Never record ourselves. At launch, and after an Esc that left us
        // frontmost, the frontmost app IS us — storing that would make the
        // paste target this app, and the keystroke would go nowhere while
        // looking like a silent failure. Keeping the previous value (or nil)
        // degrades correctly to "it is on the pasteboard".
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.processIdentifier != NSRunningApplication.current.processIdentifier {
            previousApp = frontmost
        }
        // Commit the pre-animation state before the window is on screen, or it
        // shows one frame at full size before the animation takes over.
        presentation.isVisible = false
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)

        // One runloop hop. Setting the start and end values within a single
        // tick coalesces into one update and no animation runs at all.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
                    self.presentation.isVisible = true
                }
            }
        }
    }

    /// `orderOut` rather than closing: the panel keeps its SwiftUI state, so
    /// reopening is instant and lands you back where you were. It has to wait
    /// for the dismiss animation, otherwise the window vanishes on frame one
    /// and the animation is never seen.
    func hide(then work: (() -> Void)? = nil) {
        guard let panel, panel.isVisible else {
            work?()
            return
        }
        withAnimation(.easeOut(duration: 0.16)) {
            presentation.isVisible = false
        } completion: {
            panel.orderOut(nil)
            // Ordering the panel out is not enough to stop being frontmost —
            // without this the next hotkey press would see us as the previous
            // app, and focus would never return to where the user was.
            NSApp.hide(nil)
            work?()
        }
    }

    /// Dismiss first, then paste. The panel has to be off screen and our app
    /// out of the way before the keystroke goes anywhere, or it lands here
    /// instead of in the app the user was actually using.
    func paste(_ item: ClipItem) {
        let target = previousApp
        hide { [weak self] in
            self?.pasteService.paste(item, into: target)
        }
    }

    private func makePanel() -> NSPanel {
        // The frame carries the visible panel plus a transparent margin on
        // every side for the SwiftUI shadow to fall into.
        let margin = PanelMetrics.windowMargin * 2
        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 1100 + margin, height: 780 + margin),
            // No `.titled`, so there are no traffic lights to hide.
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        // Without these the window paints an opaque background and the glass
        // has nothing to see through to.
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // AppKit infers this shadow from the window's alpha and gets a
        // rectangle; `GlassBackdrop` casts a correctly rounded one instead.
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.animationBehavior = .utilityWindow
        // Excluded from screen sharing, recording and screenshots. A window
        // whose entire purpose is showing everything the user has recently
        // copied is the last thing that should be visible on a shared screen,
        // and the default is to be visible.
        panel.sharingType = .none
        panel.onCancel = { [weak self] in self?.hide() }
        let hosting = NSHostingView(
            rootView: ClipboardPanelView(onClose: { [weak self] in self?.hide() },
                                    onPaste: { [weak self] item in self?.paste(item) },
                                    presentation: presentation,
                                    permissions: permissions,
                                    launchAtLogin: launchAtLogin)
                .modelContainer(container)
        )
        // NSHostingView backs itself with an opaque layer by default, which
        // both squared off the window shadow and would stop the glass seeing
        // through to what is behind the window.
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        hosting.layer?.isOpaque = false
        panel.contentView = hosting
        return panel
    }
}
