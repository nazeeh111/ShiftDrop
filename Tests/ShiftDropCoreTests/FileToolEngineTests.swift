import XCTest
@testable import ShiftDropCore

final class FileToolEngineTests: XCTestCase {
    func testRejectedFolderCompressionDoesNotCreateDestinationInsideSource() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("original", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = source.appendingPathComponent("keep.txt")
        let bytes = Data("original bytes stay unchanged".utf8)
        try bytes.write(to: original)
        let destination = source.appendingPathComponent("new-output/nested", isDirectory: true)
        do {
            _ = try await FileToolEngine.run(ToolRequest(tool: .compress, inputs: [source], outputDirectory: destination))
            XCTFail("Compression into its own input folder must fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("outside the folder"), error.localizedDescription)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: source.path), ["keep.txt"])
        XCTAssertEqual(try Data(contentsOf: original), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }
}
