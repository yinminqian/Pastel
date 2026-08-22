//
//  ShortcutTests.swift
//  pasterTests
//

import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
@testable import paster

@MainActor
struct ShortcutTests {

    private func keyDown(_ keyCode: UInt16, _ flags: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown,
                         location: .zero,
                         modifierFlags: flags,
                         timestamp: 0,
                         windowNumber: 0,
                         context: nil,
                         characters: "",
                         charactersIgnoringModifiers: "",
                         isARepeat: false,
                         keyCode: keyCode)!
    }

    @Test("The default is Command-Shift-V")
    func defaultShortcut() {
        #expect(Shortcut.commandShiftV.keyCode == UInt32(kVK_ANSI_V))
        #expect(Shortcut.commandShiftV.displayString == "⇧⌘V")
    }

    @Test("An event's modifiers become Carbon bits, not NSEvent bits")
    func modifiersAreTranslated() throws {
        // The two are different sets of bits. Passing an
        // `NSEvent.ModifierFlags` raw value to `RegisterEventHotKey` registers
        // a combination nobody asked for, silently.
        let recorded = try #require(Shortcut(event: keyDown(UInt16(kVK_ANSI_K),
                                                            [.command, .option])))
        #expect(recorded.carbonModifiers == UInt32(cmdKey | optionKey))
        #expect(recorded.carbonModifiers != NSEvent.ModifierFlags([.command, .option]).rawValue)
    }

    @Test("A press with no modifiers is refused")
    func bareKeyIsRefused() {
        // A global hotkey with no modifier would swallow that key from every
        // app on the system.
        #expect(Shortcut(event: keyDown(UInt16(kVK_ANSI_V), [])) == nil)
    }

    @Test("Modifiers that only affect the device are ignored")
    func deviceFlagsAreIgnored() {
        // Caps Lock and the numeric-keypad flag arrive in `modifierFlags` but
        // are not modifiers a shortcut can be built from.
        #expect(Shortcut(event: keyDown(UInt16(kVK_ANSI_V), [.capsLock, .numericPad])) == nil)
    }

    @Test("Modifiers are displayed in Apple's order, not bit order")
    func displayOrder() {
        let all = Shortcut(keyCode: UInt32(kVK_ANSI_A),
                           carbonModifiers: UInt32(cmdKey | shiftKey | optionKey | controlKey))
        #expect(all.displayString == "⌃⌥⇧⌘A")
    }

    @Test("Named keys use their glyph rather than a key code")
    func specialKeyNames() {
        #expect(Shortcut.keyName(for: UInt32(kVK_Space)) == "Space")
        #expect(Shortcut.keyName(for: UInt32(kVK_Return)) == "↩")
        #expect(Shortcut.keyName(for: UInt32(kVK_F5)) == "F5")
    }

    @Test("A letter key is named from the active keyboard layout")
    func letterFromLayout() {
        // Not asserting "V" — that is layout-dependent, which is the whole
        // reason the lookup exists. What must hold is that it produces
        // something printable rather than falling through to "Key 9".
        let name = Shortcut.keyName(for: UInt32(kVK_ANSI_V))
        #expect(!name.isEmpty)
        #expect(!name.hasPrefix("Key "))
    }

    @Test("A shortcut round-trips through its stored form")
    func codableRoundTrip() throws {
        let original = Shortcut(keyCode: 42, carbonModifiers: UInt32(cmdKey | controlKey))
        let decoded = try JSONDecoder().decode(
            Shortcut.self, from: try JSONEncoder().encode(original)
        )
        #expect(decoded == original)
    }

    @Test("A stored shortcut survives a relaunch")
    func settingsPersistShortcut() {
        let suite = "paster.tests.shortcut.persist"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)

        #expect(AppSettings(defaults: defaults).shortcut == .commandShiftV)

        let first = AppSettings(defaults: defaults)
        first.shortcut = Shortcut(keyCode: UInt32(kVK_ANSI_B), carbonModifiers: UInt32(cmdKey))
        #expect(AppSettings(defaults: defaults).shortcut.keyCode == UInt32(kVK_ANSI_B))
    }
}
