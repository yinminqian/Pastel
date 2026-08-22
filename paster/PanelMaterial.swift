//
//  PanelMaterial.swift
//  paster
//
//  Created by yinminqian on 21/8/2026.
//

import AppKit
import SwiftUI

/// The panel's background: a **standard** material, not Liquid Glass.
///
/// This is the correction to an inverted hierarchy. Apple's Materials guidance
/// is explicit: "Don't use Liquid Glass in the content layer… including it in
/// the content layer can result in unnecessary complexity and a confusing
/// visual hierarchy. Instead, use standard materials for elements in the
/// content layer, such as app backgrounds." A panel's background *is* the
/// content layer, so glass belongs on the functional chrome floating above it —
/// the search bar and its buttons — and the background gets a standard
/// material.
///
/// Putting glass here was also what forced the cards to be flat: with the
/// backdrop already glass, anything layered on it had to avoid material
/// entirely, which is why the content read as lifeless.
///
/// `.hudWindow` is chosen on semantic grounds rather than for the colour it
/// imparts — the guidance says to pick a material by "semantic meaning and
/// recommended usage" — and a floating summoned panel is what that material is
/// designated for.
struct PanelMaterial: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        // `.behindWindow` is what makes the desktop show through; the panel has
        // no in-app content behind it to blend with.
        view.blendingMode = .behindWindow
        // `.active` keeps the material alive when the panel is not the active
        // app's window — which, for a non-activating panel, is always.
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}
