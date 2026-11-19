import Foundation
import Testing
@testable import TubeUIKit

@Test func downloadsDirectoryLivesUnderApplicationSupport() {
    let directory = DownloadStore.downloadsDirectory()
    #expect(directory.lastPathComponent == "Downloads")
    #expect(directory.deletingLastPathComponent().lastPathComponent == "TubeUI")
}

@Test func fileAndMetaURLsFollowTheID() {
    let directory = URL(fileURLWithPath: "/tmp/fake-downloads")
    #expect(DownloadStore.fileURL(for: "dQw4w9WgXcQ", in: directory) == directory.appendingPathComponent("dQw4w9WgXcQ.mp4"))
    #expect(DownloadStore.metaURL(for: "dQw4w9WgXcQ", in: directory) == directory.appendingPathComponent("dQw4w9WgXcQ.json"))
}

@Test func mergeReadsSidecarsAndSkipsStrayFiles() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("tube-dl-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let payload = Data(repeating: 0, count: 2048)
    try payload.write(to: DownloadStore.fileURL(for: "dQw4w9WgXcQ", in: directory))
    let meta = DownloadStore.StoredMeta(id: "dQw4w9WgXcQ", title: "Never Gonna Give You Up", channel: "Rick Astley", length: "3:33")
    try JSONEncoder().encode(meta).write(to: DownloadStore.metaURL(for: "dQw4w9WgXcQ", in: directory))

    try Data(repeating: 1, count: 10).write(to: DownloadStore.fileURL(for: "jNQXAC9IVRw", in: directory))

    // Not a video id, not an mp4, and a sidecar without its media: all ignored.
    try Data("x".utf8).write(to: directory.appendingPathComponent("notes.txt"))
    try Data("x".utf8).write(to: directory.appendingPathComponent("short.mp4"))

    let items = DownloadStore.merge(directory: directory)
    #expect(items.count == 2)
    #expect(items.map(\.size).reduce(0, +) == 2058)

    let withMeta = items.first { $0.id == "dQw4w9WgXcQ" }
    #expect(withMeta?.title == "Never Gonna Give You Up")
    #expect(withMeta?.channel == "Rick Astley")
    #expect(withMeta?.length == "3:33")
    #expect(withMeta?.size == 2048)
    #expect(withMeta?.fileURL.lastPathComponent == "dQw4w9WgXcQ.mp4")

    let bare = items.first { $0.id == "jNQXAC9IVRw" }
    #expect(bare?.title == "jNQXAC9IVRw")  // sidecar missing: fall back to the id
    #expect(bare?.channel == "")
    #expect(bare?.length == nil)
    #expect(bare?.size == 10)
}

@Test func mergeReturnsEmptyForMissingDirectory() {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("tube-dl-missing-\(UUID().uuidString)", isDirectory: true)
    #expect(DownloadStore.merge(directory: directory).isEmpty)
}
