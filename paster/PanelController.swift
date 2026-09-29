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
    /// 1 except in a self-check, which slows the motion down far enough to be
    /// photographed halfway.
    private var animationSpeed: Double = 1
    #if DEBUG
    private let frameProbe = FrameProbe()
    #endif
    /// Watches ⌘ so the cards can show their quick-paste numbers while it is
    /// held. A *local* monitor: it only sees events already coming to this
    /// app, which the key panel's are, and needs no permission.
    private var modifierMonitor: Any?

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
        // The style is taken here and only here, so changing it in Settings
        // never rearranges a panel that is already on screen.
        var style = settings.panelStyle
        #if DEBUG
        style = PanelStyle.launchOverride ?? style
        #endif
        presentation.style = style
        dock(panel, style: style)
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
        presentation.targetAppName = previousApp?.localizedName
        // Commit the pre-animation state before the window is on screen, or it
        // shows one frame at full size before the animation takes over.
        presentation.isVisible = false
        // Deliberately no `NSApp.activate()`. See the style mask: activating is
        // exactly what would leave a full-screen Space.
        panel.makeKeyAndOrderFront(nil)
        #if DEBUG
        if let view = panel.contentView { frameProbe.start(on: view) }
        #endif

        // One runloop hop. Setting the start and end values within a single
        // tick coalesces into one update and no animation runs at all.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                withAnimation(self.presentation.style.appearAnimation.speed(self.animationSpeed)) {
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
        // A ⌘ that was down when the panel went away never sends its release
        // here, and the numbers would greet the next summon.
        presentation.isCommandHeld = false
        withAnimation(presentation.style.dismissAnimation.speed(animationSpeed)) {
            presentation.isVisible = false
        } completion: { [weak self] in
            panel.orderOut(nil)
            #if DEBUG
            self?.frameProbe.stop(rows: StressStore.requestedRows ?? 0)
            #endif
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
        #if DEBUG
        if interceptsPaste {
            let line = "paste: \(item.previewText?.prefix(40) ?? "") plain=\(plainTextOnly)\n"
            FileManager.default.createFile(atPath: "/tmp/paster-check/paste.log", contents: Data(line.utf8))
            hide()
            return
        }
        #endif
        let target = previousApp
        // The paste is about to give key status away on purpose.
        dismissesOnResignKey = false
        hide { [weak self] in
            self?.dismissesOnResignKey = true
            self?.pasteService.paste(item, into: target, plainTextOnly: plainTextOnly)
        }
    }

    /// Along the bottom of the screen the pointer is on, full width.
    /// Recomputed on every show, because that screen changes.
    ///
    /// `frame`, not `visibleFrame`: the panel goes over the Dock rather than
    /// above it — see the window level — so it is the same height wherever the
    /// Dock is and whether or not it is hidden.
    private func dock(_ panel: NSPanel, style: PanelStyle) {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) })
                ?? NSScreen.main
        else { return }
        panel.setFrame(style.windowFrame(on: screen), display: false)
    }

    #if DEBUG
    /// Drives the panel with synthetic events sent to it alone — a fast
    /// sideways fling out and back, then eighty arrow presses each way — and
    /// quits. Nothing is posted system-wide, so no other app sees any of it.
    /// `FrameProbe` logs each session. Launch with `-AutoBench YES`.
    func runAutoBench() async {
        func pause(_ seconds: Double) async {
            try? await Task.sleep(for: .seconds(seconds))
        }
        func key(_ code: UInt16, _ character: Int) {
            guard let panel else { return }
            let characters = String(Character(UnicodeScalar(character)!))
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
                                                timestamp: ProcessInfo.processInfo.systemUptime,
                                                windowNumber: panel.windowNumber, context: nil,
                                                characters: characters,
                                                charactersIgnoringModifiers: characters,
                                                isARepeat: false, keyCode: code) {
                    panel.sendEvent(event)
                }
            }
        }
        let horizontal = presentation.style.arrowAxis.isHorizontal
        func scroll(_ delta: Int32) {
            guard let panel,
                  let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                   wheel1: horizontal ? 0 : delta, wheel2: horizontal ? delta : 0,
                                   wheel3: 0)
            else { return }
            // Global, top-left origin: a point in the middle of the panel.
            let frame = panel.frame
            let screenHeight = NSScreen.screens.first?.frame.height ?? 0
            cg.location = CGPoint(x: frame.midX, y: screenHeight - frame.midY)
            if presentation.style == .basic || presentation.style == .lightStrip {
                cg.location = CGPoint(x: frame.midX, y: screenHeight - frame.minY - 110)
            }
            if let event = NSEvent(cgEvent: cg) { panel.sendEvent(event) }
        }

        // A run that loses key halfway — someone clicking elsewhere — would
        // otherwise hide the panel and cut its session short.
        dismissesOnResignKey = false
        await pause(1)
        hide(); await pause(1.2)

        show(); await pause(1.2)
        for direction: Int32 in [-1, 1] {
            for _ in 0 ..< 240 { scroll(direction * 50); await pause(0.008) }
        }
        await pause(0.5)
        hide(); await pause(1.2)

        show(); await pause(1.2)
        // Tells an outside `sample` run when the arrows begin.
        FileManager.default.createFile(atPath: "/tmp/paster-arrows-start", contents: nil)
        let (forward, back): ((UInt16, Int), (UInt16, Int)) = horizontal
            ? ((124, NSRightArrowFunctionKey), (123, NSLeftArrowFunctionKey))
            : ((125, NSDownArrowFunctionKey), (126, NSUpArrowFunctionKey))
        for _ in 0 ..< 80 { key(forward.0, forward.1); await pause(0.03) }
        for _ in 0 ..< 80 { key(back.0, back.1); await pause(0.03) }
        await pause(0.5)
        hide(); await pause(1.2)

        NSApp.terminate(nil)
    }

    /// Set by `runSelfCheck`: a paste is logged instead of performed, so a
    /// check can click cards without typing fake clippings into a real app.
    private(set) var interceptsPaste = false

    /// Walks the panel through the interactions a rewrite could break, in the
    /// style it was launched with, pausing at each step for an outside
    /// screenshot. Every event is sent to this app alone. Launch with
    /// `-SelfCheck YES` (and `-PanelStyle <style>`); a script watches
    /// `/tmp/paster-check` for `<step>.ready` and answers with `<step>.done`.
    func runSelfCheck() async {
        interceptsPaste = true
        dismissesOnResignKey = false
        let folder = URL(fileURLWithPath: "/tmp/paster-check")
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let style = presentation.style

        func pause(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }
        func checkpoint(_ name: String, settle: Double = 0.6) async {
            await pause(settle)
            let ready = folder.appending(path: "\(name).ready")
            let done = folder.appending(path: "\(name).done")
            // Who holds the keyboard, for when typing seems to go nowhere.
            let responder = panel?.firstResponder.map { String(describing: Swift.type(of: $0)) } ?? "nil"
            FileManager.default.createFile(atPath: folder.appending(path: "\(name).focus").path,
                                           contents: Data(responder.utf8))
            FileManager.default.createFile(atPath: ready.path, contents: nil)
            for _ in 0 ..< 200 where !FileManager.default.fileExists(atPath: done.path) {
                await pause(0.05)
            }
        }
        func send(_ type: NSEvent.EventType, code: UInt16, characters: String = "",
                  flags: NSEvent.ModifierFlags = []) {
            guard let panel,
                  let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
                                               timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: panel.windowNumber, context: nil,
                                               characters: characters,
                                               charactersIgnoringModifiers: characters,
                                               isARepeat: false, keyCode: code)
            else { return }
            // Through the application, so the ⌘ monitor sees it as it would a
            // real keypress.
            NSApp.sendEvent(event)
        }
        func press(_ code: UInt16, _ characters: String) {
            send(.keyDown, code: code, characters: characters)
            send(.keyUp, code: code, characters: characters)
        }
        func type(_ text: String) {
            for character in text { press(0, String(character)) }
        }
        /// The key that moves to the next item in this style.
        func next() {
            switch style.arrowAxis {
            case .vertical: press(125, String(Character(UnicodeScalar(NSDownArrowFunctionKey)!)))
            case .horizontal, .both: press(124, String(Character(UnicodeScalar(NSRightArrowFunctionKey)!)))
            }
        }
        func collectionView(in view: NSView?) -> NSCollectionView? {
            guard let view else { return nil }
            if let found = view as? NSCollectionView { return found }
            for sub in view.subviews { if let found = collectionView(in: sub) { return found } }
            return nil
        }
        /// Clicks the second item of the list, wherever this style put it.
        func clickSecondItem() {
            guard let panel, let collection = collectionView(in: panel.contentView) else { return }
            var path = IndexPath(item: 1, section: 0)
            if collection.numberOfItems(inSection: 0) < 2, collection.numberOfSections > 1 {
                path = IndexPath(item: 0, section: 1)
            }
            guard let frame = collection.layoutAttributesForItem(at: path)?.frame else { return }
            let inWindow = collection.convert(NSPoint(x: frame.midX, y: frame.midY), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let event = NSEvent.mouseEvent(with: type, location: inWindow, modifierFlags: [],
                                                  timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: panel.windowNumber, context: nil,
                                                  eventNumber: 0, clickCount: 1, pressure: 1) {
                    panel.sendEvent(event)
                }
            }
        }
        /// Presses the panel's button whose label starts with `title`, through
        /// the accessibility tree, as VoiceOver would.
        func pressButton(titled title: String) {
            let app = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
            func search(_ element: AXUIElement, depth: Int) -> Bool {
                guard depth < 40 else { return false }
                var role: CFTypeRef?, label: CFTypeRef?, desc: CFTypeRef?
                AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
                AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &label)
                AXUIElementCopyAttributeValue(element, kAXDescriptionAttribute as CFString, &desc)
                let text = ((label as? String) ?? "") + ((desc as? String) ?? "")
                if (role as? String) == kAXButtonRole, text.hasPrefix(title) {
                    AXUIElementPerformAction(element, kAXPressAction as CFString)
                    return true
                }
                var children: CFTypeRef?
                AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
                for child in (children as? [AXUIElement]) ?? [] where search(child, depth: depth + 1) {
                    return true
                }
                return false
            }
            _ = search(app, depth: 0)
        }
        func wheel(lines: Int32) {
            guard let panel, let collection = collectionView(in: panel.contentView),
                  let cg = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
                                   wheel1: lines, wheel2: 0, wheel3: 0)
            else { return }
            // Over the list, in global top-left coordinates.
            let rect = collection.window?.convertToScreen(
                collection.convert(collection.visibleRect, to: nil)) ?? .zero
            let screenHeight = NSScreen.screens.first?.frame.height ?? 0
            cg.location = CGPoint(x: rect.midX, y: screenHeight - rect.midY)
            if let event = NSEvent(cgEvent: cg) { panel.sendEvent(event) }
        }

        await pause(1.5)
        await checkpoint("01-initial")

        for _ in 0 ..< 3 { next() }
        await checkpoint("02-three-next")

        send(.flagsChanged, code: 55, flags: .command)
        await checkpoint("03-command-held")
        send(.flagsChanged, code: 55)

        for _ in 0 ..< 12 { next(); await pause(0.03) }
        await checkpoint("04-fifteen-next-held")

        for _ in 0 ..< 6 { wheel(lines: -3); await pause(0.04) }
        await checkpoint("05-mouse-wheel")

        type("com")
        await checkpoint("06-search")

        press(53, "\u{1b}")
        await checkpoint("07-search-ended")

        type("zzqxw")
        await checkpoint("07b-no-matches")
        press(53, "\u{1b}")
        await pause(0.3)

        // Pin the selection with ⌘P, then look at the pinned clippings only.
        send(.keyDown, code: 35, characters: "p", flags: .command)
        send(.keyUp, code: 35, characters: "p", flags: .command)
        await checkpoint("07c-pinned")
        if style != .basic {
            pressButton(titled: "Pinned")
            await checkpoint("07d-pinned-view")
            pressButton(titled: "All")
            await pause(0.4)
        }
        send(.keyDown, code: 35, characters: "p", flags: .command)
        send(.keyUp, code: 35, characters: "p", flags: .command)
        await pause(0.3)

        clickSecondItem()
        if style == .palette {
            // The first click only selects; the preview shows it.
            await checkpoint("08a-selected-not-pasted")
            clickSecondItem()
        }
        await checkpoint("08-clicked-second-item")

        // Clear History from outside the panel while a card that is about to
        // be deleted is selected — it must neither crash nor keep holding it.
        let context = container.mainContext
        let all = (try? context.fetch(FetchDescriptor<ClipItem>(
            sortBy: [SortDescriptor(\.copiedAt, order: .reverse)]))) ?? []
        for clip in all.dropFirst(4).prefix(2) { clip.isPinned = true }
        try? context.save()
        show(); await pause(1)
        next()
        // No pasteboard: this must not empty the clipboard of whoever is
        // running it.
        ClipboardHistory.clear(in: context, keepingPinned: true, pasteboard: nil)
        await checkpoint("09-after-clear-history")
        hide(); await pause(1)
        show()
        await checkpoint("10-reshown-after-clear")

        // The motion, slowed twelvefold and photographed on the way.
        hide(); await pause(1)
        animationSpeed = 1.0 / 12
        show()
        await checkpoint("11-appearing-early", settle: 0.45)
        await checkpoint("12-appearing-late", settle: 0.6)
        await pause(2)
        hide()
        await checkpoint("13-dismissing", settle: 0.6)
        await pause(2.5)
        animationSpeed = 1

        NSApp.terminate(nil)
    }
    #endif

    private func makePanel() -> NSPanel {
        let panel = KeyablePanel(
            // Placeholder; `dock` sets the real frame on every show.
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: PanelMetrics.windowHeight),
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
        // rectangle; the panel is flat glass and wants none at all.
        panel.hasShadow = false
        // One above the Dock, so the panel covers it instead of sliding up
        // behind it. Menus and tooltips sit higher still,
        // so the context menu and the ⋯ menu still draw on top.
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1)
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
        // Docked, so not draggable; and the slide is the only animation, so
        // AppKit adds none of its own.
        modifierMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            MainActor.assumeIsolated {
                self?.presentation.isCommandHeld = event.modifierFlags.contains(.command)
            }
            return event
        }
        panel.isMovableByWindowBackground = false
        panel.animationBehavior = .none
        // The user's choice, not the build configuration. This was `#if DEBUG`
        // with release builds hard-excluded from capture, and `.none` blocks
        // *screenshots* as well as screen sharing — so nobody running a release
        // build could produce a picture of the panel, which makes a visual bug
        // impossible to report. See `AppSettings.hidesFromScreenCapture`.
        applySharingType()
        panel.onCancel = { [weak self] in
            guard let self else { return }
            if self.presentation.isSearching {
                self.presentation.searchCancellations += 1
            } else {
                self.hide()
            }
        }
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
        // The window's size is `dock`'s to decide. By default the hosting view
        // would impose the SwiftUI content's own size on the window instead.
        hosting.sizingOptions = []
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        hosting.layer?.isOpaque = false
        panel.contentView = hosting
        return panel
    }
}
