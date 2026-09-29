//
//  Shortcut.swift
//  paster
//
//  Created by yinminqian on 22/8/2026.
//

import AppKit
import Carbon.HIToolbox
import SwiftUI

/// A global shortcut, stored as the two things Carbon needs.
///
/// Kept as a key code rather than a character: the same physical key produces
/// different characters on different layouts, and `RegisterEventHotKey` wants
/// the code.
struct Shortcut: Codable, Equatable, Sendable {
    var keyCode: UInt32
    /// A Carbon modifier mask (`cmdKey`, `shiftKey`, `optionKey`, `controlKey`),
    /// not an `NSEvent.ModifierFlags` raw value — the two are different sets of
    /// bits and mixing them silently registers the wrong combination.
    var carbonModifiers: UInt32

    /// Written out because declaring `init?(event:)` below suppresses the
    /// synthesized memberwise initialiser.
    init(keyCode: UInt32, carbonModifiers: UInt32) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
    }

    static let commandShiftV = Shortcut(keyCode: UInt32(kVK_ANSI_V),
                                        carbonModifiers: UInt32(cmdKey | shiftKey))

    // MARK: Conversion

    /// - Returns: `nil` for a press with no modifiers, or for a modifier key on
    ///   its own — a global shortcut without at least one modifier would
    ///   swallow that key from every app on the system.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var mask: UInt32 = 0
        if flags.contains(.command) { mask |= UInt32(cmdKey) }
        if flags.contains(.shift) { mask |= UInt32(shiftKey) }
        if flags.contains(.option) { mask |= UInt32(optionKey) }
        if flags.contains(.control) { mask |= UInt32(controlKey) }
        guard mask != 0 else { return nil }

        self.keyCode = UInt32(event.keyCode)
        self.carbonModifiers = mask
    }

    // MARK: Display

    /// The combination as a person reads it: "⌘⇧V".
    ///
    /// Modifier order follows Apple's convention (control, option, shift,
    /// command) rather than the order the bits happen to be in.
    var displayString: String {
        var text = ""
        if carbonModifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + Self.keyName(for: keyCode)
    }

    /// Names the key, preferring the current keyboard layout so a non-QWERTY
    /// user sees the letter actually printed on their key.
    static func keyName(for keyCode: UInt32) -> String {
        if let special = specialKeyNames[Int(keyCode)] { return special }
        if let translated = layoutCharacter(for: keyCode) { return translated }
        return String(localized: "Key \(keyCode)")
    }

    /// Asks the active keyboard layout what the key produces, unmodified.
    ///
    /// The lookup exists because hardcoding a QWERTY table gets the letter
    /// wrong on every other layout, and the shortcut display is the one place
    /// the user has to recognise their own keyboard.
    private static func layoutCharacter(for keyCode: UInt32) -> String? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?
                .takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }

        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        var deadKeyState: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)

        let status = data.withUnsafeBytes { raw -> OSStatus in
            guard let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress
            else { return OSStatus(paramErr) }
            return UCKeyTranslate(layout,
                                  UInt16(keyCode),
                                  UInt16(kUCKeyActionDisplay),
                                  0,
                                  UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                  &deadKeyState,
                                  characters.count,
                                  &length,
                                  &characters)
        }
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: characters, count: length).uppercased()
    }

    private static let specialKeyNames: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫",
        kVK_ForwardDelete: "⌦", kVK_Escape: "⎋", kVK_LeftArrow: "←",
        kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5",
        kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10",
        kVK_F11: "F11", kVK_F12: "F12",
    ]
}

// MARK: - Recorder

/// A field that captures the next combination the user presses.
///
/// An `NSView` rather than SwiftUI's `onKeyPress`, because recording has to see
/// the raw key code and the modifier flags — including combinations the system
/// would otherwise treat as menu equivalents — and has to see them before any
/// field editor gets a chance to interpret them.
struct ShortcutRecorder: NSViewRepresentable {
    var shortcut: Shortcut
    var onChange: (Shortcut) -> Void
    /// Called with `true` when recording starts and `false` when it ends.
    ///
    /// The caller must release the live registration for that window: Carbon
    /// holds the current combination exclusively, so pressing it here would
    /// summon the panel instead of ever reaching `keyDown`, making the one
    /// combination a user most likely wants to change the one they cannot.
    var onRecordingChange: (Bool) -> Void

    func makeNSView(context: Context) -> RecorderView {
        let view = RecorderView()
        view.onChange = onChange
        view.onRecordingChange = onRecordingChange
        return view
    }

    func updateNSView(_ view: RecorderView, context: Context) {
        view.shortcut = shortcut
        view.onChange = onChange
        view.onRecordingChange = onRecordingChange
        view.needsDisplay = true
    }

    final class RecorderView: NSView {
        var shortcut: Shortcut = .commandShiftV
        var onChange: ((Shortcut) -> Void)?
        var onRecordingChange: ((Bool) -> Void)?
        private var isRecording = false {
            didSet {
                guard isRecording != oldValue else { return }
                onRecordingChange?(isRecording)
            }
        }

        override var acceptsFirstResponder: Bool { true }
        override var intrinsicContentSize: NSSize { NSSize(width: 120, height: 24) }

        override func mouseDown(with event: NSEvent) {
            isRecording = true
            window?.makeFirstResponder(self)
            needsDisplay = true
        }

        override func resignFirstResponder() -> Bool {
            isRecording = false
            needsDisplay = true
            return true
        }

        override func keyDown(with event: NSEvent) {
            guard isRecording else { return super.keyDown(with: event) }

            // Escape abandons the recording rather than binding Escape, which
            // is the one key a user pressing it here certainly does not mean.
            if event.keyCode == UInt16(kVK_Escape), event.modifierFlags
                .intersection(.deviceIndependentFlagsMask).isEmpty {
                isRecording = false
                needsDisplay = true
                return
            }

            guard let recorded = Shortcut(event: event) else {
                // A bare key would be claimed system-wide, so it is refused
                // rather than accepted and quietly broken.
                NSSound.beep()
                return
            }
            shortcut = recorded
            isRecording = false
            needsDisplay = true
            onChange?(recorded)
        }

        /// Swallows the modifier-only presses that arrive while the user is
        /// still assembling a combination, so they do not beep.
        override func flagsChanged(with event: NSEvent) {
            if isRecording { needsDisplay = true } else { super.flagsChanged(with: event) }
        }

        override func draw(_ dirtyRect: NSRect) {
            let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                     xRadius: 5, yRadius: 5)
            // `controlColor`, not `controlBackgroundColor`: this reads as a
            // control you press, and a white field inside a grouped Form row
            // looks like a text field the keyboard cannot type into.
            (isRecording ? NSColor.controlAccentColor.withAlphaComponent(0.12)
                         : NSColor.controlColor).setFill()
            shape.fill()
            (isRecording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
            shape.lineWidth = isRecording ? 2 : 1
            shape.stroke()

            let text = isRecording ? String(localized: "Press keys…") : shortcut.displayString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: isRecording ? NSColor.secondaryLabelColor
                                              : NSColor.labelColor,
            ]
            let size = text.size(withAttributes: attributes)
            text.draw(at: NSPoint(x: bounds.midX - size.width / 2,
                                  y: bounds.midY - size.height / 2),
                      withAttributes: attributes)
        }
    }
}
