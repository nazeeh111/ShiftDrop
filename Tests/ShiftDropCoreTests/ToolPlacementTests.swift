import XCTest
import CoreGraphics
import CryptoKit
import ImageIO
import PDFKit
@testable import ShiftDropCore

final class ToolPlacementTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("ShiftDropToolPlacement-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    func testMixedParentCropUsesEachSourceNameAndPreservesExistingBytes() async throws {
        let first = try image(folder: "first", name: "alpha.png")
        let second = try image(folder: "second", name: "beta.png")
        let originalHashes = try [first, second].map(hash)
        let existing = first.deletingLastPathComponent().appendingPathComponent("alpha-cropImage.png")
        let existingBytes = Data("keep existing output".utf8)
        try existingBytes.write(to: existing)
        var settings = ToolSettings(); settings.width = 8; settings.height = 6
        let result = try await FileToolEngine.run(.init(tool: .cropImage, inputs: [first, second], outputDirectory: root.appendingPathComponent("unused"), settings: settings, outputBesideInputs: true))
        XCTAssertEqual(result.outputURLs.count, 2)
        for (index, output) in result.outputURLs.enumerated() {
            XCTAssertEqual(canonical(output.deletingLastPathComponent()), canonical([first, second][index].deletingLastPathComponent()))
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
            let rendered = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            XCTAssertEqual(rendered.width, 8); XCTAssertEqual(rendered.height, 6)
        }
        XCTAssertEqual(result.outputURLs[0].lastPathComponent, "alpha-cropImage (2).png")
        XCTAssertEqual(result.outputURLs[1].lastPathComponent, "beta-cropImage.png")
        XCTAssertEqual(try [first, second].map(hash), originalHashes)
        XCTAssertEqual(try Data(contentsOf: existing), existingBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("unused").path))
        try assertNoStaging()
    }

    func testDefaultRequestKeepsExplicitCustomFolderForAllInputs() async throws {
        let first = try image(folder: "first", name: "alpha.png")
        let second = try image(folder: "second", name: "beta.png")
        let custom = root.appendingPathComponent("custom", isDirectory: true)
        var settings = ToolSettings(); settings.width = 8; settings.height = 6
        let result = try await FileToolEngine.run(.init(tool: .cropImage, inputs: [first, second], outputDirectory: custom, settings: settings))
        XCTAssertEqual(result.outputURLs.count, 2)
        XCTAssertTrue(result.outputURLs.allSatisfy { canonical($0.deletingLastPathComponent()) == canonical(custom) })
        XCTAssertEqual(try entries(beside: first), ["alpha.png"])
        XCTAssertEqual(try entries(beside: second), ["beta.png"])
        try assertNoStaging()
    }

    func testCombinedImagesPDFUsesFirstSourceParentAndOrderedPages() async throws {
        let first = try image(folder: "first", name: "alpha.png", width: 16, height: 12)
        let second = try image(folder: "second", name: "beta.png", width: 20, height: 10)
        let originalHashes = try [first, second].map(hash)
        let result = try await FileToolEngine.run(.init(tool: .imagesPDF, inputs: [first, second], outputDirectory: root.appendingPathComponent("unused"), outputBesideInputs: true))
        let output = try XCTUnwrap(result.outputURLs.first)
        XCTAssertEqual(result.outputURLs.count, 1)
        XCTAssertEqual(canonical(output.deletingLastPathComponent()), canonical(first.deletingLastPathComponent()))
        let pdf = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertEqual(pdf.pageCount, 2)
        XCTAssertEqual(pdf.page(at: 0)?.bounds(for: .mediaBox).size, CGSize(width: 16, height: 12))
        XCTAssertEqual(pdf.page(at: 1)?.bounds(for: .mediaBox).size, CGSize(width: 20, height: 10))
        XCTAssertEqual(try [first, second].map(hash), originalHashes)
        XCTAssertEqual(try entries(beside: second), ["beta.png"])
        try assertNoStaging()
    }

    func testLaterInvalidImageRemovesPreparedEarlierResultWithoutPublishing() async throws {
        let first = try image(folder: "first", name: "alpha.png")
        let second = first.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("second/broken.png")
        try FileManager.default.createDirectory(at: second.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("invalid png".utf8).write(to: second)
        let hashes = try [first, second].map(hash)
        var settings = ToolSettings(); settings.width = 8; settings.height = 6
        do {
            _ = try await FileToolEngine.run(.init(tool: .cropImage, inputs: [first, second], outputDirectory: root, settings: settings, outputBesideInputs: true))
            XCTFail("Expected the second source to fail decoding")
        } catch { XCTAssertFalse(error is CancellationError) }
        XCTAssertEqual(try entries(beside: first), ["alpha.png"])
        XCTAssertEqual(try entries(beside: second), ["broken.png"])
        XCTAssertEqual(try [first, second].map(hash), hashes)
        try assertNoStaging()
    }

    func testLaterPublicationFailureRollsBackEarlierOutputAndKeepsCollisions() async throws {
        let first = try image(folder: "first", name: "alpha.png")
        let second = try image(folder: "second", name: "beta.png")
        let hashes = try [first, second].map(hash)
        let collisionBytes = Data("existing output".utf8)
        let destination = second.deletingLastPathComponent()
        // Exhaust the publisher's bounded name search to fail during publication,
        // after the first source's successful output has already been published.
        for index in 0..<10000 {
            let suffix = index == 0 ? "" : " (\(index + 1))"
            try collisionBytes.write(to: destination.appendingPathComponent("beta-cropImage\(suffix).png"))
        }
        var settings = ToolSettings(); settings.width = 8; settings.height = 6
        do {
            _ = try await FileToolEngine.run(.init(tool: .cropImage, inputs: [first, second], outputDirectory: root, settings: settings, outputBesideInputs: true))
            XCTFail("Expected exhausted output names")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Too many files"), error.localizedDescription) }
        XCTAssertEqual(try entries(beside: first), ["alpha.png"])
        XCTAssertEqual(try entries(beside: second).count, 10001)
        for index in 0..<10000 {
            let suffix = index == 0 ? "" : " (\(index + 1))"
            XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("beta-cropImage\(suffix).png")), collisionBytes)
        }
        XCTAssertEqual(try [first, second].map(hash), hashes)
        try assertNoStaging()
    }

    func testCancelledRequestLeavesNoNewFilesOrStaging() async throws {
        let input = try image(folder: "first", name: "alpha.png")
        let request = ToolRequest(tool: .cropImage, inputs: [input], outputDirectory: root, outputBesideInputs: true)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await FileToolEngine.run(request)
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(try entries(beside: input), ["alpha.png"])
        try assertNoStaging()
    }

    func testFolderCompressionStagesOutsideOriginalFolder() async throws {
        let folder = root.appendingPathComponent("original", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let input = folder.appendingPathComponent("keep.txt")
        let originalBytes = Data("keep the source".utf8)
        try originalBytes.write(to: input)
        let result = try await FileToolEngine.run(.init(tool: .compress, inputs: [folder], outputDirectory: folder.appendingPathComponent("unused"), outputBesideInputs: true))
        XCTAssertEqual(result.outputURLs.count, 1)
        XCTAssertEqual(canonical(result.outputURLs[0].deletingLastPathComponent()), canonical(root))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["keep.txt"])
        XCTAssertEqual(try Data(contentsOf: input), originalBytes)
        try assertNoStaging()
    }

    private func image(folder: String, name: String, width: Int = 16, height: Int = 12) throws -> URL {
        let directory = root.appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let canvas = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        canvas.setFillColor(CGColor(red: 0.1, green: 0.3, blue: 0.6, alpha: 1))
        canvas.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let url = directory.appendingPathComponent(name)
        try NativeImages.write(XCTUnwrap(canvas.makeImage()), destination: url, format: .png, quality: 1)
        return url
    }

    private func hash(_ url: URL) throws -> Data { Data(SHA256.hash(data: try Data(contentsOf: url))) }
    private func canonical(_ url: URL) -> String { url.resolvingSymlinksInPath().standardizedFileURL.path }
    private func entries(beside input: URL) throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: input.deletingLastPathComponent().path).sorted() }
    private func assertNoStaging() throws {
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        for case let url as URL in enumerator { XCTAssertFalse(url.lastPathComponent.hasPrefix(".shiftdrop-"), url.path) }
    }
}
