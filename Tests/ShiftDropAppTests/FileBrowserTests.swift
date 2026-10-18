import XCTest
@testable import ShiftDrop

final class FileBrowserTests: XCTestCase {
    @MainActor
    func testNavigationReplacesListingAndDirectHiddenFileCanBeSelected() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let subfolder = root.appendingPathComponent("inside", isDirectory: true)
        try FileManager.default.createDirectory(at: subfolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = subfolder.appendingPathComponent("visible.txt")
        let hidden = subfolder.appendingPathComponent(".hidden.txt")
        try Data("visible".utf8).write(to: file)
        try Data("hidden".utf8).write(to: hidden)
        let browser = FileBrowserModel(directory: root)
        try await waitForListing(browser)
        XCTAssertEqual(browser.entries.map(\.url.lastPathComponent), ["inside"])
        browser.path = subfolder.path
        browser.go()
        XCTAssertTrue(browser.entries.isEmpty)
        try await waitForListing(browser)
        XCTAssertEqual(browser.directory.path, subfolder.path)
        XCTAssertEqual(browser.entries.map(\.url.lastPathComponent), ["visible.txt"])
        browser.path = hidden.path
        browser.go()
        try await waitForListing(browser)
        XCTAssertEqual(browser.selection, [hidden])
        browser.path = root.appendingPathComponent("missing").path
        browser.go()
        XCTAssertNotNil(browser.error)
    }
    @MainActor private func waitForListing(_ browser: FileBrowserModel) async throws {
        for _ in 0..<200 {
            if !browser.loading { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("File listing did not finish")
    }
}
