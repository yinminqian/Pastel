//
//  WindowButtons.swift
//  paster
//
//  Created by yinminqian on 22/8/2026.
//

import AppKit
import SwiftUI

/// The real traffic lights, hosted inside the panel's own layout.
///
/// `NSWindow.standardWindowButton(_:for:)` — the *class* method — hands back a
/// fresh standard button that belongs to no window, which is the only way to get
/// the genuine control here. The instance method returns nil on a borderless
/// window, and adding `.titled` to the style mask would put the buttons in the
/// window's titlebar: 70pt out in the shadow margin, visually detached from the
/// panel they would be closing.
///
/// Hand-drawn circles were the alternative and are not worth it. These carry the
/// hover glyphs, the accessibility labels and the exact colours, all of which
/// change between macOS releases.
struct WindowButtons: NSViewRepresentable {
    var onClose: () -> Void

    func makeNSView(context: Context) -> NSStackView {
        var buttons: [NSButton] = []

        if let close = NSWindow.standardWindowButton(.closeButton, for: [.titled, .closable]) {
            close.target = context.coordinator
            close.action = #selector(Coordinator.close)
            buttons.append(close)
        }

        // Disabled rather than hidden. A summoned panel can neither minimise nor
        // zoom, and greyed-out is how macOS states that — the same rendering any
        // window gets for a titlebar control it cannot perform. Hiding them
        // would leave a lone red dot, which is not the pattern.
        for type in [NSWindow.ButtonType.miniaturizeButton, .zoomButton] {
            guard let button = NSWindow.standardWindowButton(
                type, for: [.titled, .closable, .miniaturizable, .resizable]
            ) else { continue }
            button.isEnabled = false
            buttons.append(button)
        }

        let stack = NSStackView(views: buttons)
        stack.orientation = .horizontal
        // The system metric between traffic lights.
        stack.spacing = 6
        stack.alignment = .centerY
        return stack
    }

    func updateNSView(_ view: NSStackView, context: Context) {
        context.coordinator.onClose = onClose
    }

    func makeCoordinator() -> Coordinator { Coordinator(onClose: onClose) }

    final class Coordinator: NSObject {
        var onClose: () -> Void

        init(onClose: @escaping () -> Void) {
            self.onClose = onClose
        }

        /// The button is not attached to a window, so its default action would
        /// go nowhere; the panel's own dismissal is what should happen.
        @objc func close() { onClose() }
    }
}
