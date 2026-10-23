import XCTest
import AppKit
import ShiftDropCore
@testable import ShiftDrop

final class AppModelTests: XCTestCase {
    @MainActor
    func testWaitingJobUsesItsLatestSelectedFormat() async throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first.txt")
        let second = root.appendingPathComponent("second.txt")
        try Data("first".utf8).write(to: first)
        try Data("second".utf8).write(to: second)
        let model = makeModel()
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
        XCTAssertEqual(output.deletingLastPathComponent().resolvingSymlinksInPath().path, model.outputDirectory.resolvingSymlinksInPath().path)
        let document = try NSAttributedString(url: output, options: [:], documentAttributes: nil)
        XCTAssertEqual(document.string, "second")
        XCTAssertFalse(FileManager.default.fileExists(atPath: model.outputDirectory.appendingPathComponent("second.html").path))
    }

    @MainActor
    func testQuickDropConvertsOnlyNewDropAndKeepsExistingReadyFiles() async throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let queued = root.appendingPathComponent("queued.txt")
        let dropped = root.appendingPathComponent("dropped.txt")
        try Data("queued source".utf8).write(to: queued)
        try Data("drop source".utf8).write(to: dropped)
        let model = makeModel()
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
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first.txt")
        let second = root.appendingPathComponent("second.txt")
        let unrelated = root.appendingPathComponent("unrelated.txt")
        try Data("first".utf8).write(to: first)
        try Data("second".utf8).write(to: second)
        try Data("leave queued".utf8).write(to: unrelated)
        let model = makeModel()
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
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first.txt")
        let pending = root.appendingPathComponent("pending.txt")
        let later = root.appendingPathComponent("later.txt")
        for url in [first, pending, later] { try Data(url.lastPathComponent.utf8).write(to: url) }
        let model = makeModel()
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
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("one.txt")
        try Data("one".utf8).write(to: file)
        let model = makeModel()
        model.addFiles([file], format: .html)
        model.addFiles([file], format: .html, start: true)
        XCTAssertEqual(model.items.count, 1)
        XCTAssertEqual(model.items[0].state, .ready)
        XCTAssertFalse(model.running)
    }

    @MainActor
    private func makeModel() -> AppModel {
        let name = "ShiftDrop.AppModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        let model = AppModel(defaults: defaults)
        model.saveBesideOriginals = false
        return model
    }

    @MainActor
    func testBesideOriginalsKeepsMixedParentOutputsAndExistingFilesSafe() async throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let firstDirectory = root.appendingPathComponent("first")
        let secondDirectory = root.appendingPathComponent("second")
        for directory in [firstDirectory, secondDirectory] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let first = firstDirectory.appendingPathComponent("same.txt")
        let second = secondDirectory.appendingPathComponent("same.txt")
        let existing = firstDirectory.appendingPathComponent("same.html")
        try Data("first source".utf8).write(to: first)
        try Data("second source".utf8).write(to: second)
        try Data("existing output".utf8).write(to: existing)
        let model = makeModel()
        model.saveBesideOriginals = true
        model.outputDirectory = root.appendingPathComponent("unused-custom")
        model.addFiles([first, second], format: .html, start: true, reveal: false)
        try await waitForIdle(model)
        XCTAssertEqual(model.completeCount, 2)
        let firstOutput = try XCTUnwrap(model.items[0].result?.outputURLs.first)
        let secondOutput = try XCTUnwrap(model.items[1].result?.outputURLs.first)
        XCTAssertEqual(firstOutput.deletingLastPathComponent().resolvingSymlinksInPath().path, firstDirectory.resolvingSymlinksInPath().path)
        XCTAssertEqual(secondOutput.deletingLastPathComponent().resolvingSymlinksInPath().path, secondDirectory.resolvingSymlinksInPath().path)
        XCTAssertNotEqual(firstOutput.resolvingSymlinksInPath().path, existing.resolvingSymlinksInPath().path)
        XCTAssertEqual(try String(contentsOf: existing), "existing output")
        XCTAssertEqual(try String(contentsOf: first), "first source")
        XCTAssertEqual(try String(contentsOf: second), "second source")
        XCTAssertFalse(FileManager.default.fileExists(atPath: model.outputDirectory.path))
    }

    @MainActor
    func testPlacementDefaultsBesideOriginalAndPersistsExplicitCustomChoice() {
        let name = "ShiftDrop.PlacementTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let source = URL(fileURLWithPath: "/private/tmp/source/input.txt")
        let model = AppModel(defaults: defaults)
        XCTAssertTrue(model.saveBesideOriginals)
        XCTAssertEqual(model.destinationDirectory(for: source), source.deletingLastPathComponent())
        XCTAssertEqual(model.toolDestination(for: [source]), source.deletingLastPathComponent())
        let custom = URL(fileURLWithPath: "/private/tmp/custom", isDirectory: true)
        model.outputDirectory = custom
        model.saveBesideOriginals = false
        let reopened = AppModel(defaults: defaults)
        XCTAssertFalse(reopened.saveBesideOriginals)
        XCTAssertEqual(reopened.destinationDirectory(for: source), custom)
        XCTAssertEqual(reopened.toolDestination(for: [source]), custom)
        XCTAssertEqual(reopened.toolDestination(for: []), custom)
    }

    @MainActor
    func testUnsupportedBackgroundDropReportsWithoutOpeningWindow() {
        let model = makeModel()
        var windowReveals = 0
        var statuses: [String] = []
        model.showWindow = { windowReveals += 1 }
        model.onStatus = { statuses.append($0) }
        model.addFiles([URL(fileURLWithPath: "/private/tmp/unsupported.unknown-extension")], format: .png, start: true, reveal: false)
        XCTAssertEqual(windowReveals, 0)
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertFalse(model.running)
        XCTAssertTrue(model.notice?.contains("Skipped 1") == true)
        XCTAssertEqual(statuses.last, model.notice)
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
