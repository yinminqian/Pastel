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
    var onClearHistory: () -> Void = {}

    var body: some View {
        TabView {
            GeneralSettings(settings: settings,
                            permissions: permissions,
                            launchAtLogin: launchAtLogin,
                            onClearHistory: onClearHistory)
                .tabItem { Label("General", systemImage: "gearshape") }

            ShortcutSettings(permissions: permissions, hotKey: hotKey)
                .tabItem { Label("Shortcut", systemImage: "command") }

            PrivacySettings(settings: settings)
                .tabItem { Label("Privacy", systemImage: "hand.raised") }
        }
        .frame(width: 480, height: 340)
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
                         ? "Hold at least one modifier, then press a key. Escape cancels."
                         : "Click the field, then press the combination you want.")
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
    }
}

// MARK: - Privacy

private struct PrivacySettings: View {
    var settings: AppSettings
    @State private var selection: String?

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
