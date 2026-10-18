import XCTest
import Foundation
import PDFKit
import CoreGraphics
import CoreText
@testable import ShiftDropCore

final class PDFToolsTests: XCTestCase {
    private var root: URL!
    private var output: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ShiftDropPDF-\(UUID().uuidString)")
        output = root.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    func testMergeKeepsPagesTextAnnotationsAndOriginals() async throws {
        let first = try fixture("first", texts: ["Page One", "Page Two"])
        let second = try fixture("second", texts: ["Page Three"])
        let bytes = try [first, second].map { try Data(contentsOf: $0) }
        let document = try XCTUnwrap(PDFDocument(url: first))
        let note = PDFAnnotation(bounds: CGRect(x: 12, y: 12, width: 20, height: 20), forType: .text, withProperties: nil)
        note.contents = "Keep annotation"
        document.page(at: 0)?.addAnnotation(note)
        XCTAssertTrue(document.write(to: first))
        let annotatedBytes = try Data(contentsOf: first)
        var settings = ToolSettings(); settings.removeMetadata = false
        let result = try await run(.mergePDF, [first, second], settings)
        let merged = try XCTUnwrap(PDFDocument(url: result.outputURLs[0]))
        XCTAssertEqual(merged.pageCount, 3)
        XCTAssertTrue(merged.page(at: 0)?.string?.contains("Page One") == true)
        XCTAssertTrue(merged.page(at: 2)?.string?.contains("Page Three") == true)
        XCTAssertEqual(merged.page(at: 0)?.annotations.first?.contents, "Keep annotation")
        XCTAssertEqual(try Data(contentsOf: first), annotatedBytes)
        XCTAssertEqual(try Data(contentsOf: second), bytes[1])
        try clean()
    }

    func testRangeOrderingRepeatsAndIndependentOutputRotations() async throws {
        let input = try fixture("source", texts: ["Page One", "Page Two", "Page Three"])
        let source = try XCTUnwrap(PDFDocument(url: input)); source.page(at: 1)?.rotation = 90
        XCTAssertTrue(source.write(to: input))
        let original = try Data(contentsOf: input)
        var s = ToolSettings(); s.pageOrder = "3-2, 1, 2-3, 1"; s.rotation = 90; s.pageRotations = "1:180,3:-90,6:180"
        let result = try await run(.organizePDF, [input], s)
        let organized = try XCTUnwrap(PDFDocument(url: result.outputURLs[0]))
        XCTAssertEqual(organized.pageCount, 6)
        let expectedText = ["Three", "Two", "One", "Two", "Three", "One"]
        let expectedRotations = [270, 180, 0, 180, 90, 270]
        for index in 0..<6 {
            XCTAssertTrue(organized.page(at: index)?.string?.contains(expectedText[index]) == true)
            XCTAssertEqual(organized.page(at: index)?.rotation, expectedRotations[index])
        }
        XCTAssertEqual(try Data(contentsOf: input), original)
        try clean()
    }

    func testMetadataReportRemovalTitleAndRasterizedGeometry() async throws {
        let input = try fixture("source", texts: ["Page One", "Page Two"])
        let originalDocument = try XCTUnwrap(PDFDocument(url: input)); originalDocument.page(at: 0)?.rotation = 90
        XCTAssertTrue(originalDocument.write(to: input))
        let original = try Data(contentsOf: input)
        var s = ToolSettings(); s.removeMetadata = false
        let report = try await run(.metadata, [input], s).outputURLs[0]
        let reportData = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: report)) as? [String: Any])
        XCTAssertEqual(reportData["pageCount"] as? Int, 2)
        XCTAssertTrue(try String(contentsOf: report).contains("Secret PDF title"))
        s.removeMetadata = true; s.metadataTitle = "New title"
        let edited = try await run(.metadata, [input], s).outputURLs[0]
        let editedDocument = try XCTUnwrap(PDFDocument(url: edited))
        XCTAssertEqual(editedDocument.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String, "New title")
        XCTAssertFalse(String(describing: editedDocument.documentAttributes).contains("Secret author"))
        s.width = 256; s.quality = 0.6
        let raster = try await run(.compress, [input], s).outputURLs[0]
        let rasterDocument = try XCTUnwrap(PDFDocument(url: raster))
        XCTAssertEqual(rasterDocument.pageCount, 2)
        XCTAssertFalse(rasterDocument.string?.contains("Page One") == true)
        let bounds = try XCTUnwrap(rasterDocument.page(at: 0)).bounds(for: .mediaBox)
        XCTAssertEqual(bounds.width, 100, accuracy: 0.01); XCTAssertEqual(bounds.height, 200, accuracy: 0.01)
        let page = try XCTUnwrap(rasterDocument.page(at: 0)?.pageRef)
        let image = try XCTUnwrap(CGContext(data: nil, width: 100, height: 200, bitsPerComponent: 8, bytesPerRow: 400, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        image.drawPDFPage(page)
        let pixels = try XCTUnwrap(image.data).assumingMemoryBound(to: UInt8.self)
        XCTAssertGreaterThan(pixels[(180 * 100 + 50) * 4], 200)
        XCTAssertEqual(try Data(contentsOf: input), original)
        try clean()
    }

    func testValidationCancellationAndExistingOutputs() async throws {
        let input = try fixture("source", texts: ["Page One", "Page Two", "Page Three"])
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let sentinel = output.appendingPathComponent("source-organizePDF.pdf")
        try Data("existing output".utf8).write(to: sentinel)
        _ = try await run(.organizePDF, [input])
        XCTAssertEqual(try String(contentsOf: sentinel), "existing output")
        for order in ["1-4", "-1", "1,,2", "1-2-3", Array(repeating: "1", count: 1001).joined(separator: ",")] {
            var s = ToolSettings(); s.pageOrder = order
            do { _ = try await run(.organizePDF, [input], s); XCTFail("Expected page-order validation: \(order.prefix(20))") } catch { XCTAssertTrue(error is ConversionError) }
        }
        for rotations in ["4:90", "1:20", "1:90,1:180"] {
            var s = ToolSettings(); s.pageRotations = rotations
            do { _ = try await run(.organizePDF, [input], s); XCTFail("Expected rotation validation") } catch { XCTAssertTrue(error is ConversionError) }
        }
        let cancelled = Task { withUnsafeCurrentTask { $0?.cancel() }; return try await self.run(.organizePDF, [input]) }
        do { _ = try await cancelled.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        try clean()
    }

    private func run(_ tool: FileTool, _ inputs: [URL], _ settings: ToolSettings = ToolSettings()) async throws -> ConversionResult {
        try await PDFTools.run(ToolRequest(tool: tool, inputs: inputs, outputDirectory: output, settings: settings))
    }
    private func fixture(_ name: String, texts: [String]) throws -> URL {
        let url = root.appendingPathComponent(name + ".pdf")
        var box = CGRect(x: 0, y: 0, width: 200, height: 100)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, [kCGPDFContextTitle: "Secret PDF title", kCGPDFContextAuthor: "Secret author"] as CFDictionary))
        for (index, text) in texts.enumerated() {
            context.beginPDFPage(nil)
            context.setFillColor(index == 0 ? CGColor(red: 1, green: 0, blue: 0, alpha: 1) : CGColor(red: 0, green: 0, blue: 1, alpha: 1)); context.fill(box)
            context.textMatrix = .identity; context.textPosition = CGPoint(x: 15, y: 50)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 16, nil), NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1)]))
            CTLineDraw(line, context)
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }
    private func clean() throws {
        if FileManager.default.fileExists(atPath: output.path) { XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: output.path).contains { $0.hasPrefix(".shiftdrop-") }) }
    }
}
