import XCTest
import Foundation
import ImageIO
import CoreGraphics
import CoreText
import PDFKit
import AppKit
@testable import ShiftDropCore

final class ConversionEngineTests: XCTestCase {
    var root: URL!
    var output: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ShiftDropTests-\(UUID().uuidString)")
        output = root.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    func testAllNativeImageEncodersProduceDecodableFilesAndPreserveSource() async throws {
        let input = try makeImage()
        let original = try Data(contentsOf: input)
        let formats = FormatCatalog.formats(for: input).filter { FormatCatalog.imageFormats.contains($0) }
        XCTAssertTrue(formats.contains(.png))
        XCTAssertTrue(formats.contains(.jpeg))
        for format in formats {
            let result = try await ConversionEngine().convert(input: input, to: format, outputDirectory: output)
            XCTAssertEqual(result.outputURLs.count, 1)
            let image = try decode(result.outputURLs[0])
            XCTAssertEqual(image.width, 40, format.rawValue)
            XCTAssertEqual(image.height, 20, format.rawValue)
            XCTAssertGreaterThan(result.outputBytes, 0)
            XCTAssertEqual(result.inputBytes, Int64(original.count))
        }
        XCTAssertEqual(try Data(contentsOf: input), original)
        try assertNoStaging()
    }

    func testResizeAndOrientationAreAppliedBeforeEncoding() async throws {
        let source = try makeImage(format: .jpeg, orientation: 6)
        let result = try await ConversionEngine().convert(input: source, to: .png, outputDirectory: output, options: .init(maxPixelSize: 10))
        let image = try decode(result.outputURLs[0])
        XCTAssertEqual(image.width, 5)
        XCTAssertEqual(image.height, 10)
    }

    func testTransparentJPEGFlattensAgainstWhite() async throws {
        let input = try makeImage(transparent: true)
        let result = try await ConversionEngine().convert(input: input, to: .jpeg, outputDirectory: output, options: .init(quality: 1))
        let pixel = try pixels(decode(result.outputURLs[0]))
        XCTAssertGreaterThan(pixel[0], 245)
        XCTAssertGreaterThan(pixel[1], 245)
        XCTAssertGreaterThan(pixel[2], 245)
    }

    func testImagePDFIsReadableAndOriginalSurvivesDestinationCollision() async throws {
        let input = try makeImage()
        let original = try Data(contentsOf: input)
        let result = try await ConversionEngine().convert(input: input, to: .pdf, outputDirectory: root)
        XCTAssertEqual(PDFDocument(url: result.outputURLs[0])?.pageCount, 1)
        let reencoded = try await ConversionEngine().convert(input: input, to: .png, outputDirectory: root)
        XCTAssertNotEqual(reencoded.outputURLs[0], input)
        XCTAssertEqual(try Data(contentsOf: input), original)
    }

    func testMultipagePDFProducesEveryPageAndSelectableText() async throws {
        let input = try makePDF()
        let original = try Data(contentsOf: input)
        let result = try await ConversionEngine().convert(input: input, to: .png, outputDirectory: output, options: .init(maxPixelSize: 100))
        XCTAssertEqual(result.outputURLs.count, 2)
        XCTAssertEqual(Set(result.outputURLs.map(\.lastPathComponent)), Set(["sample-page-1.png", "sample-page-2.png"]))
        for page in result.outputURLs {
            let image = try decode(page)
            XCTAssertLessThanOrEqual(max(image.width, image.height), 100)
        }
        let textResult = try await ConversionEngine().convert(input: input, to: .txt, outputDirectory: output)
        let text = try String(contentsOf: textResult.outputURLs[0], encoding: .utf8)
        XCTAssertTrue(text.contains("Page one"), text)
        XCTAssertTrue(text.contains("Page two"), text)
        XCTAssertEqual(try Data(contentsOf: input), original)
    }

    func testScannedPDFTextHasSpecificErrorAndNoOutput() async throws {
        let image = try makeImage()
        let pdf = try await ConversionEngine().convert(input: image, to: .pdf, outputDirectory: root)
        do {
            _ = try await ConversionEngine().convert(input: pdf.outputURLs[0], to: .txt, outputDirectory: output)
            XCTFail("Expected no-selectable-text error")
        } catch { XCTAssertTrue(error.localizedDescription.contains("selectable text"), error.localizedDescription) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: output.path), [])
    }

    func testPDFRotationAndNonzeroMediaBoxOriginRenderFullPage() async throws {
        for rotation in [0, 90, 270] {
            let input = root.appendingPathComponent("offset-\(rotation).pdf")
            // Hand-authored PDF keeps the source coordinates and box independently explicit.
            let stream = "q\n1 0 0 rg\n30 40 200 100 re f\nQ\n"
            let objects = [
                "<< /Type /Catalog /Pages 2 0 R >>",
                "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
                "<< /Type /Page /Parent 2 0 R /MediaBox [30 40 230 140] /Rotate \(rotation) /Resources << >> /Contents 4 0 R >>",
                "<< /Length \(stream.utf8.count) >>\nstream\n\(stream)endstream"
            ]
            var pdf = "%PDF-1.4\n"
            var offsets: [Int] = []
            for (index, object) in objects.enumerated() {
                offsets.append(pdf.utf8.count)
                pdf += "\(index + 1) 0 obj\n\(object)\nendobj\n"
            }
            let xref = pdf.utf8.count
            pdf += "xref\n0 5\n0000000000 65535 f \n"
            for offset in offsets { pdf += String(format: "%010d 00000 n \n", offset) }
            pdf += "trailer\n<< /Size 5 /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
            try Data(pdf.utf8).write(to: input)
            let result = try await ConversionEngine().convert(input: input, to: .png, outputDirectory: output)
            let image = try decode(result.outputURLs[0])
            XCTAssertEqual(image.width, rotation == 0 ? 400 : 200)
            XCTAssertEqual(image.height, rotation == 0 ? 200 : 400)
            let bytes = try pixels(image)
            for (x, y) in [(0, 0), (image.width - 1, 0), (0, image.height - 1), (image.width - 1, image.height - 1), (image.width / 2, image.height / 2)] {
                let index = (y * image.width + x) * 4
                XCTAssertGreaterThan(bytes[index], 245, "rotation \(rotation), pixel \(x),\(y)")
                XCTAssertLessThan(bytes[index + 1], 5, "rotation \(rotation), pixel \(x),\(y)")
                XCTAssertLessThan(bytes[index + 2], 5, "rotation \(rotation), pixel \(x),\(y)")
            }
        }
    }

    func testTextRTFHTMLRoundTripEscapesContentAndStaysOffline() async throws {
        let original = "Hello, 世界 & <safe>\nSecond line."
        let input = try fixture("writing.txt", Data(original.utf8))
        let rtf = try await ConversionEngine().convert(input: input, to: .rtf, outputDirectory: output).outputURLs[0]
        let html = try await ConversionEngine().convert(input: rtf, to: .html, outputDirectory: output).outputURLs[0]
        let htmlSource = try String(contentsOf: html, encoding: .utf8)
        XCTAssertTrue(htmlSource.contains("&lt;safe&gt;"))
        let txt = try await ConversionEngine().convert(input: html, to: .txt, outputDirectory: output).outputURLs[0]
        XCTAssertEqual(try String(contentsOf: txt, encoding: .utf8), original)
        let malicious = try fixture("offline.html", Data("<head><title>Ignore me</title></head><p>A &amp; B &#x1F680;</p><script>fetch('https://example.invalid')</script><style>p{color:red}</style>".utf8))
        let plain = try await ConversionEngine().convert(input: malicious, to: .txt, outputDirectory: output).outputURLs[0]
        XCTAssertEqual(try String(contentsOf: plain, encoding: .utf8), "A & B 🚀")
    }

    func testUTF16TextAndInvalidEncoding() async throws {
        let value = "Unicode ✓"
        let input = try fixture("utf16.txt", value.data(using: .utf16)!)
        let result = try await ConversionEngine().convert(input: input, to: .txt, outputDirectory: output)
        XCTAssertEqual(try String(contentsOf: result.outputURLs[0], encoding: .utf8), value)
        let bad = try fixture("invalid.txt", Data([0xC0, 0x80, 0xFF]))
        do { _ = try await ConversionEngine().convert(input: bad, to: .txt, outputDirectory: output); XCTFail("Expected encoding failure") }
        catch { XCTAssertTrue(error.localizedDescription.contains("UTF-8")) }
    }

    func testSubtitlePrecisionAndRoundTrip() async throws {
        let original = "1\r\n00:00:01,007 --> 00:00:02,999\r\nHello <i>world</i>.\r\n\r\n2\r\n25:01:02,003 --> 25:01:03,004\r\nSecond\r\nline\r\n"
        let input = try fixture("sample.srt", Data(original.utf8))
        let web = try await ConversionEngine().convert(input: input, to: .vtt, outputDirectory: output).outputURLs[0]
        let vtt = try String(contentsOf: web, encoding: .utf8)
        XCTAssertTrue(vtt.hasPrefix("WEBVTT\n\n"))
        XCTAssertTrue(vtt.contains("25:01:02.003 --> 25:01:03.004"))
        let srt = try await ConversionEngine().convert(input: web, to: .srt, outputDirectory: output).outputURLs[0]
        XCTAssertEqual(try String(contentsOf: srt, encoding: .utf8), original.replacingOccurrences(of: "\r\n", with: "\n"))
        let txt = try await ConversionEngine().convert(input: web, to: .txt, outputDirectory: output).outputURLs[0]
        XCTAssertEqual(try String(contentsOf: txt, encoding: .utf8), "Hello world.\n\nSecond\nline")
        XCTAssertEqual(try Data(contentsOf: input), Data(original.utf8))
    }

    func testVTTShortTimestampsSettingsNotesAndMalformedCues() async throws {
        let input = try fixture("short.vtt", Data("WEBVTT\n\nNOTE explanation\nignored\n\nidentifier\n01:02.003 --> 01:04.005 align:start\nCaption\n".utf8))
        let result = try await ConversionEngine().convert(input: input, to: .srt, outputDirectory: output)
        XCTAssertEqual(try String(contentsOf: result.outputURLs[0], encoding: .utf8), "1\n00:01:02,003 --> 00:01:04,005\nCaption\n")
        for malformed in ["1\n00:00:02,000 --> 00:00:01,000\nNo", "1\n00:61:00,000 --> 00:62:00,000\nNo", "1\n00:00:00,000 --> 00:00:01,000", "garbage"] {
            let bad = try fixture("bad.srt", Data(malformed.utf8))
            do { _ = try await ConversionEngine().convert(input: bad, to: .vtt, outputDirectory: output); XCTFail("Expected subtitle failure") }
            catch { XCTAssertTrue(error.localizedDescription.contains("cue")) }
        }
    }

    func testConcurrentPublicationNeverOverwritesExistingFile() async throws {
        let input = try makeImage()
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let sentinel = output.appendingPathComponent("sample.jpg")
        try Data("KEEP THIS".utf8).write(to: sentinel)
        let urls = try await withThrowingTaskGroup(of: URL.self) { group in
            for _ in 0..<12 {
                group.addTask { [input, output = output!] in
                    try await ConversionEngine().convert(input: input, to: .jpeg, outputDirectory: output).outputURLs[0]
                }
            }
            var result: [URL] = []
            for try await url in group { result.append(url) }
            return result
        }
        XCTAssertEqual(Set(urls).count, 12)
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("KEEP THIS".utf8))
        for url in urls { XCTAssertEqual(try decode(url).width, 40) }
        try assertNoStaging()
    }

    func testZIPIncludesFolderAndRejectsSymlinksAndRecursiveDestination() async throws {
        let folder = root.appendingPathComponent("Folder with spaces")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let contents = Data("archive payload".utf8)
        let input = folder.appendingPathComponent("file ; $(touch hacked).txt")
        try contents.write(to: input)
        let zip = try await ConversionEngine().convert(input: folder, to: .zip, outputDirectory: output)
        let extracted = root.appendingPathComponent("extracted")
        try await ProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/ditto"), arguments: ["-x", "-k", zip.outputURLs[0].path, extracted.path])
        XCTAssertEqual(try Data(contentsOf: extracted.appendingPathComponent(folder.lastPathComponent).appendingPathComponent(input.lastPathComponent)), contents)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("hacked").path))
        do { _ = try await ConversionEngine().convert(input: folder, to: .zip, outputDirectory: folder); XCTFail("Expected recursion rejection") }
        catch { XCTAssertTrue(error.localizedDescription.contains("outside")) }
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("link"), withDestinationURL: input)
        do { _ = try await ConversionEngine().convert(input: folder, to: .zip, outputDirectory: output); XCTFail("Expected symlink rejection") }
        catch { XCTAssertTrue(error.localizedDescription.contains("symbolic link")) }
        XCTAssertEqual(try Data(contentsOf: input), contents)
        try assertNoStaging()
    }

    func testMalformedImageUnsupportedRouteAndInvalidOptions() async throws {
        let bad = try fixture("bad.png", Data("not a PNG".utf8))
        do { _ = try await ConversionEngine().convert(input: bad, to: .jpeg, outputDirectory: output); XCTFail("Expected decode failure") }
        catch { XCTAssertTrue(error.localizedDescription.contains("image")) }
        let input = try makeImage()
        do { _ = try await ConversionEngine().convert(input: input, to: .mp3, outputDirectory: output); XCTFail("Expected unsupported route") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Unsupported")) }
        for option in [ConversionOptions(quality: .nan), .init(quality: 2), .init(maxPixelSize: 0), .init(maxPixelSize: 20000)] {
            do { _ = try await ConversionEngine().convert(input: input, to: .jpeg, outputDirectory: output, options: option); XCTFail("Expected invalid settings") }
            catch { XCTAssertTrue(error.localizedDescription.contains("settings")) }
        }
        try assertNoStaging()
    }

    func testPreCancelledConversionPublishesNothing() async throws {
        let input = try makeImage()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ConversionEngine().convert(input: input, to: .jpeg, outputDirectory: output)
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testSubprocessCancellationIsPromptAndDiagnosticOutputCannotDeadlock() async throws {
        let started = Date()
        let task = Task { try await ProcessRunner.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["20"]) }
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        do { try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        // An argument array is passed directly, without invoking a shell.
        do {
            try await ProcessRunner.run(executable: URL(fileURLWithPath: "/bin/ls"), arguments: ["-d"] + (0..<100).map { "/nonexistent-\($0)-" + String(repeating: "x", count: 1000) })
            XCTFail("Expected diagnostic failure")
        } catch {
            XCTAssertLessThan(error.localizedDescription.utf8.count, 20_000)
            XCTAssertTrue(error.localizedDescription.contains("Conversion failed"))
        }
    }

    func testOptionalFFmpegProducesDecodableAudioVideoAndGIF() async throws {
        guard let ffmpeg = FormatCatalog.ffmpegURL else { throw XCTSkip("FFmpeg is optional and is not installed.") }
        let audio = root.appendingPathComponent("tone.wav")
        try await ProcessRunner.run(executable: ffmpeg, arguments: ["-hide_banner", "-loglevel", "error", "-nostdin", "-f", "lavfi", "-i", "sine=frequency=440:duration=0.25", "-c:a", "pcm_s16le", audio.path])
        let originalAudio = try Data(contentsOf: audio)
        for format: ConversionFormat in [.m4a, .mp3, .wav, .flac] {
            let converted = try await ConversionEngine().convert(input: audio, to: format, outputDirectory: output)
            try await ProcessRunner.run(executable: ffmpeg, arguments: ["-hide_banner", "-loglevel", "error", "-nostdin", "-i", converted.outputURLs[0].path, "-f", "null", "-"])
            XCTAssertGreaterThan(converted.outputBytes, 0)
        }
        XCTAssertEqual(try Data(contentsOf: audio), originalAudio)
        let video = root.appendingPathComponent("motion.mp4")
        try await ProcessRunner.run(executable: ffmpeg, arguments: ["-hide_banner", "-loglevel", "error", "-nostdin", "-f", "lavfi", "-i", "testsrc=size=80x40:rate=12:duration=0.25", "-c:v", "libx264", "-pix_fmt", "yuv420p", video.path])
        let originalVideo = try Data(contentsOf: video)
        for format: ConversionFormat in [.mp4, .mov, .gif] {
            let converted = try await ConversionEngine().convert(input: video, to: format, outputDirectory: output, options: .init(maxPixelSize: 32))
            try await ProcessRunner.run(executable: ffmpeg, arguments: ["-hide_banner", "-loglevel", "error", "-nostdin", "-i", converted.outputURLs[0].path, "-f", "null", "-"])
            if format == .gif {
                let decoded = try decode(converted.outputURLs[0])
                XCTAssertEqual(decoded.width, 32)
                XCTAssertEqual(decoded.height, 16)
            }
        }
        XCTAssertEqual(try Data(contentsOf: video), originalVideo)
        try assertNoStaging()
    }

    func testFFmpegRejectsNetworkInputProtocolsAndMalformedMedia() async throws {
        guard FormatCatalog.ffmpegURL != nil else { throw XCTSkip("FFmpeg is optional and is not installed.") }
        let playlist = try fixture("network.mp4", Data("#EXTM3U\n#EXT-X-TARGETDURATION:1\n#EXTINF:1,\nhttps://example.invalid/segment.ts\n#EXT-X-ENDLIST\n".utf8))
        do { _ = try await ConversionEngine().convert(input: playlist, to: .mp4, outputDirectory: output); XCTFail("Expected network protocol rejection") }
        catch {
            // Current FFmpeg rejects disguised playlists before opening their protocol;
            // older builds can reach the explicit file/pipe whitelist instead.
            XCTAssertTrue(error.localizedDescription.contains("whitelist") || error.localizedDescription.contains("non standard extension"), error.localizedDescription)
        }
        let invalid = try fixture("broken.mp4", Data("bad media bytes".utf8))
        do { _ = try await ConversionEngine().convert(input: invalid, to: .mp4, outputDirectory: output); XCTFail("Expected malformed media error") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Conversion failed")) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: output.path), [])
    }

    private func fixture(_ name: String, _ data: Data) throws -> URL {
        let url = root.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func makeImage(format: ConversionFormat = .png, orientation: Int = 1, transparent: Bool = false) throws -> URL {
        let context = CGContext(data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        if !transparent {
            context.setFillColor(CGColor(red: 0.1, green: 0.6, blue: 0.9, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
        }
        let url = root.appendingPathComponent("sample.\(format.fileExtension)")
        let target = CGImageDestinationCreateWithURL(url as CFURL, format.imageType as CFString, 1, nil)!
        CGImageDestinationAddImage(target, context.makeImage()!, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(target))
        return url
    }

    private func makePDF() throws -> URL {
        let url = root.appendingPathComponent("sample.pdf")
        var bounds = CGRect(x: 0, y: 0, width: 200, height: 120)
        let context = CGContext(url as CFURL, mediaBox: &bounds, nil)!
        for text in ["Page one", "Page two"] {
            context.beginPDFPage(nil)
            let attributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 18, nil)]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
            context.textPosition = CGPoint(x: 10, y: 50)
            CTLineDraw(line, context)
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }

    private func decode(_ url: URL) throws -> CGImage {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    private func pixels(_ image: CGImage) throws -> [UInt8] {
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Array(UnsafeBufferPointer(start: try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4))
    }

    private func assertNoStaging() throws {
        guard FileManager.default.fileExists(atPath: output.path) else { return }
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: output.path).contains { $0.hasPrefix(".shiftdrop-") })
    }
}
