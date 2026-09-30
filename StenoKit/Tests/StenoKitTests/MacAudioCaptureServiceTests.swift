#if os(macOS)
import Foundation
import Testing
@testable import StenoKit

@Test("The launch sweep removes only stale Steno recordings")
func launchSweepRemovesOnlyStaleRecordings() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("StenoRecordingSweep-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let now = Date()
    let old = now.addingTimeInterval(-60 * 60)
    func file(_ name: String, modified: Date) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data("RIFF".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        return url
    }

    let stale = try file("steno-audio-\(UUID().uuidString).wav", modified: old)
    let staleLowercase = try file("steno-audio-\(UUID().uuidString.lowercased()).wav", modified: old)
    let fresh = try file("steno-audio-\(UUID().uuidString).wav", modified: now.addingTimeInterval(-30))
    let otherApp = try file("other-audio-\(UUID().uuidString).wav", modified: old)
    let notUUID = try file("steno-audio-notes.wav", modified: old)
    let otherExtension = try file("steno-audio-\(UUID().uuidString).wav.txt", modified: old)
    let transcript = try file("steno-audio-\(UUID().uuidString).txt", modified: old)
    let staleDirectory = directory.appendingPathComponent("steno-audio-\(UUID().uuidString).wav", isDirectory: true)
    try FileManager.default.createDirectory(at: staleDirectory, withIntermediateDirectories: false)
    try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: staleDirectory.path)
    let linkTarget = try file("keep-target.wav", modified: old)
    let staleLink = directory.appendingPathComponent("steno-audio-\(UUID().uuidString).wav")
    try FileManager.default.createSymbolicLink(at: staleLink, withDestinationURL: linkTarget)

    let removed = MacAudioCaptureService.removeStaleRecordings(
        in: directory,
        olderThan: 5 * 60,
        now: now
    )

    #expect(Set(removed.map(\.lastPathComponent)) == [stale.lastPathComponent, staleLowercase.lastPathComponent])
    #expect(!FileManager.default.fileExists(atPath: stale.path))
    #expect(!FileManager.default.fileExists(atPath: staleLowercase.path))
    for kept in [fresh, otherApp, notUUID, otherExtension, transcript, staleDirectory, linkTarget] {
        #expect(FileManager.default.fileExists(atPath: kept.path), "\(kept.lastPathComponent)")
    }
    #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: staleLink.path)) != nil)
}

@Test("The launch sweep tolerates a missing directory")
func launchSweepToleratesMissingDirectory() {
    let missing = FileManager.default.temporaryDirectory
        .appendingPathComponent("StenoRecordingSweepMissing-\(UUID().uuidString)", isDirectory: true)
    #expect(MacAudioCaptureService.removeStaleRecordings(in: missing, olderThan: 60, now: Date()).isEmpty)
}
#endif
