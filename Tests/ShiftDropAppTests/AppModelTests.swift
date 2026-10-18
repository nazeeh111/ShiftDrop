import XCTest
import AppKit
import ShiftDropCore
@testable import ShiftDrop

final class AppModelTests: XCTestCase {
    @MainActor
    func testWaitingJobUsesItsLatestSelectedFormat() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first.txt")
        let second = root.appendingPathComponent("second.txt")
        try Data("first".utf8).write(to: first)
        try Data("second".utf8).write(to: second)
        let model = AppModel()
        model.outputDirectory = root.appendingPathComponent("out")
        model.addFiles([first, second], format: .html)
        model.run()
        // MainActor has not yielded, so the worker cannot have claimed either job yet.
        model.setFormat(model.items[1].id, .rtf)
        try await waitForIdle(model)
        XCTAssertEqual(model.items[1].state, .complete)
        XCTAssertEqual(model.items[1].format, .rtf)
        let output = try XCTUnwrap(model.items[1].result?.outputURLs.first)
        XCTAssertEqual(output.pathExtension, "rtf")
        let document = try NSAttributedString(url: output, options: [:], documentAttributes: nil)
        XCTAssertEqual(document.string, "second")
        XCTAssertFalse(FileManager.default.fileExists(atPath: model.outputDirectory.appendingPathComponent("second.html").path))
    }

    @MainActor
    func testQuickDropConvertsOnlyNewDropAndKeepsExistingReadyFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let queued = root.appendingPathComponent("queued.txt")
        let dropped = root.appendingPathComponent("dropped.txt")
        try Data("queued source".utf8).write(to: queued)
        try Data("drop source".utf8).write(to: dropped)
        let model = AppModel()
        model.outputDirectory = root.appendingPathComponent("out")
        model.addFiles([queued], format: .html)
        model.addFiles([dropped], format: .rtf, start: true)
        try await waitForIdle(model)
        XCTAssertEqual(model.items[0].state, .ready)
        XCTAssertEqual(model.items[1].state, .complete)
        XCTAssertFalse(FileManager.default.fileExists(atPath: model.outputDirectory.appendingPathComponent("queued.html").path))
        XCTAssertEqual(try String(contentsOf: queued), "queued source")
        XCTAssertEqual(try String(contentsOf: dropped), "drop source")
    }

    @MainActor
    func testDropDuringBatchAutomaticallyRunsOnlyNewQuickDrops() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first.txt")
        let second = root.appendingPathComponent("second.txt")
        let unrelated = root.appendingPathComponent("unrelated.txt")
        try Data("first".utf8).write(to: first)
        try Data("second".utf8).write(to: second)
        try Data("leave queued".utf8).write(to: unrelated)
        let model = AppModel()
        model.outputDirectory = root.appendingPathComponent("out")
        var windowReveals = 0
        model.showWindow = { windowReveals += 1 }
        model.addFiles([first], format: .html, start: true, reveal: false)
        XCTAssertTrue(model.running)
        // MainActor has not yielded: both additions arrive while the first batch is active.
        model.addFiles([unrelated], format: .html, reveal: false)
        model.addFiles([second], format: .rtf, start: true, reveal: false)
        XCTAssertTrue(model.backgroundStatus?.contains("after the active batch") == true)
        try await waitForIdle(model)
        XCTAssertEqual(model.items[0].state, .complete)
        XCTAssertEqual(model.items[1].state, .ready)
        XCTAssertEqual(model.items[2].state, .complete)
        XCTAssertEqual(windowReveals, 0)
        let output = try XCTUnwrap(model.items[2].result?.outputURLs.first)
        XCTAssertEqual(try NSAttributedString(url: output, options: [:], documentAttributes: nil).string, "second")
        XCTAssertFalse(FileManager.default.fileExists(atPath: model.outputDirectory.appendingPathComponent("unrelated.html").path))
        XCTAssertEqual(try String(contentsOf: unrelated), "leave queued")
    }

    @MainActor
    func testCancellingBatchDoesNotRestartItsPendingQuickDrops() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first.txt")
        let pending = root.appendingPathComponent("pending.txt")
        let later = root.appendingPathComponent("later.txt")
        for url in [first, pending, later] { try Data(url.lastPathComponent.utf8).write(to: url) }
        let model = AppModel()
        model.outputDirectory = root.appendingPathComponent("out")
        model.addFiles([first], format: .html, start: true, reveal: false)
        model.addFiles([pending], format: .html, start: true, reveal: false)
        // Cancel before yielding, so cancellation deterministically precedes the next batch.
        model.cancel()
        try await waitForIdle(model)
        XCTAssertEqual(model.items[1].state, .ready)
        XCTAssertNil(model.items[1].result)
        // Finishing a later successful drop must not revive the cancelled automatic request.
        model.addFiles([later], format: .html, start: true, reveal: false)
        try await waitForIdle(model)
        XCTAssertEqual(model.items[2].state, .complete)
        XCTAssertEqual(model.items[1].state, .ready)
        XCTAssertNil(model.items[1].result)
        XCTAssertFalse(FileManager.default.fileExists(atPath: model.outputDirectory.appendingPathComponent("pending.html").path))
        XCTAssertEqual(try String(contentsOf: pending), "pending.txt")
    }

    @MainActor
    func testDuplicateDropDoesNotStartUnrelatedQueue() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("one.txt")
        try Data("one".utf8).write(to: file)
        let model = AppModel()
        model.addFiles([file], format: .html)
        model.addFiles([file], format: .html, start: true)
        XCTAssertEqual(model.items.count, 1)
        XCTAssertEqual(model.items[0].state, .ready)
        XCTAssertFalse(model.running)
    }

    @MainActor
    private func waitForIdle(_ model: AppModel) async throws {
        for _ in 0..<500 {
            if !model.running { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Batch did not finish within five seconds")
        model.cancel()
    }
}
