//
//  SettingsView.swift
//  paster
//
//  Created by yinminqian on 21/8/2026.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    var settings: AppSettings
    var permissions: PermissionsService
    var launchAtLogin: LaunchAtLogin
    /// Optional because the binding needs the store, which is opened after the
    /// scene graph is built. In practice it is always there by the time a
    /// window appears; the pane says so plainly if it is not.
    var hotKey: HotKeyBinding?
    var mcp: MCPService?
    var onClearHistory: () -> Void = {}
    var onSharingChange: () -> Void = {}
    var onTryStyle: () -> Void = {}

    var body: some View {
        TabView {
            GeneralSettings(settings: settings,
                            permissions: permissions,
                            launchAtLogin: launchAtLogin,
                            onClearHistory: onClearHistory)
                .tabItem { Label("General", systemImage: "gearshape") }

            StyleSettings(settings: settings, onTry: onTryStyle)
                .frame(height: 440)
                .tabItem { Label("Style", systemImage: "paintbrush") }

            ShortcutSettings(permissions: permissions, hotKey: hotKey)
                .tabItem { Label("Shortcut", systemImage: "command") }

            PrivacySettings(settings: settings, onSharingChange: onSharingChange)
                .tabItem { Label("Privacy", systemImage: "hand.raised") }

            MCPSettings(settings: settings, mcp: mcp)
                .tabItem { Label("MCP", systemImage: "sparkles") }
        }
        // Resizable, in both directions, on request. Apple's settings guidance
        // leaves a settings window at its pane's size ("people don't need to
        // expand the window to see more"), but the panes are grouped `Form`s,
        // which scroll, so a taller window simply shows more of them at once.
        // The minimum is what the widest row needs; the ideal is the size it
        // opens at.
        // Capped as well: the window restores whatever size it last had, and
        // a settings window spread across half the screen reads as oversized.
        // Width only: each pane states its own height, and the window takes
        // it as the tab changes, the way a Mac settings window does.
        .frame(minWidth: 540, idealWidth: 620, maxWidth: 720)
    }
}

// MARK: - Shortcut

private struct ShortcutSettings: View {
    var permissions: PermissionsService
    var hotKey: HotKeyBinding?

    var body: some View {
        Form {
            Section("Show Clipboard") {
                if let hotKey {
                    LabeledContent("Shortcut") {
                        HStack(spacing: 8) {
                            ShortcutRecorder(
                                shortcut: hotKey.shortcut,
                                onChange: { hotKey.record($0) },
                                onRecordingChange: { hotKey.setRecording($0) }
                            )
                            .fixedSize()
                            Button("Restore Default") { hotKey.resetToDefault() }
                                .disabled(hotKey.isDefault)
                        }
                    }
                    Text(hotKey.isRecording
                         ? String(localized: "Hold at least one modifier, then press a key. Escape cancels.")
                         : String(localized: "Click the field, then press the combination you want."))
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Still starting up.").foregroundStyle(.secondary)
                }
            }

            if let taken = permissions.hotKeyConflict {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(taken) is already taken")
                            // Named because there is no API to ask which app
                            // holds a Carbon hotkey — only whether the claim
                            // succeeded — so the app cannot be more specific
                            // than this, and pretending otherwise would send
                            // the user looking for a name that is a guess.
                            Text("Another app claimed it first. Pick a different combination above.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }

            Section {
                Text("The shortcut works everywhere, including over full-screen apps. While it is held by this app no other app receives it, which is why it is worth choosing one nothing else uses.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        // A short pane starts at the top instead of floating mid-window.
        .defaultScrollAnchor(.top)
        .frame(height: 200)
    }
}

// MARK: - General

private struct GeneralSettings: View {
    var settings: AppSettings
    var permissions: PermissionsService
    var launchAtLogin: LaunchAtLogin
    var onClearHistory: () -> Void

    var body: some View {
        Form {
            // Titled, not a bare leading Section: an untitled group renders its
            // own edge directly under the tab bar's divider, which reads as a
            // second rule with an empty band between them.
            LanguageSection()

            Section("Startup") {
                Toggle("Launch at login", isOn: Binding(
                    get: { launchAtLogin.isEnabled },
                    set: { launchAtLogin.setEnabled($0) }
                ))
                if let error = launchAtLogin.lastError {
                    Text(error).font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("History") {
                Stepper("Keep the newest \(settings.historyLimit) clippings",
                        value: Binding(get: { settings.historyLimit },
                                       set: { settings.historyLimit = $0 }),
                        in: 50...5000,
                        step: 50)
                Stepper("Discard anything older than \(settings.retentionDays) days",
                        value: Binding(get: { settings.retentionDays },
                                       set: { settings.retentionDays = $0 }),
                        in: 1...365,
                        step: 1)
                Text("Both limits apply. Lowering either takes effect on the next copy. Pinned clippings are exempt from both.")
                    .font(.caption).foregroundStyle(.secondary)

                LabeledContent("Delete everything now") {
                    Button("Clear History…", action: onClearHistory)
                }
            }

            Section("Permissions") {
                LabeledContent("Paste directly into other apps") {
                    if permissions.canPasteDirectly {
                        Label("Granted", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Button("Grant Accessibility…") {
                            permissions.openAccessibilitySettings()
                        }
                    }
                }
                LabeledContent("Read the clipboard") {
                    Button("Open Settings…") { permissions.openPasteboardSettings() }
                }
            }
        }
        .formStyle(.grouped)
        // A short pane starts at the top instead of floating mid-window.
        .defaultScrollAnchor(.top)
        .frame(height: 520)
    }
}

// MARK: - Privacy

private struct PrivacySettings: View {
    var settings: AppSettings
    var onSharingChange: () -> Void
    @State private var selection: String?
    @FocusState private var listFocused: Bool

    var body: some View {
        Form {
            Section("Always ignored") {
                Label("Content apps mark as confidential", systemImage: "lock.fill")
                Label("Content apps mark as transient", systemImage: "clock.arrow.circlepath")
                Label("Known password managers", systemImage: "key.fill")
                // Deliberately not toggles. These protect against storing
                // secrets, and a switch that turns that off is a switch that
                // eventually gets turned off by accident.
                Text("These cannot be turned off.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Screen sharing") {
                Toggle("Hide the panel from screen sharing and screenshots",
                       isOn: Binding(get: { settings.hidesFromScreenCapture },
                                     set: { settings.hidesFromScreenCapture = $0
                                            onSharingChange() }))
                // Stated because the cost is not obvious: the same flag that
                // hides the panel from a shared screen also hides it from the
                // user's own screenshots, which is how a visual bug becomes
                // impossible to report.
                Text("Off by default. Turning it on also removes the panel from your own screenshots and recordings.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Never capture from these apps") {
                if settings.excludedApps.isEmpty {
                    Text("No apps added.").foregroundStyle(.secondary)
                } else {
                    List(selection: $selection) {
                        ForEach(settings.excludedApps, id: \.self) { identifier in
                            Text(identifier).tag(identifier)
                        }
                    }
                    .frame(height: 90)
                    .focused($listFocused)
                }

                HStack {
                    Button("Add App…", action: addApp)
                    Button("Remove", action: removeSelected)
                        .disabled(selection == nil)
                    Spacer()
                }
                Text("Matched as a fragment of the bundle identifier, so one entry covers an app's variants.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        // A short pane starts at the top instead of floating mid-window.
        // The app list below takes focus when the pane opens, and the form
        // scrolled down to it, hiding the first heading under the toolbar.
        .defaultScrollAnchor(.top)
        .defaultFocus($listFocused, false)
        .frame(height: 480)
    }

    /// Picks a real app and stores its bundle identifier, rather than asking
    /// the user to type one correctly.
    private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }

        let identifiers = panel.urls.compactMap { Bundle(url: $0)?.bundleIdentifier }
        var updated = settings.excludedApps
        for identifier in identifiers where !updated.contains(identifier) {
            updated.append(identifier)
        }
        settings.excludedApps = updated
    }

    private func removeSelected() {
        guard let selection else { return }
        settings.excludedApps.removeAll { $0 == selection }
        self.selection = nil
    }
}

// MARK: - MCP

/// The switch, and everything needed to point a client at the endpoint.
///
/// Written as one screen on purpose: a local server whose port, token and
/// address live in three different places is a local server people give up on
/// and leave running.
private struct MCPSettings: View {
    var settings: AppSettings
    var mcp: MCPService?

    @State private var revealToken = false
    @State private var copied = false

    var body: some View {
        Form {
            Section("Model Context Protocol") {
                Toggle("Let AI tools read the clipboard", isOn: Binding(
                    get: { settings.mcpEnabled },
                    set: { enable($0) }
                ))
                // Stated at the switch rather than buried in a footnote. Anyone
                // deciding whether to turn this on is deciding exactly this.
                Text("Off by default. While it is on, any program on this Mac that has the access token below can read every clipping in your history — including anything you copied from a page you were logged into.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if settings.mcpEnabled {
                Section("Endpoint") {
                    LabeledContent("Address") {
                        Text(mcp?.endpointURL ?? "—")
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                    }
                    // Built as a plain String so the number is not grouped: a
                    // port is an identifier, and "Port 4,258" reads as a
                    // quantity of something.
                    Stepper("Port " + String(settings.mcpPort),
                            value: Binding(get: { settings.mcpPort },
                                           set: { settings.mcpPort = $0; mcp?.apply() }),
                            in: 1024...65535)
                    LabeledContent("Status") { statusLabel }
                }

                Section("Access token") {
                    LabeledContent("Token") {
                        HStack(spacing: 6) {
                            // Hidden by default: this pane is the kind of thing
                            // that ends up in a screen share.
                            Text(revealToken ? settings.mcpToken : "••••••••••••••••")
                                .font(.caption.monospaced())
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                            Button(revealToken ? String(localized: "Hide") : String(localized: "Reveal")) { revealToken.toggle() }
                                .controlSize(.small)
                        }
                    }
                    HStack {
                        Button(copied ? String(localized: "Copied") : String(localized: "Copy Setup Command")) { copyCommand() }
                            .disabled(mcp == nil)
                        Button("Regenerate") {
                            mcp?.regenerateToken()
                            revealToken = false
                        }
                        Spacer()
                    }
                    Text("Regenerating stops every client that has the old token until it is given the new one.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("Tools") {
                    // Named so the switch is not a blank cheque: someone
                    // deciding whether to enable this can see the whole surface.
                    Label("search_clipboard — find clippings by text", systemImage: "magnifyingglass")
                    Label("get_recent_items — list the newest clippings", systemImage: "clock")
                    Label("read_clipboard_item — read one in full", systemImage: "doc.text")
                    Label("copy_to_clipboard — put something on the clipboard", systemImage: "doc.on.clipboard")
                    Text("Nothing is ever pasted into an app on a model's behalf, and image and file bytes are never sent.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        // A short pane starts at the top instead of floating mid-window.
        .defaultScrollAnchor(.top)
        // Two heights, because switching the endpoint on reveals three more
        // sections. A single height sized for the long form leaves the switch
        // floating in an empty window, which reads as a pane that failed to
        // load rather than one with a single control.
        .frame(height: settings.mcpEnabled ? 700 : 200)
    }

    @ViewBuilder
    private var statusLabel: some View {
        if let failure = mcp?.failure {
            // The usual cause is the port already being taken, and a server the
            // user switched on that is not running has to say so here rather
            // than in some client's error message later.
            Label(failure, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.caption)
        } else if mcp?.isRunning == true {
            Label("Listening on this Mac only", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
        } else {
            Text("Not running").font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Turning it on mints a token if there is not one yet, so the switch alone
    /// leaves a working, authenticated endpoint rather than one that refuses
    /// every request for a reason the user cannot see.
    private func enable(_ on: Bool) {
        if on, settings.mcpToken.isEmpty {
            settings.mcpToken = MCPService.generateToken()
        }
        settings.mcpEnabled = on
        mcp?.apply()
    }

    private func copyCommand() {
        guard let mcp else { return }
        // Through the service, not straight to the pasteboard: the command
        // contains the bearer token, and an unstamped write would be captured
        // and stored as a searchable plain-text copy of the credential.
        mcp.copySetupCommand()
        copied = true
    }
}

// MARK: - Language

/// The app's own language, which can differ from the system's.
///
/// Stored the way macOS stores a per-app language — `AppleLanguages` in the
/// app's defaults, the same key System Settings › Language & Region › Apps
/// writes — so the two stay in step. It is read at launch, hence the restart.
private struct LanguageSection: View {
    /// An empty string follows the system.
    @State private var chosen = LanguageSection.current
    private let atLaunch = LanguageSection.current

    private static let options: [(code: String, name: String)] = [
        ("en", "English"), ("zh-Hans", "简体中文"), ("ja", "日本語"), ("ko", "한국어"),
    ]

    private static var current: String {
        let domain = Bundle.main.bundleIdentifier.flatMap { UserDefaults.standard.persistentDomain(forName: $0) }
        return (domain?["AppleLanguages"] as? [String])?.first ?? ""
    }

    var body: some View {
        Section("Language") {
            Picker("Language", selection: $chosen) {
                Text("Same as System").tag("")
                Divider()
                // Each in its own language, so it can be found by someone who
                // cannot read the current one.
                ForEach(Self.options, id: \.code) { option in
                    Text(verbatim: option.name).tag(option.code)
                }
            }
            .onChange(of: chosen) { _, code in
                if code.isEmpty {
                    UserDefaults.standard.removeObject(forKey: "AppleLanguages")
                } else {
                    UserDefaults.standard.set([code], forKey: "AppleLanguages")
                }
            }
            if chosen != atLaunch {
                LabeledContent {
                    Button("Restart Now", action: Self.relaunch)
                        .buttonStyle(.glassProminent)
                        .tint(PanelPalette.accent)
                } label: {
                    Text("paster needs to restart to change language.")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Quits and opens again. A second copy started while this one is still
    /// running would hand over to it and quit, so the reopen waits a moment.
    private static func relaunch() {
        let path = Bundle.main.bundleURL.path
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.8; /usr/bin/open \"$0\"", path]
        try? task.run()
        NSApp.terminate(nil)
    }
}
