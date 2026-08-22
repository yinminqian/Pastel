//
//  ClipboardMonitorLogicTests.swift
//  pasterTests
//

import AppKit
import Foundation
import Testing
@testable import paster

@MainActor
struct ClipboardMonitorLogicTests {

    private func png(_ side: Int) -> Data {
        let image = NSImage(size: NSSize(width: side, height: side))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: side, height: side).fill()
        image.unlockFocus()
        let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
        return rep.representation(using: .png, properties: [:])!
    }

    // MARK: Kind classification

    @Test("A file URL wins over every other flavour it is offered with")
    func fileURLTakesPrecedence() {
        // Finder puts an icon on the pasteboard alongside the file URL; the
        // clipping is still a file.
        let types: Set<String> = ["public.file-url", "public.png", "public.utf8-plain-text"]
        #expect(ClipboardMonitor.kind(for: types) == .fileURL)
    }

    @Test("An image wins over rich text and plain text")
    func imageBeatsText() {
        #expect(ClipboardMonitor.kind(for: ["public.png", "public.utf8-plain-text"]) == .image)
        #expect(ClipboardMonitor.kind(for: ["public.tiff", "public.rtf"]) == .image)
    }

    @Test("Plain text wins over a styled copy of the same thing")
    func plainTextBeatsStyling() {
        // A terminal puts HTML on the pasteboard next to the characters, which
        // used to label a one-line shell command "Rich Text".
        #expect(ClipboardMonitor.kind(for: ["public.rtf", "public.utf8-plain-text"]) == .text)
        #expect(ClipboardMonitor.kind(for: ["public.html", "public.utf8-plain-text"]) == .text)
        #expect(ClipboardMonitor.kind(for: ["com.apple.flat-rtfd", "public.utf8-plain-text",
                                            "public.html"]) == .text)
    }

    @Test("Rich text is the kind only when there is no plain text to fall back on")
    func richTextWithoutPlain() {
        #expect(ClipboardMonitor.kind(for: ["public.rtf"]) == .richText)
        #expect(ClipboardMonitor.kind(for: ["public.html"]) == .richText)
        // The real RTFD identifier, which is not `public.rtfd`.
        #expect(ClipboardMonitor.kind(for: ["com.apple.flat-rtfd"]) == .richText)
    }

    @Test("A URL still classifies as a link even when a styled copy rides along")
    func linkSurvivesStyling() {
        let kind = ClipboardMonitor.kind(for: ["public.html", "public.utf8-plain-text"],
                                        preview: "https://example.com/a")
        #expect(kind == .link)
    }

    @Test("Plain text alone is text")
    func plainText() {
        #expect(ClipboardMonitor.kind(for: ["public.utf8-plain-text"]) == .text)
    }

    @Test("An unrecognised set is 'other' rather than a wrong guess")
    func unknownIsOther() {
        #expect(ClipboardMonitor.kind(for: ["com.example.private-type"]) == .other)
        #expect(ClipboardMonitor.kind(for: []) == .other)
    }

    // MARK: Fingerprint

    @Test("The same content produces the same fingerprint, so a repeat copy collapses")
    func fingerprintIsStable() {
        let reps = [(type: "public.utf8-plain-text", data: Data("hello".utf8))]
        #expect(ClipboardMonitor.fingerprint(of: reps) == ClipboardMonitor.fingerprint(of: reps))
    }

    @Test("Fingerprint does not depend on the order the pasteboard reported types in")
    func fingerprintIsOrderIndependent() {
        // The pasteboard is free to enumerate types in any order; two copies of
        // the same thing must not become two rows.
        let a = [(type: "public.utf8-plain-text", data: Data("x".utf8)),
                 (type: "public.html", data: Data("<b>x</b>".utf8))]
        let b = [(type: "public.html", data: Data("<b>x</b>".utf8)),
                 (type: "public.utf8-plain-text", data: Data("x".utf8))]
        #expect(ClipboardMonitor.fingerprint(of: a) == ClipboardMonitor.fingerprint(of: b))
    }

    @Test("Different content produces a different fingerprint")
    func fingerprintDiscriminatesContent() {
        let a = [(type: "public.utf8-plain-text", data: Data("hello".utf8))]
        let b = [(type: "public.utf8-plain-text", data: Data("world".utf8))]
        #expect(ClipboardMonitor.fingerprint(of: a) != ClipboardMonitor.fingerprint(of: b))
    }

    @Test("Same bytes under a different type is a different clipping")
    func fingerprintDiscriminatesType() {
        let bytes = Data("payload".utf8)
        let a = [(type: "public.utf8-plain-text", data: bytes)]
        let b = [(type: "public.html", data: bytes)]
        #expect(ClipboardMonitor.fingerprint(of: a) != ClipboardMonitor.fingerprint(of: b))
    }

    @Test("An extra representation changes the fingerprint")
    func fingerprintCoversEveryRepresentation() {
        let one = [(type: "public.utf8-plain-text", data: Data("x".utf8))]
        let two = one + [(type: "public.html", data: Data("<b>x</b>".utf8))]
        #expect(ClipboardMonitor.fingerprint(of: one) != ClipboardMonitor.fingerprint(of: two))
    }

    @Test("A fingerprint is a full SHA-256 in hex")
    func fingerprintShape() {
        let f = ClipboardMonitor.fingerprint(of: [(type: "t", data: Data())])
        #expect(f.count == 64)
        #expect(f.allSatisfy { $0.isHexDigit })
    }

    // MARK: Preview text

    @Test("Plain text is preferred for the preview")
    func previewPrefersPlainText() {
        let reps = [(type: "public.html", data: Data("<b>rich</b>".utf8)),
                    (type: "public.utf8-plain-text", data: Data("plain".utf8))]
        #expect(ClipboardMonitor.previewText(from: reps) == "plain")
    }

    @Test("A file URL is used when there is no plain text")
    func previewFallsBackToFileURL() {
        let reps = [(type: "public.file-url", data: Data("file:///tmp/x.txt".utf8))]
        #expect(ClipboardMonitor.previewText(from: reps) == "file:///tmp/x.txt")
    }

    @Test("An image has no preview text rather than mojibake")
    func previewIsNilForImages() {
        #expect(ClipboardMonitor.previewText(from: [(type: "public.png", data: Data([0xFF, 0xD8]))]) == nil)
    }

    @Test("Preview text is truncated so a huge clipping does not bloat every row")
    func previewIsTruncated() {
        let long = String(repeating: "a", count: 5000)
        let preview = ClipboardMonitor.previewText(
            from: [(type: "public.utf8-plain-text", data: Data(long.utf8))]
        )
        #expect(preview?.count == 500)
    }

    @Test("Invalid UTF-8 yields no preview instead of a replacement-character mess")
    func previewRejectsInvalidUTF8() {
        let invalid = Data([0xFF, 0xFE, 0xFD])
        #expect(ClipboardMonitor.previewText(from: [(type: "public.utf8-plain-text", data: invalid)]) == nil)
    }

    // MARK: Image normalisation

    @Test("A large image is re-encoded down to the requested bound")
    func reencodeBoundsTheLongestSide() throws {
        let source = png(800)
        let shrunk = try #require(ClipboardMonitor.reencodedPNG(from: source, maxPixel: 100))
        let rep = try #require(NSBitmapImageRep(data: shrunk))
        #expect(max(rep.pixelsWide, rep.pixelsHigh) == 100)
        #expect(shrunk.count < source.count)
    }

    @Test("An image already within bounds is not enlarged")
    func reencodeDoesNotUpscale() throws {
        let shrunk = try #require(ClipboardMonitor.reencodedPNG(from: png(50), maxPixel: 500))
        let rep = try #require(NSBitmapImageRep(data: shrunk))
        #expect(max(rep.pixelsWide, rep.pixelsHigh) == 50)
    }

    @Test("Non-image data yields nil rather than a corrupt thumbnail")
    func reencodeRejectsNonImages() {
        #expect(ClipboardMonitor.reencodedPNG(from: Data("not an image".utf8), maxPixel: 100) == nil)
        #expect(ClipboardMonitor.reencodedPNG(from: Data(), maxPixel: 100) == nil)
    }

    @Test("A thumbnail is derived from an image representation and bounded")
    func thumbnailFromImage() throws {
        let reps = [(type: "public.png", data: png(1000))]
        let thumb = try #require(ClipboardMonitor.thumbnail(from: reps))
        let rep = try #require(NSBitmapImageRep(data: thumb))
        #expect(max(rep.pixelsWide, rep.pixelsHigh) == 320)
    }

    @Test("Text-only clippings get no thumbnail")
    func noThumbnailForText() {
        let reps = [(type: "public.utf8-plain-text", data: Data("hello".utf8))]
        #expect(ClipboardMonitor.thumbnail(from: reps) == nil)
    }

    @Test("Image types are recognised, and non-image types are not")
    func imageTypeRecognition() {
        #expect(ClipboardMonitor.isImageType("public.png"))
        #expect(ClipboardMonitor.isImageType("public.tiff"))
        #expect(!ClipboardMonitor.isImageType("public.utf8-plain-text"))
        #expect(!ClipboardMonitor.isImageType("public.file-url"))
    }
}

@MainActor
struct LinkDetectionTests {

    @Test("A bare web URL is a link", arguments: [
        "https://developer.apple.com/documentation/appkit/nspasteboard",
        "http://example.com",
        "https://example.com/a/b?q=1#frag",
    ])
    func webURLsAreLinks(text: String) {
        #expect(ClipboardMonitor.isLink(text))
        #expect(ClipboardMonitor.kind(for: ["public.utf8-plain-text"], preview: text) == .link)
    }

    @Test("Surrounding whitespace does not stop it being a link")
    func whitespaceIsTrimmed() {
        #expect(ClipboardMonitor.isLink("  https://example.com\n"))
    }

    @Test("A paragraph that merely mentions a URL is still text")
    func prosePreservedAsText() {
        // Rendering this as a link card would hide the text the user copied.
        let text = "See https://example.com for details"
        #expect(!ClipboardMonitor.isLink(text))
        #expect(ClipboardMonitor.kind(for: ["public.utf8-plain-text"], preview: text) == .text)
    }

    @Test("Non-web schemes are not links", arguments: [
        "file:///Users/me/x.txt",
        "mailto:someone@example.com",
        "paster://pause",
        "ftp://example.com",
    ])
    func nonWebSchemesRejected(text: String) {
        // A file URL has its own kind, and an app scheme is not something to
        // render as a web link.
        #expect(!ClipboardMonitor.isLink(text))
    }

    @Test("Malformed or hostless input is not a link", arguments: [
        "", "   ", "https://", "https://nodot", "not a url at all", "example.com",
    ])
    func malformedRejected(text: String) {
        #expect(!ClipboardMonitor.isLink(text))
    }

    @Test("A file URL clipping stays a file even when the text parses as a URL")
    func fileTypeWinsOverLinkDetection() {
        let kind = ClipboardMonitor.kind(for: ["public.file-url", "public.utf8-plain-text"],
                                        preview: "file:///tmp/x.pdf")
        #expect(kind == .fileURL)
    }

    @Test("An absurdly long single token is not treated as a link")
    func lengthIsBounded() {
        #expect(!ClipboardMonitor.isLink("https://example.com/" + String(repeating: "a", count: 4000)))
    }
}

@MainActor
struct MonospacePreviewTests {

    private func item(_ preview: String) -> ClipItem {
        ClipItem(kind: .text, fingerprint: "x", previewText: preview)
    }

    @Test("Indented lines mean whitespace carries meaning, so the preview is monospaced")
    func indentedTextIsCode() {
        #expect(item("func x() {\n    return 1\n}").prefersMonospacedPreview)
        #expect(item("a\n\tb").prefersMonospacedPreview)
    }

    @Test("Ordinary prose is not monospaced just because it has brackets or newlines")
    func proseIsNotCode() {
        // Guessing from punctuation density would mono-space this.
        #expect(!item("Hello (world).\nSecond line here.").prefersMonospacedPreview)
        #expect(!item("One line only { with braces }").prefersMonospacedPreview)
    }

    @Test("A single line is never monospaced")
    func singleLineIsNeverCode() {
        #expect(!item("    indented but one line").prefersMonospacedPreview)
    }

    @Test("No preview text means no monospacing decision to make")
    func nilPreview() {
        #expect(!ClipItem(kind: .image, fingerprint: "y").prefersMonospacedPreview)
    }
}
