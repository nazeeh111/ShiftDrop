import XCTest
@testable import ShiftDropCore

final class FileTransferTests: XCTestCase {
    func testMovesWithoutReplacingExistingBytesAndRejectsRecursiveMove() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("source"), destination = root.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let input = source.appendingPathComponent("Note.txt"), existing = destination.appendingPathComponent("Note.txt")
        try Data("new".utf8).write(to: input); try Data("existing".utf8).write(to: existing)
        let moved = try FileTransfer.move([input], to: destination)
        XCTAssertEqual(moved.first?.lastPathComponent, "Note (2).txt")
        XCTAssertEqual(try Data(contentsOf: existing), Data("existing".utf8))
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(moved.first)), Data("new".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: input.path))
        XCTAssertThrowsError(try FileTransfer.move([root], to: destination))
        let link = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: existing)
        XCTAssertThrowsError(try FileTransfer.move([link], to: source))
        XCTAssertEqual(try Data(contentsOf: existing), Data("existing".utf8))
    }
}
