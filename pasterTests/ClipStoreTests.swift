//
//  ClipStoreTests.swift
//  pasterTests
//

import Foundation
import SQLite3
import Testing
@testable import paster

/// Bringing the history over from the shared `default.store` path.
struct ClipStoreTests {

    private func tempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "paster.tests.store.\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A SQLite file holding just the given table, plus an external-data file.
    private func makeStore(at url: URL, table: String) throws {
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        #expect(sqlite3_exec(db, "CREATE TABLE \(table) (Z_PK INTEGER PRIMARY KEY)", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
        let external = ClipStore.supportDirectory(for: url).appending(path: "_EXTERNAL_DATA", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try Data("png".utf8).write(to: external.appending(path: "blob"))
    }

    @Test func adoptsALegacyStoreThatHoldsClippings() throws {
        let dir = try tempDirectory()
        let legacy = dir.appending(path: "default.store")
        let target = dir.appending(path: "own/paster.store")
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try makeStore(at: legacy, table: "ZCLIPITEM")

        #expect(ClipStore.adoptLegacyStore(from: legacy, to: target))
        #expect(ClipStore.hasClipTable(at: target))
        let blob = ClipStore.supportDirectory(for: target).appending(path: "_EXTERNAL_DATA/blob")
        #expect(FileManager.default.fileExists(atPath: blob.path))
        // Copied, not moved: the legacy file may be another program's by now.
        #expect(FileManager.default.fileExists(atPath: legacy.path))
    }

    /// The failure this guards against: another unsandboxed SwiftData program
    /// rewrote `default.store` to its own schema.
    @Test func ignoresALegacyStoreRewrittenToAnotherSchema() throws {
        let dir = try tempDirectory()
        let legacy = dir.appending(path: "default.store")
        let target = dir.appending(path: "own/paster.store")
        try makeStore(at: legacy, table: "ZAPIREQUESTMODEL")

        #expect(!ClipStore.adoptLegacyStore(from: legacy, to: target))
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }

    @Test func neverOverwritesAnExistingStore() throws {
        let dir = try tempDirectory()
        let legacy = dir.appending(path: "default.store")
        let target = dir.appending(path: "paster.store")
        try makeStore(at: legacy, table: "ZCLIPITEM")
        try makeStore(at: target, table: "ZMINE")

        #expect(!ClipStore.adoptLegacyStore(from: legacy, to: target))
        #expect(!ClipStore.hasClipTable(at: target))
    }
}
