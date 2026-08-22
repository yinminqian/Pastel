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

    var body: some View {
        TabView {
            GeneralSettings(settings: settings,
                            permissions: permissions,
                            launchAtLogin: launchAtLogin)
                .tabItem { Label("General", systemImage: "gearshape") }

            PrivacySettings(settings: settings)
                .tabItem { Label("Privacy", systemImage: "hand.raised") }
        }
        .frame(width: 480, height: 340)
    }
}

// MARK: - General

private struct GeneralSettings: View {
    var settings: AppSettings
    var permissions: PermissionsService
    var launchAtLogin: LaunchAtLogin

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
                Text("Both limits apply. Lowering either takes effect on the next copy.")
                    .font(.caption).foregroundStyle(.secondary)
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
