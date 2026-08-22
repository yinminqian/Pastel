//
//  ClipboardMonitor.swift
//  paster
//
//  Created by yinminqian on 21/8/2026.
//

import AppKit
import CryptoKit
import QuickLookThumbnailing
import SwiftData

/// Watches the general pasteboard and records what lands on it.
///
/// Polling is not a shortcut here: `NSPasteboard` exposes no notification, no
/// delegate and no publisher — only a readonly `changeCount`. Polling that
/// counter is the only mechanism the API offers. Contents are read only when
/// the counter actually moves, which also keeps us clear of the access alert
/// described on `pasteboardAccess`.
///
/// `@MainActor` because it owns a `ModelContext`, and contexts and model
/// instances must never cross actor boundaries.
@MainActor
final class ClipboardMonitor {
    /// The convention's marker for "this pasteboard came from me".
    static let sourceType = NSPasteboard.PasteboardType(ClipboardPrivacy.sourceType)

    /// Our stamp. Seeing it means we are looking at our own paste, not a copy
    /// the user made — recording it would feed the history back into itself.
    ///
    /// A marker rather than "remember the changeCount we caused" because a
    /// marker is self-describing and cannot race with the poll.
    /// Derived, not hardcoded: `org.nspasteboard.source` is a cross-app
    /// convention, so every other clipboard manager on the machine reads this
    /// to attribute our writes. A literal that does not match the real bundle
    /// identifier would have them attribute us to an app that does not exist.
    static let ownSourceMarker = Bundle.main.bundleIdentifier ?? "com.minqian.paster"

    /// Cap applied per representation, never to the whole clipping.
    ///
    /// Granularity matters: dropping one giant TIFF flavour while keeping the
    /// plain-text and RTF ones leaves a usable clipping, whereas discarding the
    /// whole item because a single flavour was huge throws away content the
    /// user cannot get back.
    static let maxRepresentationBytes = 10 * 1024 * 1024

    /// Once a clipping reaches this, stop taking further flavours but keep what
    /// was already collected. A backstop against pathological items carrying
    /// dozens of large flavours, not a reason to reject the clipping.
    private static let maxTotalBytes = 40 * 1024 * 1024


    private let pasteboard = NSPasteboard.general
    private let context: ModelContext
    private let settings: AppSettings
    private var timer: Timer?

    /// Persisted so a relaunch resumes where we left off. Starting from the
    /// live `changeCount` instead would silently drop anything copied while
    /// the app was not running.
    private static let changeTokenKey = "pasteboard-change-token"
    private var lastChangeCount: Int {
        didSet { UserDefaults.standard.set(lastChangeCount, forKey: Self.changeTokenKey) }
    }

    /// The first poll after launch sees whatever was already on the pasteboard.
    /// That content did not come from the app that happens to be frontmost
    /// right now — which at launch is usually us — so it must not be attributed
    /// to anyone, and it must not reorder history it merely re-observed.
    private var isFirstPoll = true

    init(context: ModelContext, settings: AppSettings) {
        self.context = context
        self.settings = settings
        let stored = UserDefaults.standard.object(forKey: Self.changeTokenKey) as? Int
        self.lastChangeCount = stored ?? NSPasteboard.general.changeCount
    }

    /// Whether macOS will let us read the pasteboard without prompting.
    ///
    /// `accessBehavior` is readonly — there is no API to request it. If this is
    /// `.ask`, the user has to switch this app to "Always Allow" in System
    /// Settings themselves, or they get an alert on essentially every copy.
    var pasteboardAccess: NSPasteboard.AccessBehavior {
        pasteboard.accessBehavior
    }

    func start(interval: TimeInterval = 0.6) {
        stop()
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            MainActor.assumeIsolated { self.poll() }
        }
        // The panel spends most of its life hidden while the user works in
        // other apps; without this the timer stalls during scroll tracking.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Polling

    private func poll() {
        let current = pasteboard.changeCount

        // Paused: advance the token without recording, so resuming does not
        // then capture everything copied while paused. Pausing is a promise
        // that nothing is kept, and a backlog flushed on resume would break it.
        if settings.isPaused {
            lastChangeCount = current
            isFirstPoll = false
            return
        }

        let wasFirstPoll = isFirstPoll
        isFirstPoll = false

        guard current != lastChangeCount else { return }
        lastChangeCount = current

        guard let items = pasteboard.pasteboardItems, !items.isEmpty else { return }

        let allTypes = Set(items.flatMap { $0.types.map(\.rawValue) })

        // First privacy layer: the pasteboard telling us this is a secret or is
        // throwaway.
        guard !ClipboardPrivacy.isExcluded(types: allTypes) else { return }

        // Our own paste echoing back at us.
        let declaredSource = items.compactMap { $0.string(forType: Self.sourceType) }.first
        guard declaredSource != Self.ownSourceMarker else { return }

        let isRemote = allTypes.contains(ClipboardPrivacy.remoteClipboardType)

        // `org.nspasteboard.source` beats the frontmost app when present: a
        // background or cross-device write did not originate from whatever
        // window happens to be in front.
        let origin = wasFirstPoll
            ? declaredSource
            : declaredSource ?? NSWorkspace.shared.frontmostApplication?.bundleIdentifier

        guard let origin else {
            // Fail closed. An unattributable pasteboard change is exactly the
            // case that might be a password manager writing from the
            // background, and with no origin the confidential-app check cannot
            // run at all. Universal Clipboard is the one legitimate
            // unattributed case, and it identifies itself.
            // Universal Clipboard identifies itself, and the first poll after
            // launch is legitimately unattributable rather than suspicious.
            if isRemote || wasFirstPoll {
                capture(items, origin: nil, isRemote: isRemote, isRefresh: wasFirstPoll)
            }
            return
        }

        // Second privacy layer, independent of whether the app marked its own
        // write. Password managers that never set ConcealedType are stopped
        // here rather than trusted to behave.
        guard !ClipboardPrivacy.isConfidentialApp(origin,
                                                  userExcluded: settings.excludedApps)
        else { return }

        capture(items, origin: origin, isRemote: isRemote, isRefresh: wasFirstPoll)
    }

    private func capture(_ items: [NSPasteboardItem],
                         origin: String?,
                         isRemote: Bool,
                         isRefresh: Bool) {
        var representations: [(type: String, data: Data)] = []
        var seenTypes = Set<String>()
        var total = 0
        /// Largest image flavour we had to skip for size, kept so an
        /// image-only clipping can still be stored downscaled instead of
        /// vanishing.
        var oversizedImage: Data?

        // Flattened across items. A multi-item copy (several files at once)
        // therefore collapses to one clipping keyed by first-seen type — good
        // enough while every card is a single paste, but it is a real limit.
        outer: for item in items {
            for type in item.types {
                let identifier = type.rawValue
                guard !seenTypes.contains(identifier),
                      type != Self.sourceType,
                      !ClipboardPrivacy.nonStorableTypes.contains(identifier),
                      let data = item.data(forType: type),
                      !data.isEmpty
                else { continue }

                // Skip just this flavour; the clipping survives.
                guard data.count <= Self.maxRepresentationBytes else {
                    if Self.isImageType(identifier), data.count > (oversizedImage?.count ?? 0) {
                        oversizedImage = data
                    }
                    continue
                }

                seenTypes.insert(identifier)
                representations.append((identifier, data))
                total += data.count
                if total > Self.maxTotalBytes { break outer }
            }
        }

        // A big screenshot can exceed the cap in every flavour it offers. The
        // clipping disappearing with no trace is worse than storing a
        // downscaled copy, so re-encode rather than drop.
        if representations.isEmpty, let oversizedImage,
           let downscaled = Self.reencodedPNG(from: oversizedImage, maxPixel: 2048) {
            let identifier = NSPasteboard.PasteboardType.png.rawValue
            seenTypes.insert(identifier)
            representations.append((identifier, downscaled))
        }

        guard !representations.isEmpty else { return }

        let fingerprint = Self.fingerprint(of: representations)

        // A repeat copy moves the existing clipping to the top rather than
        // adding a second identical row.
        if let existing = try? context.fetch(
            FetchDescriptor<ClipItem>(predicate: #Predicate { $0.fingerprint == fingerprint })
        ).first {
            // A refresh poll only re-observed what was already on the
            // pasteboard; treating that as a fresh copy would reorder history
            // with a timestamp nothing actually happened at.
            if !isRefresh {
                existing.copiedAt = Date()
                try? context.save()
            }
            return
        }

        let preview = Self.previewText(from: representations)
        let kind = Self.kind(for: seenTypes, preview: preview)
        let item = ClipItem(
            kind: kind,
            fingerprint: fingerprint,
            previewText: preview,
            contentLength: Self.contentLength(of: representations, kind: kind),
            thumbnailData: Self.thumbnail(from: representations),
            sourceBundleID: origin,
            isFromRemoteDevice: isRemote
        )
        context.insert(item)

        // One archive rather than a row per type. Assigned after insert so the
        // payload joins an item that already exists in the context.
        let archive = ClipArchive(
            representations: representations.map {
                ClipArchive.Representation(typeIdentifier: $0.type, data: $0.data)
            }
        )
        if let encoded = try? archive.encoded() {
            let payload = ClipPayload(archive: encoded)
            context.insert(payload)
            item.payload = payload
        } else {
            // No payload means a card that pastes nothing, which is worse than
            // no card at all.
            context.delete(item)
            return
        }

        // SwiftData's autosaving is unpredictable, and losing a clipping means
        // losing something the user cannot get back.
        try? context.save()
        prune()

        // A copied file gets a real preview of its contents rather than a
        // generic type icon — a copied screenshot should look like the
        // screenshot. Kicked off after the save because QuickLook is async and
        // the clipping must not wait on it.
        if item.kind == .fileURL { generateFileThumbnail(for: item) }
    }

    /// Renders a QuickLook thumbnail for a copied file into `thumbnailData`.
    ///
    /// Stored rather than generated on demand, for two reasons: a card must not
    /// do async work while scrolling, and a clipping is a record of what was
    /// copied — if the file is later moved or deleted, the thumbnail should
    /// still show what the user put on the clipboard.
    private func generateFileThumbnail(for item: ClipItem) {
        guard let text = item.previewText,
              let url = URL(string: text),
              url.isFileURL,
              FileManager.default.fileExists(atPath: url.path)
        else { return }

        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: 160, height: 160),
            scale: 2,
            representationTypes: .all
        )
        let identifier = item.persistentModelID

        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] rep, _ in
            guard let rep else { return }
            let png = NSBitmapImageRep(cgImage: rep.cgImage)
                .representation(using: .png, properties: [:])
            guard let png else { return }
            Task { @MainActor [weak self] in
                // Re-fetched by identifier rather than captured: a model object
                // must not cross the callback's actor boundary, and the item
                // may have been pruned while QuickLook was working.
                guard let self,
                      let stored = self.context.model(for: identifier) as? ClipItem
                else { return }
                stored.thumbnailData = png
                try? self.context.save()
            }
        }
    }

    /// Not `private`, so the retention rules can be tested directly. They are
    /// the one part of this class whose bugs delete the user's data.
    func prune() {
        var didDelete = false

        // Age axis. Runs first and unconditionally: an old clipping is stale
        // whether or not the store is near its row limit, and content the user
        // forgot about is exactly what should not sit around indefinitely.
        let cutoff = Date().addingTimeInterval(-settings.maxAge)
        let expired = FetchDescriptor<ClipItem>(
            predicate: #Predicate { $0.copiedAt < cutoff && !$0.isPinned }
        )
        if let old = try? context.fetch(expired), !old.isEmpty {
            old.forEach(context.delete)
            didDelete = true
        }

        // Count axis. Counted before fetching, because loading every row's
        // objects just to learn there is nothing to prune would run on every
        // single copy.
        //
        // The pinned filter has to be on the count AND on the offset fetch. With
        // it on only one, the offset would be measured against a total that
        // includes pinned rows but applied to a list that does not, so it walks
        // past unpinned rows and deletes from the wrong end.
        let unpinned = #Predicate<ClipItem> { !$0.isPinned }
        let total = (try? context.fetchCount(FetchDescriptor<ClipItem>(predicate: unpinned))) ?? 0
        if total > settings.historyLimit {
            var descriptor = FetchDescriptor<ClipItem>(
                predicate: unpinned,
                sortBy: [SortDescriptor(\.copiedAt, order: .reverse)]
            )
            descriptor.fetchOffset = settings.historyLimit
            if let surplus = try? context.fetch(descriptor), !surplus.isEmpty {
                surplus.forEach(context.delete)
                didDelete = true
            }
        }

        if didDelete { try? context.save() }
    }

    // MARK: - Derivation

    static func fingerprint(of reps: [(type: String, data: Data)]) -> String {
        var hasher = SHA256()
        for rep in reps.sorted(by: { $0.type < $1.type }) {
            hasher.update(data: Data(rep.type.utf8))
            hasher.update(data: rep.data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func kind(for types: Set<String>, preview: String? = nil) -> ClipKind {
        if types.contains(NSPasteboard.PasteboardType.fileURL.rawValue) { return .fileURL }
        if types.contains(NSPasteboard.PasteboardType.png.rawValue)
            || types.contains(NSPasteboard.PasteboardType.tiff.rawValue) { return .image }
        // Plain text wins over a styled representation of the same thing.
        //
        // Checked before the rich types on purpose: a terminal puts HTML on the
        // pasteboard alongside the characters, so "contains HTML" labelled a
        // one-line shell command "Rich Text". If plain text is there, that is
        // what the user copied and what they see. The styled representations
        // are still stored, and listed as formats in the detail pane, which is
        // information rather than a misleading category.
        if types.contains(NSPasteboard.PasteboardType.string.rawValue) {
            return isLink(preview) ? .link : .text
        }
        // Rich only when there is no plain text at all to fall back on.
        if types.contains(NSPasteboard.PasteboardType.rtf.rawValue)
            || types.contains(NSPasteboard.PasteboardType.rtfd.rawValue)
            || types.contains(NSPasteboard.PasteboardType.html.rawValue) { return .richText }
        return .other
    }

    /// A clipping is a link only if the whole thing is one web URL.
    ///
    /// Checked against the content rather than the pasteboard's own
    /// `public.url` type, because copying a URL out of a text field offers only
    /// plain text. Deliberately strict: a paragraph that merely mentions a URL
    /// is still a paragraph, and rendering it as a link card would hide the
    /// text the user actually copied.
    static func isLink(_ preview: String?) -> Bool {
        guard let trimmed = preview?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              trimmed.count <= 2048,
              !trimmed.contains(where: \.isWhitespace),
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = url.host, host.contains(".")
        else { return false }
        return true
    }

    static func isImageType(_ identifier: String) -> Bool {
        identifier == NSPasteboard.PasteboardType.png.rawValue
            || identifier == NSPasteboard.PasteboardType.tiff.rawValue
    }

    /// Re-encodes an image to PNG, bounded to `maxPixel` on its longest side.
    static func reencodedPNG(from data: Data, maxPixel: CGFloat) -> Data? {
        guard let source = NSImage(data: data) else { return nil }
        let size = source.size
        guard size.width > 0, size.height > 0 else { return nil }

        let scale = min(1, maxPixel / max(size.width, size.height))
        let target = NSSize(width: (size.width * scale).rounded(),
                            height: (size.height * scale).rounded())

        // Drawn through a bitmap rep rather than NSImage's own PNG path so the
        // output pixel dimensions are the ones asked for, independent of the
        // source's DPI metadata.
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                        pixelsWide: Int(target.width),
                                        pixelsHigh: Int(target.height),
                                        bitsPerSample: 8,
                                        samplesPerPixel: 4,
                                        hasAlpha: true,
                                        isPlanar: false,
                                        colorSpaceName: .deviceRGB,
                                        bytesPerRow: 0,
                                        bitsPerPixel: 0)
        else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        source.draw(in: NSRect(origin: .zero, size: target))
        NSGraphicsContext.restoreGraphicsState()

        return rep.representation(using: .png, properties: [:])
    }

    static func thumbnail(from reps: [(type: String, data: Data)]) -> Data? {
        guard let image = reps.first(where: { isImageType($0.type) })?.data else { return nil }
        return reencodedPNG(from: image, maxPixel: 320)
    }

    /// Characters for text-like clippings, bytes for binary ones — one field,
    /// disambiguated by the kind.
    static func contentLength(of reps: [(type: String, data: Data)], kind: ClipKind) -> Int {
        switch kind {
        case .text, .richText, .link:
            let plain = NSPasteboard.PasteboardType.string.rawValue
            guard let data = reps.first(where: { $0.type == plain })?.data,
                  let text = String(data: data, encoding: .utf8)
            else { return 0 }
            return text.count
        case .image, .fileURL, .other:
            return reps.reduce(0) { $0 + $1.data.count }
        }
    }

    static func previewText(from reps: [(type: String, data: Data)]) -> String? {
        let plain = NSPasteboard.PasteboardType.string.rawValue
        let url = NSPasteboard.PasteboardType.fileURL.rawValue
        for identifier in [plain, url] {
            if let data = reps.first(where: { $0.type == identifier })?.data,
               let text = String(data: data, encoding: .utf8) {
                return String(text.prefix(500))
            }
        }
        return nil
    }
}
