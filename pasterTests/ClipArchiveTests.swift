//
//  ClipArchiveTests.swift
//  pasterTests
//

import Foundation
import Testing
@testable import paster

struct ClipArchiveTests {

    @Test("A single representation round-trips")
    func singleRoundTrip() throws {
        let archive = ClipArchive(representations: [
            .init(typeIdentifier: "public.utf8-plain-text", data: Data("hello".utf8))
        ])
        let decoded = try ClipArchive.decode(try archive.encoded())

        #expect(decoded.version == ClipArchive.currentVersion)
        #expect(decoded.representations.count == 1)
        #expect(decoded.representations[0].typeIdentifier == "public.utf8-plain-text")
        #expect(String(data: decoded.representations[0].data, encoding: .utf8) == "hello")
    }

    @Test("Every representation survives, in order — this is what makes pasting lossless")
    func multipleRoundTripPreservesOrder() throws {
        let originals: [ClipArchive.Representation] = [
            .init(typeIdentifier: "public.utf8-plain-text", data: Data("plain".utf8)),
            .init(typeIdentifier: "public.html", data: Data("<b>rich</b>".utf8)),
            .init(typeIdentifier: "public.rtf", data: Data("{\\rtf1 rich}".utf8)),
        ]
        let decoded = try ClipArchive.decode(try ClipArchive(representations: originals).encoded())

        #expect(decoded.representations.count == 3)
        #expect(decoded.representations.map(\.typeIdentifier) == originals.map(\.typeIdentifier))
        #expect(decoded.representations.map(\.data) == originals.map(\.data))
    }

    @Test("Binary data survives byte for byte")
    func binaryDataIsExact() throws {
        // Not text, and deliberately containing bytes that are invalid UTF-8.
        let blob = Data((0...255).map { UInt8($0) })
        let decoded = try ClipArchive.decode(
            try ClipArchive(representations: [.init(typeIdentifier: "public.png", data: blob)]).encoded()
        )
        #expect(decoded.representations[0].data == blob)
    }

    @Test("An empty archive is representable rather than an error")
    func emptyArchive() throws {
        let decoded = try ClipArchive.decode(try ClipArchive(representations: []).encoded())
        #expect(decoded.representations.isEmpty)
    }

    @Test("The encoded form is a binary plist, not XML")
    func encodesAsBinaryPlist() throws {
        // XML would base64 every byte of the payload, and payloads are mostly
        // binary. The magic is the guarantee that has not silently regressed.
        let data = try ClipArchive(representations: [
            .init(typeIdentifier: "public.png", data: Data(repeating: 0xAB, count: 4096))
        ]).encoded()

        #expect(data.starts(with: Array("bplist00".utf8)))
        // A base64 XML plist of 4 KB would be well over 5 KB.
        #expect(data.count < 5000)
    }

    @Test("A version tag is written, so a future layout change can be detected")
    func versionIsPersisted() throws {
        let decoded = try ClipArchive.decode(
            try ClipArchive(representations: []).encoded()
        )
        #expect(decoded.version == 1)
    }

    @Test("Garbage does not decode into a plausible-looking archive")
    func garbageFailsToDecode() {
        #expect(throws: (any Error).self) {
            try ClipArchive.decode(Data("not a plist at all".utf8))
        }
    }

    @Test("A Core Data framing byte is not silently accepted as a valid archive")
    func framingBytePrefixIsRejected() throws {
        // Reading the blob straight out of SQLite yields one leading 0x01 that
        // SwiftData strips before the app sees it. If that byte ever reaches
        // the decoder, failing loudly beats returning half an archive.
        var framed = Data([0x01])
        framed.append(try ClipArchive(representations: []).encoded())
        #expect(throws: (any Error).self) {
            try ClipArchive.decode(framed)
        }
    }
}
