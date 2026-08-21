//
//  AppSettingsTests.swift
//  pasterTests
//

import Foundation
import Testing
@testable import paster

@MainActor
struct AppSettingsTests {

    /// A throwaway domain per test, so tests never read or write the real
    /// app's preferences and cannot affect each other.
    private func isolatedDefaults(_ name: String) -> UserDefaults {
        let suite = "paster.tests.\(name)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test("Retention defaults are registered, not left at zero")
    func retentionDefaults() {
        // Zero would mean "prune everything on the next copy".
        let settings = AppSettings(defaults: isolatedDefaults("registered"))
        #expect(settings.historyLimit == 500)
        #expect(settings.retentionDays == 30)
    }

    @Test("Capture starts enabled")
    func startsUnpaused() {
        #expect(AppSettings(defaults: isolatedDefaults("unpaused")).isPaused == false)
    }

    @Test("There are no excluded apps until the user adds one")
    func noExclusionsByDefault() {
        #expect(AppSettings(defaults: isolatedDefaults("noexcl")).excludedApps.isEmpty)
    }

    @Test("Changes persist and are read back by a fresh instance")
    func changesPersist() {
        let defaults = isolatedDefaults("persist")

        let first = AppSettings(defaults: defaults)
        first.isPaused = true
        first.historyLimit = 1200
        first.retentionDays = 7
        first.excludedApps = ["com.example.secret"]

        let second = AppSettings(defaults: defaults)
        #expect(second.isPaused)
        #expect(second.historyLimit == 1200)
        #expect(second.retentionDays == 7)
        #expect(second.excludedApps == ["com.example.secret"])
    }

    @Test("maxAge converts days to seconds")
    func maxAgeConversion() {
        let settings = AppSettings(defaults: isolatedDefaults("maxage"))
        settings.retentionDays = 3
        #expect(settings.maxAge == 3 * 24 * 60 * 60)
    }

    @Test("Pausing and resuming returns to the original state")
    func pauseIsReversible() {
        let settings = AppSettings(defaults: isolatedDefaults("toggle"))
        #expect(!settings.isPaused)
        settings.isPaused = true
        #expect(settings.isPaused)
        settings.isPaused = false
        #expect(!settings.isPaused)
    }
}
