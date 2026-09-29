//
//  StressStore.swift
//  paster
//

#if DEBUG
import AppKit
import QuartzCore
import SwiftData

/// A throwaway in-memory history of any size, for measuring the panel at
/// 1,000 or 10,000 clippings without touching the real store.
///
/// Launch a Debug build with `-StressRows 10000`. Nothing is written to disk,
/// and quitting discards it all.
@MainActor
enum StressStore {
    static var requestedRows: Int? {
        let rows = UserDefaults.standard.integer(forKey: "StressRows")
        return rows > 0 ? rows : nil
    }

    static func make(rows: Int, schema: Schema) -> ModelContainer? {
        guard let container = try? ModelContainer(
            for: schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        ) else { return nil }
        let context = container.mainContext
        let pictures = [(NSColor.systemTeal, NSColor.systemOrange), (.systemIndigo, .systemYellow),
                        (.systemPink, .white), (.systemGreen, .systemBlue)].compactMap(swatch)
        // Seconds between clippings; `-StressSpacing 3600` spreads 300 of
        // them over a fortnight, so day headings have something to head.
        let configured = UserDefaults.standard.double(forKey: "StressSpacing")
        let spacing = configured > 0 ? configured : 30
        // What a real clipboard holds: prose in two languages, commands, code,
        // links, colours, addresses, pictures — each from a plausible app.
        let samples: [(ClipKind, String, String)] = [
            (.text, "产品评审纪要 — Q4 Roadmap 已确认，周一同步给设计和研发", "com.electron.lark"),
            (.text, "git push origin feat/light-list --force-with-lease", "com.apple.Terminal"),
            (.link, "https://developer.apple.com/design/human-interface-guidelines", "com.apple.Safari"),
            (.image, "", "com.apple.finder"),
            (.text, "let rows = clips.prefix(14).map(ClipRow.init)", "com.apple.dt.Xcode"),
            (.text, "#F2552C", "com.bohemiancoding.sketch3"),
            (.text, "明天下午三点开会，记得带上打印好的合同", "com.tencent.xinWeChat"),
            (.text, "Can you review PR #482 before lunch? Mostly layout changes.", "com.google.Chrome"),
            (.link, "https://github.com/ihealth/paster/pull/482", "com.google.Chrome"),
            (.text, "上海市徐汇区漕溪北路 88 号 12 楼，200030", "com.tencent.xinWeChat"),
            (.text, "ssh deploy@10.0.3.21 -p 2222", "com.mitchellh.ghostty"),
            (.image, "", "com.apple.Safari"),
            (.text, "Thanks — I'll send the signed copy by Friday.", "com.apple.mail"),
            (.text, "#2F6BFF", "com.bohemiancoding.sketch3"),
            (.text, "SELECT id, kind FROM clips WHERE pinned = 1;", "com.apple.dt.Xcode"),
            (.text, "发票抬头：上海云杉信息科技有限公司，税号 91310104MA1FR6", "com.electron.lark"),
            (.link, "https://www.figma.com/design/Kx9f2/round-3-lists", "com.google.Chrome"),
            (.text, "func debounce<T>(_ value: T, for interval: Duration) async -> T {\n    try? await Task.sleep(for: interval)\n    return value\n}", "com.apple.dt.Xcode"),
            (.text, "好的，我按这版截图改，下午给你看", "com.tencent.xinWeChat"),
            (.text, "The migration runs before the store opens, so there is no window where old rows are read with the new schema.", "md.obsidian"),
        ]
        for index in 0 ..< rows {
            let (kind, text, app) = samples[index % samples.count]
            let isImage = kind == .image
            context.insert(ClipItem(
                copiedAt: Date().addingTimeInterval(-Double(index) * spacing),
                kind: kind,
                fingerprint: "stress-\(index)",
                previewText: isImage ? nil : text,
                contentLength: isImage ? 48_000 + index : text.count,
                thumbnailData: isImage ? pictures[(index / samples.count) % pictures.count] : nil,
                sourceBundleID: app
            ))
        }
        try? context.save()
        return container
    }

    private static func swatch(_ colours: (NSColor, NSColor)) -> Data? {
        let image = NSImage(size: NSSize(width: 320, height: 200))
        image.lockFocus()
        colours.0.setFill()
        NSRect(x: 0, y: 0, width: 320, height: 200).fill()
        colours.1.setFill()
        NSRect(x: 40, y: 40, width: 120, height: 80).fill()
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation else { return nil }
        return NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
    }
}

/// Records every frame while the panel is on screen and appends a summary to
/// `/tmp/paster-frames.log` when it goes away: how many frames were late, the
/// worst gap, and the process's memory.
///
/// Only runs when `-FrameProbe YES` is passed, so an ordinary Debug run pays
/// nothing for it.
@MainActor
final class FrameProbe: NSObject {
    static let isEnabled = UserDefaults.standard.bool(forKey: "FrameProbe")

    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private var gaps: [CFTimeInterval] = []
    private var shownAt: CFTimeInterval = 0
    private var firstFrame: CFTimeInterval?

    func start(on view: NSView) {
        guard Self.isEnabled, link == nil else { return }
        gaps.removeAll(keepingCapacity: true)
        last = 0
        firstFrame = nil
        shownAt = CACurrentMediaTime()
        // The screen's link, not the view's: a view's link created in the same
        // tick the window is ordered in never fired under -O.
        guard let screen = view.window?.screen ?? NSScreen.main else { return }
        let link = screen.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        if firstFrame == nil { firstFrame = now - shownAt }
        if last > 0 { gaps.append(now - last) }
        last = now
    }

    func stop(rows: Int) {
        guard let link else { return }
        link.invalidate()
        self.link = nil
        guard !gaps.isEmpty else { return }

        let sorted = gaps.sorted()
        let frame = sorted[sorted.count / 2]
        // Absolute rather than relative to the median: ProMotion drops to
        // 60 Hz when idle, which would move a relative threshold.
        let hitches = gaps.filter { $0 > 0.025 }.count
        let p99 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.99))]
        let line = String(
            format: "rows=%d frames=%d over25ms=%d p50=%.1fms p99=%.1fms max=%.1fms firstFrame=%.0fms rss=%.0fMB\n",
            rows, gaps.count, hitches, frame * 1000, p99 * 1000, (sorted.last ?? 0) * 1000,
            (firstFrame ?? 0) * 1000, Self.residentMegabytes()
        )
        let url = URL(fileURLWithPath: "/tmp/paster-frames.log")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    private static func residentMegabytes() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : 0
    }
}
#endif
