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
    private let settings: AppSettings
    /// Shared with `MCPService`, which writes to the pasteboard through the
    /// same path so the own-source marker is always stamped the same way.
    let pasteService = PasteService()
    private var keyObservers: [NSObjectProtocol] = []

    /// Guards the resign-key dismissal so a paste, which deliberately hands key
    /// status to the target app, does not race the hide it has already started.
    private var dismissesOnResignKey = true

    /// Whoever was frontmost before the panel took focus. Captured at show
    /// time because by the time a card is clicked we are frontmost ourselves,
    /// and pasting needs to hand focus back to where the user actually was.
    private(set) var previousApp: NSRunningApplication?

    init(container: ModelContainer,
         permissions: PermissionsService,
         launchAtLogin: LaunchAtLogin,
         settings: AppSettings) {
        self.container = container
        self.permissions = permissions
        self.launchAtLogin = launchAtLogin
        self.settings = settings
    }

    /// Applied on creation and again whenever the setting changes, so the
    /// switch takes effect without relaunching.
    func applySharingType() {
        panel?.sharingType = settings.hidesFromScreenCapture ? .none : .readOnly
    }

    func toggle() {
        if panel?.isVisible == true { hide() } else { show() }
    }

    func show() {
        let panel = panel ?? makePanel()
        self.panel = panel
        panel.center()
        // Never record ourselves. Even without activation this stays a real
        // case — the panel can be summoned while our own Settings window is
        // frontmost — and storing it would make the paste target this app, so
        // the keystroke would go nowhere while looking like a silent failure.
        // Keeping the previous value (or nil) degrades correctly to "it is on
        // the pasteboard".
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.processIdentifier != NSRunningApplication.current.processIdentifier {
            previousApp = frontmost
        }
        // Commit the pre-animation state before the window is on screen, or it
        // shows one frame at full size before the animation takes over.
        presentation.isVisible = false
        // Deliberately no `NSApp.activate()`. See the style mask: activating is
        // exactly what would leave a full-screen Space.
        panel.makeKeyAndOrderFront(nil)

        // One runloop hop. Setting the start and end values within a single
        // tick coalesces into one update and no animation runs at all.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                withAnimation(PanelMetrics.appearAnimation) {
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
        withAnimation(PanelMetrics.dismissAnimation) {
            presentation.isVisible = false
        } completion: {
            panel.orderOut(nil)
            // No `NSApp.hide(nil)` any more: we never activated, so there is
            // nothing to hide, and hiding an inactive app would only risk
            // pulling focus around on the way out.
            work?()
        }
    }

    /// Dismiss first, then paste. The panel has to be off screen and our app
    /// out of the way before the keystroke goes anywhere, or it lands here
    /// instead of in the app the user was actually using.
    func paste(_ item: ClipItem, plainTextOnly: Bool = false) {
        let target = previousApp
        // The paste is about to give key status away on purpose.
        dismissesOnResignKey = false
        hide { [weak self] in
            self?.dismissesOnResignKey = true
            self?.pasteService.paste(item, into: target, plainTextOnly: plainTextOnly)
        }
    }

    private func makePanel() -> NSPanel {
        // The frame carries the visible panel plus a transparent margin on
        // every side for the SwiftUI shadow to fall into. Both numbers come
        // from `PanelMetrics` — they used to be duplicated here and in the
        // view's `.frame`, in a type whose comment claims they cannot drift.
        let margin = PanelMetrics.windowMargin * 2
        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0,
                                width: PanelMetrics.panelSize.width + margin,
                                height: PanelMetrics.panelSize.height + margin),
            // `.nonactivatingPanel` is what makes this work over a full-screen
            // app. Activating a regular, Dock-icon application pulls the user
            // out of the full-screen Space to wherever our app lives —
            // `canJoinAllSpaces` alone cannot prevent that, because the Space
            // switch comes from the activation, not from the window. A
            // non-activating panel takes keyboard input without its owner ever
            // becoming the active app, so the current Space stays put.
            //
            // No `.titled`, so there are no traffic lights to hide.
            styleMask: [.borderless, .nonactivatingPanel],
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
        // `.fullScreenAuxiliary` lets the panel sit over a full-screen app
        // rather than being pushed to its own Space; `.canJoinAllSpaces` means
        // whichever Space is current is the one it appears on. Both are needed,
        // and neither is sufficient without the non-activating style mask.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // Without this the panel disappears the moment anything else takes
        // focus, which for a panel that never activates is immediately.
        panel.hidesOnDeactivate = false

        // Key status drives the selection's emphasis. Observed here rather than
        // read from SwiftUI's `\.appearsActive`, because whether that tracks a
        // non-activating panel is not something to leave to chance in the one
        // place a Mac app is most obviously judged.
        let center = NotificationCenter.default
        keyObservers = [
            center.addObserver(forName: NSWindow.didBecomeKeyNotification,
                               object: panel, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.presentation.isKeyWindow = true }
            },
            center.addObserver(forName: NSWindow.didResignKeyNotification,
                               object: panel, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.presentation.isKeyWindow = false
                    // Losing key status *is* the click-outside gesture: the
                    // panel never activates the app, so nothing else can take
                    // key from it except the user going somewhere else. A
                    // one-shot panel that lingers after you have moved on is
                    // clutter, and this is how Spotlight behaves.
                    //
                    // Preferred over a global mouse monitor: no extra event
                    // stream, and it also covers dismissal by keyboard or by
                    // another app activating itself.
                    if self.dismissesOnResignKey { self.hide() }
                }
            },
        ]
        panel.isMovableByWindowBackground = true
        panel.animationBehavior = .utilityWindow
        // The user's choice, not the build configuration. This was `#if DEBUG`
        // with release builds hard-excluded from capture, and `.none` blocks
        // *screenshots* as well as screen sharing — so nobody running a release
        // build could produce a picture of the panel, which makes a visual bug
        // impossible to report. See `AppSettings.hidesFromScreenCapture`.
        applySharingType()
        panel.onCancel = { [weak self] in self?.hide() }
        let hosting = NSHostingView(
            rootView: ClipboardPanelView(onClose: { [weak self] in self?.hide() },
                                    onPaste: { [weak self] item, plainOnly in
                                        self?.paste(item, plainTextOnly: plainOnly)
                                    },
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
