//
//  ClipStore.swift
//  paster
//

import Foundation
import SQLite3
import SwiftData
import os

/// Where the history lives, and how it is saved.
///
/// The store used to be SwiftData's default, `~/Library/Application Support/default.store`.
/// That path is not ours: this app is not sandboxed, so every unsandboxed process
/// that opens a default `ModelContainer` shares the same file. One did, rewrote the
/// file to its own schema, and from then on every save here failed — silently,
/// behind `try?` — while the autosave timer retried it on the main thread forever.
enum ClipStore {
    static let logger = Logger(subsystem: "com.minqian.paster", category: "store")

    static var directory: URL {
        URL.applicationSupportDirectory.appending(path: "com.minqian.paster", directoryHint: .isDirectory)
    }

    static var url: URL {
        directory.appending(path: "paster.store")
    }

    static var legacyURL: URL {
        URL.applicationSupportDirectory.appending(path: "default.store")
    }

    /// Creates the directory, and brings the history over from the legacy
    /// location the first time this build runs.
    ///
    /// Keyed on the directory, not the store file: "Move Store Aside and Retry"
    /// removes the store file, and adopting again then would bring back the
    /// very store that just failed to open.
    static func prepare() throws {
        let firstRun = !FileManager.default.fileExists(atPath: directory.path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if firstRun { adoptLegacyStore(from: legacyURL, to: url) }
    }

    /// Copies — never moves — the legacy store when it is still this app's.
    ///
    /// Copied rather than moved because the file may belong to another program
    /// by now (that is how this went wrong), and taking it away would break that
    /// program instead. Adopted only when it actually holds clippings: a store
    /// rewritten to someone else's schema has nothing of ours to bring.
    @discardableResult
    static func adoptLegacyStore(from legacy: URL, to target: URL) -> Bool {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: target.path),
              fm.fileExists(atPath: legacy.path),
              hasClipTable(at: legacy)
        else { return false }

        do {
            // The -wal holds commits not yet checkpointed into the main file;
            // copying the store without it would roll the history back.
            for suffix in ["", "-wal", "-shm"] {
                let source = URL(fileURLWithPath: legacy.path + suffix)
                guard fm.fileExists(atPath: source.path) else { continue }
                try fm.copyItem(at: source, to: URL(fileURLWithPath: target.path + suffix))
            }
            // Large attributes (`.externalStorage`) live beside the store in a
            // directory named after it.
            let legacySupport = supportDirectory(for: legacy)
            if fm.fileExists(atPath: legacySupport.path) {
                try fm.copyItem(at: legacySupport, to: supportDirectory(for: target))
            }
            logger.notice("adopted legacy store from \(legacy.path, privacy: .public)")
            return true
        } catch {
            // A half-copied store is worse than none: SwiftData would open it as
            // a valid but truncated history. Start empty instead.
            for suffix in ["", "-wal", "-shm"] {
                try? fm.removeItem(at: URL(fileURLWithPath: target.path + suffix))
            }
            try? fm.removeItem(at: supportDirectory(for: target))
            logger.error("could not adopt legacy store: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    static func supportDirectory(for store: URL) -> URL {
        let name = store.deletingPathExtension().lastPathComponent
        return store.deletingLastPathComponent().appending(path: ".\(name)_SUPPORT", directoryHint: .isDirectory)
    }

    /// Whether the SQLite file has the table `ClipItem` maps to.
    static func hasClipTable(at store: URL) -> Bool {
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(store.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return false }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'ZCLIPITEM'"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return false }
        return sqlite3_step(statement) == SQLITE_ROW
    }
}

extension ModelContext {
    /// Saves, or discards the pending changes if the save fails.
    ///
    /// A failed save that is merely ignored leaves its changes in the context,
    /// and every later save carries them again and fails again — one bad
    /// change wedges all that follow. Losing the one change is the lesser harm.
    @discardableResult
    func saveOrRollback(_ caller: StaticString = #function) -> Bool {
        do {
            try save()
            return true
        } catch {
            ClipStore.logger.error("save failed in \(String(describing: caller), privacy: .public): \(error.localizedDescription, privacy: .public)")
            rollback()
            return false
        }
    }
}
