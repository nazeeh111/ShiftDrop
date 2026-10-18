import XCTest
import Foundation
import CoreGraphics
import CoreText
import ImageIO
import PDFKit
@testable import ShiftDropCore

final class ImageToolsTests: XCTestCase {
    var root: URL!
    var output: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ShiftDropImageTools-\(UUID().uuidString)")
        output = root.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    func testCropUsesExactTopLeftCoordinatesAndPreservesSource() async throws {
        let input = try fixture(); let original = try Data(contentsOf: input)
        var settings = ToolSettings(); settings.x = 3; settings.y = 0; settings.width = 12; settings.height = 8
        let result = try await run(.cropImage, [input], settings)
        let image = try decode(result.outputURLs[0])
        XCTAssertEqual(image.width, 12); XCTAssertEqual(image.height, 8)
        let pixel = try sample(image, x: 3, y: 2)
        XCTAssertGreaterThan(pixel.0, 240); XCTAssertLessThan(pixel.2, 10)
        XCTAssertEqual(try Data(contentsOf: input), original)
        try noStaging()
    }

    func testSVGCanBeCroppedUsedAsBackgroundAndOverlaid() async throws {
        let svg = root.appendingPathComponent("art.SVG")
        let source = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"40\" height=\"20\"><rect width=\"40\" height=\"10\" fill=\"#ff0000\"/><rect y=\"10\" width=\"40\" height=\"10\" fill=\"#0000ff\"/></svg>"
        try Data(source.utf8).write(to: svg)
        var settings = ToolSettings(); settings.x = 2; settings.y = 1; settings.width = 10; settings.height = 5
        let cropped = try await run(.cropImage, [svg], settings)
        let image = try decode(cropped.outputURLs[0])
        XCTAssertEqual(image.width, 10); XCTAssertEqual(image.height, 5)
        XCTAssertGreaterThan(try sample(image, x: 4, y: 2).0, 240)
        XCTAssertLessThan(try sample(image, x: 4, y: 2).2, 10)
        let input = try fixture()
        settings = ToolSettings(); settings.width = 80; settings.height = 40; settings.padding = 10; settings.backgroundImage = svg
        let framed = try await run(.frameImage, [input], settings)
        XCTAssertGreaterThan(try sample(decode(framed.outputURLs[0]), x: 1, y: 1).0, 240)
        settings = ToolSettings(); settings.marks = [.init(kind: "overlay", region: .init(x: 0, y: 0, width: 20, height: 10), imageURL: svg)]
        let annotated = try await run(.annotateImage, [input], settings)
        XCTAssertGreaterThan(try sample(decode(annotated.outputURLs[0]), x: 10, y: 8).2, 240)
        XCTAssertEqual(try String(contentsOf: svg, encoding: .utf8), source)
        try noStaging()
    }

    func testUnsafeSVGSourceBackgroundAndOverlayAreRejected() async throws {
        let svg = root.appendingPathComponent("unsafe.svg")
        try Data("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"40\" height=\"20\"><image href=\"https://example.com/art.png\"/></svg>".utf8).write(to: svg)
        let input = try fixture()
        for tool in [FileTool.cropImage, .frameImage, .annotateImage] {
            var settings = ToolSettings(); settings.width = 20; settings.height = 10
            if tool == .frameImage { settings.backgroundImage = svg; settings.padding = 0 }
            if tool == .annotateImage { settings.marks = [.init(kind: "overlay", region: .init(x: 0, y: 0, width: 20, height: 10), imageURL: svg)] }
            do { _ = try await run(tool, [tool == .cropImage ? svg : input], settings); XCTFail("Expected unsafe SVG rejection") }
            catch { XCTAssertTrue(error.localizedDescription.contains("SVG")) }
        }
        try noStaging()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: output.path), [])
    }

    func testSolidRedactionFlattensOnlySelectedTopLeftPixels() async throws {
        let input = try fixture()
        var settings = ToolSettings(); settings.x = 0; settings.y = 0; settings.width = 10; settings.height = 10; settings.colorHex = "00FF00"
        let result = try await run(.redactImage, [input], settings)
        let image = try decode(result.outputURLs[0])
        let mask = try sample(image, x: 3, y: 3), outside = try sample(image, x: 20, y: 3)
        XCTAssertGreaterThan(mask.1, 250); XCTAssertLessThan(mask.0, 5)
        XCTAssertGreaterThan(outside.0, 250); XCTAssertLessThan(outside.1, 5)
        settings.regions = [.init(x: 0, y: 0, width: 5, height: 5), .init(x: 30, y: 10, width: 10, height: 10)]
        let multiple = try await run(.redactImage, [input], settings)
        let masked = try decode(multiple.outputURLs[0])
        XCTAssertGreaterThan(try sample(masked, x: 2, y: 2).1, 250)
        XCTAssertGreaterThan(try sample(masked, x: 35, y: 15).1, 250)
        XCTAssertGreaterThan(try sample(masked, x: 20, y: 2).0, 250)
    }

    func testColorAdjustmentActuallyChangesPixels() async throws {
        let input = try fixture()
        var settings = ToolSettings(); settings.saturation = 0
        let result = try await run(.editImage, [input], settings)
        let value = try sample(decode(result.outputURLs[0]), x: 2, y: 2)
        XCTAssertEqual(value.0, value.1, accuracy: 2); XCTAssertEqual(value.1, value.2, accuracy: 2)
    }

    func testBrightnessSharpenAndNoiseReductionHaveDistinctEffects() async throws {
        let width = 128, height = 96
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let value = UInt8(80 + (x >= 64 ? 50 : 0) + ((x * 17 + y * 31) % 37))
            let index = (y * width + x) * 4
            bytes[index] = value; bytes[index + 1] = value; bytes[index + 2] = value
        } }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let source = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let input = root.appendingPathComponent("noisy.png"); try NativeImages.write(source, destination: input, format: .png, quality: 1)
        let unchanged = try rgba(source)
        for control in ["brightness", "sharpness", "noiseReduction", "dehaze", "clarity", "grain"] {
            var settings = ToolSettings()
            if control == "brightness" { settings.brightness = 0.2 }
            if control == "sharpness" { settings.sharpness = 1.5 }
            if control == "noiseReduction" { settings.noiseReduction = 1 }
            if control == "dehaze" { settings.dehaze = 1 }
            if control == "clarity" { settings.clarity = 1 }
            if control == "grain" { settings.grain = 1 }
            let result = try await run(.editImage, [input], settings)
            let actual = try rgba(decode(result.outputURLs[0]))
            let difference = zip(unchanged, actual).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
            XCTAssertGreaterThan(difference, 1000, control)
        }
    }

    func testFrameAndCollageHaveRequestedGeometryAndBackground() async throws {
        let input = try fixture()
        var settings = ToolSettings(); settings.width = 100; settings.height = 80; settings.padding = 10; settings.cornerRadius = 0; settings.backgroundHex = "00FF00"
        let framed = try await run(.frameImage, [input], settings)
        let image = try decode(framed.outputURLs[0]); XCTAssertEqual(image.width, 100); XCTAssertEqual(image.height, 80)
        XCTAssertGreaterThan(try sample(image, x: 0, y: 0).1, 250)
        settings.frameShadow = 12
        let shadowed = try await run(.frameImage, [input], settings)
        XCTAssertNotEqual(try rgba(image), try rgba(decode(shadowed.outputURLs[0])))
        settings.frameBlur = 10
        let blurred = try await run(.frameImage, [input], settings)
        XCTAssertNotEqual(try rgba(decode(shadowed.outputURLs[0])), try rgba(decode(blurred.outputURLs[0])))
        settings.width = 40; settings.height = 30; settings.columns = 2
        let combined = try await run(.collage, [input, input, input], settings)
        let collage = try decode(combined.outputURLs[0])
        XCTAssertEqual(collage.width, 110); XCTAssertEqual(collage.height, 90)
        XCTAssertGreaterThan(try sample(collage, x: 0, y: 0).1, 250)
    }

    func testEveryAnnotationModeDrawsPixelsAndRejectsTextOverflow() async throws {
        let input = try fixture(width: 300, height: 200)
        for annotation in ["text", "arrow", "rectangle", "ellipse"] {
            var settings = ToolSettings(); settings.annotation = annotation; settings.text = "HELLO"; settings.fontSize = 20; settings.colorHex = "00FF00"
            settings.x = 10; settings.y = 10; settings.width = 200; settings.height = 80
            let result = try await run(.annotateImage, [input], settings)
            let image = try decode(result.outputURLs[0])
            let pixels = try rgba(image)
            var green = 0
            for y in stride(from: 10, to: 90, by: 2) {
                for x in stride(from: 10, to: 210, by: 2) {
                    let index = (y * image.width + x) * 4
                    if pixels[index + 1] > 180 && pixels[index] < 80 && pixels[index + 2] < 80 { green += 1 }
                }
            }
            XCTAssertGreaterThan(green, 5, annotation)
        }
        var settings = ToolSettings(); settings.width = 2; settings.height = 2
        do { _ = try await run(.annotateImage, [input], settings); XCTFail("Expected text overflow") }
        catch { XCTAssertTrue(error.localizedDescription.contains("fit")) }
    }

    func testArrowQuarterTurnsMoveTheArrowhead() async throws {
        let input = try fixture(width: 300, height: 200)
        var variants: [[UInt8]] = []
        for rotation in [0, 90, 180, 270] {
            var settings = ToolSettings(); settings.annotation = "arrow"; settings.rotation = rotation
            settings.width = 180; settings.height = 100; settings.x = 20; settings.y = 20; settings.colorHex = "00FF00"
            let result = try await run(.annotateImage, [input], settings)
            variants.append(try rgba(decode(result.outputURLs[0])))
        }
        for first in 0..<4 { for second in (first + 1)..<4 { XCTAssertNotEqual(variants[first], variants[second]) } }
    }

    func testLayerOrderOverlayFreehandAndHighlight() async throws {
        let input = try fixture()
        let source = try decode(input)
        let blue = try XCTUnwrap(source.cropping(to: CGRect(x: 0, y: 10, width: 20, height: 10)))
        let overlay = root.appendingPathComponent("overlay.png"); try NativeImages.write(blue, destination: overlay, format: .png, quality: 1)
        let image = ImageMark(kind: "overlay", region: .init(x: 0, y: 0, width: 20, height: 10), imageURL: overlay)
        let path = ImageMark(kind: "freehand", region: .init(x: 0, y: 0, width: 1, height: 1), colorHex: "00FF00", lineWidth: 4,
            points: [.init(x: 0, y: 5), .init(x: 19, y: 5)])
        let highlight = ImageMark(kind: "highlight", region: .init(x: 0, y: 0, width: 1, height: 1), colorHex: "FFFF00", lineWidth: 4,
            points: [.init(x: 0, y: 15), .init(x: 39, y: 15)])
        var settings = ToolSettings(); settings.marks = [image, path, highlight]
        let layered = try await run(.annotateImage, [input], settings)
        let rendered = try decode(layered.outputURLs[0])
        XCTAssertGreaterThan(try sample(rendered, x: 10, y: 5).1, 240)
        XCTAssertGreaterThan(try sample(rendered, x: 10, y: 0).2, 240)
        XCTAssertGreaterThan(try sample(rendered, x: 30, y: 5).0, 240)
        let highlightedBlue = try sample(rendered, x: 20, y: 15).2
        XCTAssertLessThan(highlightedBlue, 240); XCTAssertGreaterThan(highlightedBlue, 100)
        settings.marks = [path, image]
        let reversed = try await run(.annotateImage, [input], settings)
        XCTAssertGreaterThan(try sample(decode(reversed.outputURLs[0]), x: 10, y: 5).2, 240)
    }

    func testNumberedMarkerAndMagnifierRenderIndependently() async throws {
        let input = try fixture(width: 200, height: 100)
        var settings = ToolSettings(); settings.annotation = "marker"; settings.text = "2"; settings.colorHex = "00FF00"
        settings.x = 10; settings.y = 10; settings.width = 60; settings.height = 60
        let marker = try await run(.annotateImage, [input], settings)
        let rendered = try decode(marker.outputURLs[0])
        XCTAssertGreaterThan(try sample(rendered, x: 40, y: 15).1, 240)
        settings.annotation = "magnifier"; settings.x = 30; settings.y = 20; settings.width = 100; settings.height = 60
        let magnified = try await run(.annotateImage, [input], settings)
        XCTAssertNotEqual(try rgba(decode(input)), try rgba(decode(magnified.outputURLs[0])))
    }

    func testImagesPDFCombinesOrderedPagesWithNativeDimensions() async throws {
        let first = try fixture(width: 40, height: 20, name: "first.png")
        let second = try fixture(width: 50, height: 30, name: "second.png")
        let result = try await run(.imagesPDF, [first, second])
        let pdf = try XCTUnwrap(PDFDocument(url: result.outputURLs[0]))
        XCTAssertEqual(pdf.pageCount, 2)
        XCTAssertEqual(pdf.page(at: 0)?.bounds(for: .mediaBox).size, CGSize(width: 40, height: 20))
        XCTAssertEqual(pdf.page(at: 1)?.bounds(for: .mediaBox).size, CGSize(width: 50, height: 30))
    }

    func testTargetByteCompressionMeetsBudgetAndImpossibleTargetCleansUp() async throws {
        let input = try fixture(width: 1000, height: 600)
        var settings = ToolSettings(); settings.targetBytes = 2000
        let result = try await run(.compress, [input], settings)
        XCTAssertLessThanOrEqual(result.outputBytes, 2000)
        XCTAssertNotNil(CGImageSourceCreateWithURL(result.outputURLs[0] as CFURL, nil))
        settings.targetBytes = 10
        do { _ = try await run(.compress, [input], settings); XCTFail("Expected impossible target error") }
        catch { XCTAssertTrue(error.localizedDescription.contains("target")) }
        try noStaging()
    }

    func testCompressionBoundsPreserveRatioAndNeverEnlarge() async throws {
        let input = try fixture(width: 200, height: 100)
        var settings = ToolSettings(); settings.width = 80; settings.height = 80
        let resized = try await run(.compress, [input], settings)
        let small = try decode(resized.outputURLs[0]); XCTAssertEqual(small.width, 80); XCTAssertEqual(small.height, 40)
        settings.width = 800; settings.height = 800
        let unchanged = try await run(.compress, [input], settings)
        let large = try decode(unchanged.outputURLs[0]); XCTAssertEqual(large.width, 200); XCTAssertEqual(large.height, 100)
    }

    func testMetadataInspectTitleAndStripAreReal() async throws {
        let input = try fixture(); let original = try Data(contentsOf: input)
        var settings = ToolSettings(); settings.removeMetadata = false; settings.metadataTitle = "Private fixture"
        let edited = try await run(.metadata, [input], settings)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(edited.outputURLs[0] as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
        let png = properties[kCGImagePropertyPNGDictionary as String] as? [String: Any]
        XCTAssertEqual(png?[kCGImagePropertyPNGTitle as String] as? String, "Private fixture")
        settings.metadataTitle = ""
        let inspected = try await run(.metadata, edited.outputURLs, settings)
        let report = try String(contentsOf: inspected.outputURLs[0], encoding: .utf8)
        XCTAssertTrue(report.contains("Private fixture")); XCTAssertTrue(report.contains("PixelWidth"))
        settings.removeMetadata = true
        let stripped = try await run(.metadata, edited.outputURLs, settings)
        let clean = try XCTUnwrap(CGImageSourceCreateWithURL(stripped.outputURLs[0] as CFURL, nil))
        let cleanProperties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(clean, 0, nil) as? [String: Any])
        let cleanPNG = cleanProperties[kCGImagePropertyPNGDictionary as String] as? [String: Any]
        XCTAssertNil(cleanPNG?[kCGImagePropertyPNGTitle as String])
        XCTAssertEqual(try Data(contentsOf: input), original)
    }

    func testAutomaticTextRedactionMasksRecognizedText() async throws {
        let canvas = try XCTUnwrap(CGContext(data: nil, width: 600, height: 150, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        canvas.setFillColor(CGColor(gray: 1, alpha: 1)); canvas.fill(CGRect(x: 0, y: 0, width: 600, height: 150))
        let text = NSAttributedString(string: "PRIVATE 12345", attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica-Bold" as CFString, 48, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)])
        canvas.textPosition = CGPoint(x: 30, y: 50); CTLineDraw(CTLineCreateWithAttributedString(text), canvas)
        let input = root.appendingPathComponent("text.png")
        try NativeImages.write(XCTUnwrap(canvas.makeImage()), destination: input, format: .png, quality: 1)
        var settings = ToolSettings(); settings.detectText = true; settings.colorHex = "FF0000"
        let result = try await run(.redactImage, [input], settings)
        let image = try decode(result.outputURLs[0])
        let pixels = try rgba(image)
        var red = 0
        for y in stride(from: 0, to: 150, by: 3) {
            for x in stride(from: 0, to: 600, by: 3) {
                let index = (y * image.width + x) * 4
                if pixels[index] > 240 && pixels[index + 1] < 10 && pixels[index + 2] < 10 { red += 1 }
            }
        }
        XCTAssertGreaterThan(red, 200)
    }

    func testInvalidGeometryColorAndNaNAreRejectedWithoutPublishedOutputs() async throws {
        let input = try fixture()
        var settings = ToolSettings(); settings.x = Int.max; settings.width = Int.max
        do { _ = try await run(.cropImage, [input], settings); XCTFail("Expected invalid rectangle") } catch {}
        settings = ToolSettings(); settings.width = 80; settings.height = 80; settings.backgroundHex = "oops"
        do { _ = try await run(.frameImage, [input], settings); XCTFail("Expected invalid color") } catch {}
        settings = ToolSettings(); settings.exposure = .nan
        do { _ = try await run(.editImage, [input], settings); XCTFail("Expected nonfinite rejection") } catch {}
        try noStaging()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: output.path), [])
    }

    func testCancellationAndSymbolicLinksCannotPublishOutputs() async throws {
        let input = try fixture()
        let request = ToolRequest(tool: .editImage, inputs: [input], outputDirectory: output)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ImageTools.run(request)
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        let link = root.appendingPathComponent("linked.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: input)
        do { _ = try await run(.editImage, [link]); XCTFail("Expected symbolic-link rejection") }
        catch { XCTAssertTrue(error.localizedDescription.contains("regular")) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    private func run(_ tool: FileTool, _ inputs: [URL], _ settings: ToolSettings = ToolSettings()) async throws -> ConversionResult {
        try await ImageTools.run(.init(tool: tool, inputs: inputs, outputDirectory: output, settings: settings))
    }
    private func fixture(width: Int = 40, height: Int = 20, name: String = "input.png") throws -> URL {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let offset = (y * width + x) * 4
            bytes[offset] = y < height / 2 ? 255 : 0
            bytes[offset + 1] = 0
            bytes[offset + 2] = y < height / 2 ? 0 : 255
        } }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let image = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let input = root.appendingPathComponent(name); try NativeImages.write(image, destination: input, format: .png, quality: 1)
        return input
    }
    private func decode(_ url: URL) throws -> CGImage {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }
    private func sample(_ image: CGImage, x: Int, y: Int) throws -> (Double, Double, Double) {
        let pixels = try rgba(image)
        let offset = (y * image.width + x) * 4
        return (Double(pixels[offset]), Double(pixels[offset + 1]), Double(pixels[offset + 2]))
    }
    private func rgba(_ image: CGImage) throws -> [UInt8] {
        // Normalize to a known RGBA pixel layout before reading encoded PNGs.
        let canvas = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        canvas.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let pixels = try XCTUnwrap(canvas.data).assumingMemoryBound(to: UInt8.self)
        return Array(UnsafeBufferPointer(start: pixels, count: image.width * image.height * 4))
    }
    private func noStaging() throws {
        let entries = try FileManager.default.contentsOfDirectory(atPath: output.path)
        XCTAssertFalse(entries.contains { $0.hasPrefix(".shiftdrop-") })
    }
}
