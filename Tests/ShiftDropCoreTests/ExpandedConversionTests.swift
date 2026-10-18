import XCTest
import Foundation
import ImageIO
import CoreGraphics
import PDFKit
@testable import ShiftDropCore

final class ExpandedConversionTests: XCTestCase {
    private var root: URL!
    private var output: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ShiftDropExpanded-\(UUID().uuidString)")
        output = root.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    func testZIPTARTGZCreateExtractAndRepackPreserveEveryByte() async throws {
        XCTAssertTrue(ArchiveConversions.isAvailable)
        let folder = root.appendingPathComponent("Source folder")
        let nested = folder.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let bytes = Data((0..<8192).map { UInt8($0 % 251) })
        let input = nested.appendingPathComponent("資料 ; literal.txt")
        try bytes.write(to: input)
        try Data().write(to: folder.appendingPathComponent("empty"))
        for format: ConversionFormat in [.zip, .tar, .tgz] {
            let archive = try await ConversionEngine().convert(input: folder, to: format, outputDirectory: output).outputURLs[0]
            let originalArchive = try Data(contentsOf: archive)
            let unpacked = try await ConversionEngine().convert(input: archive, to: .folder, outputDirectory: output).outputURLs[0]
            XCTAssertTrue((try unpacked.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true)
            XCTAssertEqual(try Data(contentsOf: unpacked.appendingPathComponent("Source folder/nested/資料 ; literal.txt")), bytes)
            XCTAssertEqual(try Data(contentsOf: unpacked.appendingPathComponent("Source folder/empty")).count, 0)
            let repacked = try await ConversionEngine().convert(input: archive, to: .zip, outputDirectory: output).outputURLs[0]
            let again = try await ConversionEngine().convert(input: repacked, to: .folder, outputDirectory: output).outputURLs[0]
            XCTAssertEqual(try Data(contentsOf: again.appendingPathComponent("Source folder/nested/資料 ; literal.txt")), bytes)
            XCTAssertEqual(try Data(contentsOf: archive), originalArchive)
        }
        XCTAssertEqual(try Data(contentsOf: input), bytes)
        try assertNoStaging()
    }

    func testGZIPIsOneFileAndDirectoryExtractionDoesNotOverwrite() async throws {
        let bytes = Data(String(repeating: "gzip payload\n", count: 200).utf8)
        let input = try fixture("content.txt", bytes)
        let gzip = try await ConversionEngine().convert(input: input, to: .gzip, outputDirectory: output).outputURLs[0]
        XCTAssertEqual(Array(try Data(contentsOf: gzip).prefix(2)), [0x1F, 0x8B])
        let existing = output.appendingPathComponent(gzip.deletingPathExtension().lastPathComponent)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        let sentinel = existing.appendingPathComponent("keep.txt")
        try Data("KEEP".utf8).write(to: sentinel)
        let unpacked = try await ConversionEngine().convert(input: gzip, to: .folder, outputDirectory: output).outputURLs[0]
        XCTAssertNotEqual(unpacked, existing)
        let contents = try FileManager.default.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil)
        XCTAssertEqual(contents.count, 1)
        XCTAssertEqual(try Data(contentsOf: contents[0]), bytes)
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("KEEP".utf8))
        XCTAssertFalse(FormatCatalog.formats(for: existing).contains(.gzip))
    }

    func testArchiveTraversalLinksSpecialFilesAndDuplicatesAreRejected() throws {
        let cases: [(String, [(String, UInt8, String, Data)])] = [
            ("traversal", [("../outside.txt", 48, "", Data("escaped".utf8))]),
            ("absolute", [("/tmp/outside.txt", 48, "", Data())]),
            ("windows", [("C:\\outside.txt", 48, "", Data())]),
            ("symlink", [("linked", 50, "/tmp", Data())]),
            ("hardlink", [("linked", 49, "other", Data())]),
            ("fifo", [("pipe", 54, "", Data())]),
            ("duplicate", [("same", 48, "", Data([1])), ("same", 48, "", Data([2]))])
        ]
        for (name, entries) in cases {
            let archive = try fixture(name + ".tar", tar(entries))
            let destination = root.appendingPathComponent(name)
            XCTAssertThrowsError(try ArchiveConversions.extract(archive, destination: destination), name)
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path), "Failed extraction must remove its private staging tree")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("outside.txt").path))
    }

    func testArchiveExpandedSizeAndEntryCountLimitsStopExtraction() throws {
        let archive = try fixture("limits.tar", tar([("a", 48, "", Data(repeating: 0, count: 100)), ("b", 48, "", Data(repeating: 0, count: 100))]))
        var limits = ArchiveConversions.Limits()
        limits.totalBytes = 150
        XCTAssertThrowsError(try ArchiveConversions.extract(archive, destination: root.appendingPathComponent("bytes"), limits: limits))
        limits = ArchiveConversions.Limits(); limits.entries = 1
        XCTAssertThrowsError(try ArchiveConversions.extract(archive, destination: root.appendingPathComponent("count"), limits: limits))
        limits = ArchiveConversions.Limits(); limits.fileBytes = 50
        XCTAssertThrowsError(try ArchiveConversions.extract(archive, destination: root.appendingPathComponent("file"), limits: limits))
        let source = try fixture("zeros", Data(repeating: 0, count: 100_000))
        let zip = root.appendingPathComponent("bomb.zip")
        try ArchiveConversions.create([source], destination: zip, format: .zip)
        limits = ArchiveConversions.Limits(); limits.totalBytes = 10_000
        XCTAssertThrowsError(try ArchiveConversions.extract(zip, destination: root.appendingPathComponent("compressed"), limits: limits))
        for name in ["bytes", "count", "file", "compressed"] { XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path)) }
    }

    func testNativeDOCXDOCODTRoundTripsAndSourcePreservation() async throws {
        guard DocumentConversions.textutilAvailable else { throw XCTSkip("The native offline document converter is unavailable.") }
        let text = "ShiftDrop document\nUnicode café 世界\nSecond paragraph & literal <tag>."
        let input = try fixture("words.txt", Data(text.utf8))
        for format: ConversionFormat in [.docx, .doc, .odt] {
            let document = try await ConversionEngine().convert(input: input, to: format, outputDirectory: output).outputURLs[0]
            let original = try Data(contentsOf: document)
            let result = try await ConversionEngine().convert(input: document, to: .txt, outputDirectory: output).outputURLs[0]
            let decoded = try String(contentsOf: result, encoding: .utf8)
            XCTAssertTrue(decoded.contains(text), format.title + ": " + decoded)
            XCTAssertEqual(try Data(contentsOf: document), original)
        }
        XCTAssertEqual(try Data(contentsOf: input), Data(text.utf8))
    }

    func testTextPDFPaginationAndPDFToDOCXIsExplicitlyTextReflow() async throws {
        let text = (1...120).map { "Line \($0): visible text." }.joined(separator: "\n")
        let input = try fixture("long.txt", Data(text.utf8))
        let pdf = try await ConversionEngine().convert(input: input, to: .pdf, outputDirectory: output).outputURLs[0]
        let document = try XCTUnwrap(PDFDocument(url: pdf))
        XCTAssertGreaterThan(document.pageCount, 1)
        XCTAssertTrue(document.string?.contains("Line 120") == true)
        XCTAssertTrue(FormatCatalog.note(for: pdf, to: .docx)?.contains("layout") == true)
        let word = try await ConversionEngine().convert(input: pdf, to: .docx, outputDirectory: output).outputURLs[0]
        let plain = try await ConversionEngine().convert(input: word, to: .txt, outputDirectory: output).outputURLs[0]
        XCTAssertTrue(try String(contentsOf: plain, encoding: .utf8).contains("Line 120"))
    }

    func testMarkdownCreatesStructuredOfflineHTMLAndReadablePDF() async throws {
        let source = "# Heading\n\nA **bold** word and [a link](https://example.invalid).\n\n- First\n- Second\n"
        let input = try fixture("notes.md", Data(source.utf8))
        let html = try await ConversionEngine().convert(input: input, to: .html, outputDirectory: output).outputURLs[0]
        let rendered = try String(contentsOf: html, encoding: .utf8)
        XCTAssertTrue(rendered.contains("<h1>Heading</h1>"), rendered)
        XCTAssertTrue(rendered.contains("<strong>bold</strong>"), rendered)
        let plain = try await ConversionEngine().convert(input: input, to: .txt, outputDirectory: output).outputURLs[0]
        let text = try String(contentsOf: plain, encoding: .utf8)
        XCTAssertTrue(text.contains("Heading\n"), text)
        XCTAssertFalse(text.contains("**"))
        XCTAssertTrue(text.contains("First"))
        let pdf = try await ConversionEngine().convert(input: input, to: .pdf, outputDirectory: output).outputURLs[0]
        XCTAssertTrue(PDFDocument(url: pdf)?.string?.contains("Heading") == true)
    }

    func testEPUBHasRequiredStoredMimetypePackageSpineAndTextRoundTrip() async throws {
        let text = "A chapter with café, 世界, & <literal>.\nSecond paragraph."
        let input = try fixture("Book.txt", Data(text.utf8))
        let epub = try await ConversionEngine().convert(input: input, to: .epub, outputDirectory: output).outputURLs[0]
        let data = try Data(contentsOf: epub)
        XCTAssertEqual(Array(data.prefix(4)), [0x50, 0x4B, 0x03, 0x04])
        XCTAssertEqual(data[8], 0, "EPUB first entry must use ZIP store, not deflate")
        XCTAssertEqual(String(data: data.subdata(in: 30..<38), encoding: .utf8), "mimetype")
        let unpacked = root.appendingPathComponent("epub-content")
        try ArchiveConversions.extract(epub, destination: unpacked)
        XCTAssertEqual(try String(contentsOf: unpacked.appendingPathComponent("mimetype"), encoding: .utf8), "application/epub+zip")
        XCTAssertTrue(try String(contentsOf: unpacked.appendingPathComponent("OEBPS/content.opf"), encoding: .utf8).contains("<spine>"))
        let plain = try await ConversionEngine().convert(input: epub, to: .txt, outputDirectory: output).outputURLs[0]
        XCTAssertTrue(try String(contentsOf: plain, encoding: .utf8).contains(text))
        XCTAssertEqual(try Data(contentsOf: input), Data(text.utf8))
    }

    func testEPUBRejectsManifestTraversalAndEntityDeclarations() async throws {
        for (name, xml) in [
            ("traversal", "<container><rootfiles><rootfile full-path=\"../../outside.opf\"/></rootfiles></container>"),
            ("entity", "<!DOCTYPE container [<!ENTITY bad SYSTEM 'file:///etc/passwd'>]><container>&bad;</container>")
        ] {
            let containerRoot = root.appendingPathComponent(name)
            let meta = containerRoot.appendingPathComponent("META-INF")
            try FileManager.default.createDirectory(at: meta, withIntermediateDirectories: true)
            try Data(xml.utf8).write(to: meta.appendingPathComponent("container.xml"))
            let epub = root.appendingPathComponent(name + ".epub")
            try ArchiveConversions.create([meta], destination: epub, format: .zip)
            do { _ = try await ConversionEngine().convert(input: epub, to: .txt, outputDirectory: output); XCTFail("Expected unsafe EPUB rejection") }
            catch { XCTAssertTrue(error.localizedDescription.contains("EPUB"), error.localizedDescription) }
        }
        try assertNoStaging()
    }

    func testOptionalLibreOfficeSpreadsheetConversionsAreRealAndOffline() async throws {
        guard DocumentConversions.officeURL != nil else { throw XCTSkip("Optional LibreOffice is not installed.") }
        let csv = try fixture("values.csv", Data("Name,Value\nAlpha,10\nBeta,20\n".utf8))
        let bytes = try Data(contentsOf: csv)
        let xlsx = try await ConversionEngine().convert(input: csv, to: .xlsx, outputDirectory: output).outputURLs[0]
        let unpacked = root.appendingPathComponent("xlsx-package")
        try ArchiveConversions.extract(xlsx, destination: unpacked)
        XCTAssertTrue(FileManager.default.fileExists(atPath: unpacked.appendingPathComponent("xl/workbook.xml").path))
        for format: ConversionFormat in [.pdf, .ods, .xls, .csv, .tsv] {
            let result = try await ConversionEngine().convert(input: xlsx, to: format, outputDirectory: output).outputURLs[0]
            if format == .pdf { XCTAssertTrue(PDFDocument(url: result)?.string?.contains("Alpha") == true) }
            if format == .tsv {
                let tsv = try String(contentsOf: result, encoding: .utf8)
                let cells = (tsv.components(separatedBy: .newlines).first ?? "").split(separator: "\t").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"\u{FEFF}")) }
                XCTAssertEqual(cells, ["Name", "Value"], tsv)
            }
            if format == .xls { XCTAssertEqual(Array(try Data(contentsOf: result).prefix(4)), [0xD0, 0xCF, 0x11, 0xE0]) }
        }
        XCTAssertEqual(try Data(contentsOf: csv), bytes)
        XCTAssertTrue(FormatCatalog.note(for: xlsx, to: .csv)?.contains("first sheet") == true)
        try assertNoStaging()
    }

    func testOptionalLibreOfficePresentationAndWordPDFExports() async throws {
        guard DocumentConversions.officeURL != nil else { throw XCTSkip("Optional LibreOffice is not installed.") }
        let malicious = try fixture("unsafe.pptx", tar([("../outside.txt", 48, "", Data("escaped".utf8))]))
        do {
            _ = try await ConversionEngine().convert(input: malicious, to: .png, outputDirectory: output)
            XCTFail("Presentation image imports must validate their compressed container before invoking LibreOffice.")
        } catch ConversionError.unsafeArchive { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("outside.txt").path))
        let document = try fixture("letter.txt", Data("Word PDF export\nA real native document.".utf8))
        let word = try await ConversionEngine().convert(input: document, to: .docx, outputDirectory: output).outputURLs[0]
        let pdf = try await ConversionEngine().convert(input: word, to: .pdf, outputDirectory: output).outputURLs[0]
        XCTAssertTrue(PDFDocument(url: pdf)?.string?.contains("Word PDF export") == true)
        let odp = try await presentationFixture()
        let original = try Data(contentsOf: odp)
        for format: ConversionFormat in [.pptx, .ppt, .pdf, .png, .jpeg] {
            let result = try await ConversionEngine().convert(input: odp, to: format, outputDirectory: output).outputURLs[0]
            if format == .pdf { XCTAssertTrue(PDFDocument(url: result)?.string?.contains("Hello ShiftDrop") == true) }
            if format == .pptx {
                let extracted = root.appendingPathComponent("pptx-package")
                try ArchiveConversions.extract(result, destination: extracted)
                XCTAssertTrue(FileManager.default.fileExists(atPath: extracted.appendingPathComponent("ppt/presentation.xml").path))
            }
            if format == .ppt { XCTAssertEqual(Array(try Data(contentsOf: result).prefix(4)), [0xD0, 0xCF, 0x11, 0xE0]) }
            if format == .png || format == .jpeg { XCTAssertNotNil(CGImageSourceCreateWithURL(result as CFURL, nil)) }
        }
        XCTAssertEqual(try Data(contentsOf: odp), original)
        try assertNoStaging()
    }

    func testNativePDFToPPTXPageImagesAndXLSXTextRowsAreValidPackages() async throws {
        let input = try fixture("paper.txt", Data((1...90).map { "Row \($0): original PDF text & symbols." }.joined(separator: "\n").utf8))
        let pdf = try await ConversionEngine().convert(input: input, to: .pdf, outputDirectory: output).outputURLs[0]
        let pageCount = try XCTUnwrap(PDFDocument(url: pdf)).pageCount
        XCTAssertGreaterThan(pageCount, 1)
        let pptx = try await ConversionEngine().convert(input: pdf, to: .pptx, outputDirectory: output).outputURLs[0]
        let slides = root.appendingPathComponent("page-slides")
        try ArchiveConversions.extract(pptx, destination: slides)
        let media = try FileManager.default.contentsOfDirectory(at: slides.appendingPathComponent("ppt/media"), includingPropertiesForKeys: nil)
        XCTAssertEqual(media.count, pageCount)
        for image in media { XCTAssertNotNil(CGImageSourceCreateWithURL(image as CFURL, nil)) }
        XCTAssertTrue(FormatCatalog.note(for: pdf, to: .pptx)?.contains("not editable") == true)
        let xlsx = try await ConversionEngine().convert(input: pdf, to: .xlsx, outputDirectory: output).outputURLs[0]
        let sheets = root.appendingPathComponent("text-sheets")
        try ArchiveConversions.extract(xlsx, destination: sheets)
        let xml = try String(contentsOf: sheets.appendingPathComponent("xl/worksheets/sheet1.xml"), encoding: .utf8)
        XCTAssertTrue(xml.contains("Row 90: original PDF text &amp; symbols."), xml)
        XCTAssertTrue(xml.contains("t=\"inlineStr\""))
        if DocumentConversions.officeURL != nil {
            let reopened = try await ConversionEngine().convert(input: pptx, to: .pdf, outputDirectory: output).outputURLs[0]
            XCTAssertEqual(PDFDocument(url: reopened)?.pageCount, pageCount)
            let csv = try await ConversionEngine().convert(input: xlsx, to: .csv, outputDirectory: output).outputURLs[0]
            XCTAssertTrue(try String(contentsOf: csv, encoding: .utf8).contains("Row 90"))
        }
    }

    func testSVGRasterizationIsBoundedAndRejectsActiveOrExternalContent() async throws {
        let svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"80\" height=\"40\"><rect width=\"80\" height=\"40\" fill=\"#ff0000\"/></svg>"
        let input = try fixture("art.svg", Data(svg.utf8))
        let png = try await ConversionEngine().convert(input: input, to: .png, outputDirectory: output, options: .init(maxPixelSize: 20)).outputURLs[0]
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(png as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 20); XCTAssertEqual(image.height, 10)
        let publishedBefore = Set(try FileManager.default.contentsOfDirectory(atPath: output.path))
        for bad in [
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><script>alert(1)</script></svg>",
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><image href=\"file:///etc/passwd\"/></svg>",
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><style>rect{fill:url(https://example.invalid/fill)}</style></svg>",
            #"<svg xmlns="http://www.w3.org/2000/svg"><rect fill="u&#114;l(https://example.invalid/a.svg#p)"/></svg>"#,
            #"<svg xmlns="http://www.w3.org/2000/svg"><style>rect{fill:u&#114;l(https://example.invalid/a.svg#p)}</style></svg>"#,
            #"<svg xmlns="http://www.w3.org/2000/svg"><style>rect{fill:u<![CDATA[r]]>l(https://example.invalid/a.svg#p)}</style></svg>"#,
            #"<svg xmlns="http://www.w3.org/2000/svg"><rect style="fill:&#92;75rl(https://example.invalid/a.svg#p)"/></svg>"#,
            #"<svg xmlns="http://www.w3.org/2000/svg"><style>&#64;im&#112;ort 'https://example.invalid/style.css';</style></svg>"#,
            ##"<svg xmlns="http://www.w3.org/2000/svg" xml:base="https://example.invalid/a.svg"><use href="#external"/></svg>"##,
            ##"<svg xmlns="http://www.w3.org/2000/svg"><image href="#local"><set attributeName="href" to="https://example.invalid/a.svg"/></image></svg>"##,
            #"<?xml-stylesheet type="text/css" href="https://example.invalid/style.css"?><svg xmlns="http://www.w3.org/2000/svg"/>"#,
            "<!DOCTYPE svg [<!ENTITY x SYSTEM 'file:///etc/passwd'>]><svg xmlns=\"http://www.w3.org/2000/svg\">&x;</svg>"
        ] {
            let invalid = try fixture("unsafe.svg", Data(bad.utf8))
            do { _ = try await ConversionEngine().convert(input: invalid, to: .png, outputDirectory: output); XCTFail("Expected unsafe SVG rejection") }
            catch { XCTAssertTrue(error.localizedDescription.contains("SVG"), error.localizedDescription) }
            XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: output.path)), publishedBefore, "Unsafe SVG must publish no file or staging directory")
        }
        let local = try fixture("local-paint.svg", Data(#"<svg xmlns="http://www.w3.org/2000/svg" width="20" height="10"><defs><linearGradient id="paint"><stop stop-color="red"/></linearGradient></defs><style>rect{fill:u&#114;l(#paint)}</style><rect width="20" height="10"/></svg>"#.utf8))
        let localOutput = try await ConversionEngine().convert(input: local, to: .png, outputDirectory: output).outputURLs[0]
        XCTAssertNotNil(CGImageSourceCreateWithURL(localOutput as CFURL, nil))
        XCTAssertEqual(try Data(contentsOf: input), Data(svg.utf8))
    }

    func testRTFDAndFinderUnicodeTextClippingImportRealText() async throws {
        let text = "Finder clipping café 世界"
        let input = try fixture("source.txt", Data(text.utf8))
        let rtfd = try await ConversionEngine().convert(input: input, to: .rtfd, outputDirectory: output).outputURLs[0]
        XCTAssertEqual(FormatCatalog.kind(for: rtfd), "Document")
        XCTAssertTrue((try rtfd.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true)
        let plain = try await ConversionEngine().convert(input: rtfd, to: .txt, outputDirectory: output).outputURLs[0]
        XCTAssertTrue(try String(contentsOf: plain, encoding: .utf8).contains(text))
        let clip = try fixture("sample.textClipping", Data())
        let fork = resourceFork(text.data(using: .utf16BigEndian)!, type: "utxt")
        try fork.write(to: URL(fileURLWithPath: clip.path + "/..namedfork/rsrc"))
        let exported = try await ConversionEngine().convert(input: clip, to: .txt, outputDirectory: output).outputURLs[0]
        XCTAssertEqual(try String(contentsOf: exported, encoding: .utf8), text)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: clip.path + "/..namedfork/rsrc")), fork)
        XCTAssertThrowsError(try DocumentConversions.resourceText(Data([0, 0, 0])))
    }

    func testRejectedRecursiveArchiveDestinationCreatesNoNestedFolder() async throws {
        let folder = root.appendingPathComponent("archive-source")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("unchanged".utf8).write(to: folder.appendingPathComponent("file.txt"))
        let nested = folder.appendingPathComponent("must-not-exist/deeper")
        do { _ = try await ConversionEngine().convert(input: folder, to: .zip, outputDirectory: nested); XCTFail("Expected recursive destination rejection") }
        catch { XCTAssertTrue(error.localizedDescription.contains("outside")) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("must-not-exist").path))
    }

    func testOptionalExpandedMediaAndModernImageOutputsDecode() async throws {
        guard let ffmpeg = FormatCatalog.ffmpegURL else { throw XCTSkip("Optional FFmpeg is not installed.") }
        let image = root.appendingPathComponent("source.png")
        try await ProcessRunner.run(executable: ffmpeg, arguments: ["-v", "error", "-nostdin", "-f", "lavfi", "-i", "testsrc=size=48x32:duration=0.1", "-frames:v", "1", image.path])
        let original = try Data(contentsOf: image)
        for format: ConversionFormat in [.webp, .avif, .gif] {
            let converted = try await ConversionEngine().convert(input: image, to: format, outputDirectory: output).outputURLs[0]
            try await assertMediaDecodes(converted, ffmpeg: ffmpeg)
            if format != .gif {
                let back = try await ConversionEngine().convert(input: converted, to: .png, outputDirectory: output).outputURLs[0]
                XCTAssertNotNil(CGImageSourceCreateWithURL(back as CFURL, nil))
            }
        }
        let audio = root.appendingPathComponent("tone.wav")
        try await ProcessRunner.run(executable: ffmpeg, arguments: ["-v", "error", "-nostdin", "-f", "lavfi", "-i", "sine=frequency=440:duration=0.2", audio.path])
        for format: ConversionFormat in [.ogg, .opus, .aiff, .wma] {
            let converted = try await ConversionEngine().convert(input: audio, to: format, outputDirectory: output).outputURLs[0]
            try await assertMediaDecodes(converted, ffmpeg: ffmpeg)
        }
        let video = root.appendingPathComponent("source.mp4")
        try await ProcessRunner.run(executable: ffmpeg, arguments: ["-v", "error", "-nostdin", "-f", "lavfi", "-i", "testsrc=size=48x32:rate=12:duration=0.25", "-c:v", "libx264", "-pix_fmt", "yuv420p", video.path])
        for format: ConversionFormat in [.mkv, .webm, .avi, .wmv] {
            let converted = try await ConversionEngine().convert(input: video, to: format, outputDirectory: output).outputURLs[0]
            try await assertMediaDecodes(converted, ffmpeg: ffmpeg)
        }
        XCTAssertEqual(try Data(contentsOf: image), original)
        try assertNoStaging()
    }

    private func assertMediaDecodes(_ input: URL, ffmpeg: URL) async throws {
        try await ProcessRunner.run(executable: ffmpeg, arguments: ["-hide_banner", "-loglevel", "error", "-nostdin", "-i", input.path, "-f", "null", "-"])
    }
    private func fixture(_ name: String, _ data: Data) throws -> URL {
        let url = root.appendingPathComponent(name); try data.write(to: url); return url
    }
    private func assertNoStaging() throws {
        guard FileManager.default.fileExists(atPath: output.path) else { return }
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: output.path).contains { $0.hasPrefix(".shiftdrop-") })
    }
    private func tar(_ entries: [(String, UInt8, String, Data)]) -> Data {
        var archive = Data()
        for (name, type, link, data) in entries {
            var header = [UInt8](repeating: 0, count: 512)
            func field(_ value: String, _ offset: Int, _ count: Int) { for (i, byte) in value.utf8.prefix(count).enumerated() { header[offset + i] = byte } }
            field(name, 0, 100); field("0000644\0", 100, 8); field("0000000\0", 108, 8); field("0000000\0", 116, 8)
            field(String(format: "%011llo", data.count) + "\0", 124, 12); field("00000000000\0", 136, 12)
            for index in 148..<156 { header[index] = 32 }
            header[156] = type; field(link, 157, 100); field("ustar\0", 257, 6); field("00", 263, 2)
            field(String(format: "%06o", header.reduce(0) { $0 + Int($1) }) + "\0 ", 148, 8)
            archive.append(contentsOf: header); archive.append(data)
            archive.append(Data(repeating: 0, count: (512 - data.count % 512) % 512))
        }
        archive.append(Data(repeating: 0, count: 1024)); return archive
    }
    private func presentationFixture() async throws -> URL {
        // Start with a native, valid presentation package, then give the test slide
        // independent editable text and have LibreOffice serialize a genuine ODP.
        let text = try fixture("slide-text.txt", Data("Hello ShiftDrop".utf8))
        let pdf = try await ConversionEngine().convert(input: text, to: .pdf, outputDirectory: output).outputURLs[0]
        let pptx = try await ConversionEngine().convert(input: pdf, to: .pptx, outputDirectory: output).outputURLs[0]
        let package = root.appendingPathComponent("odp-source")
        try ArchiveConversions.extract(pptx, destination: package)
        let slide = package.appendingPathComponent("ppt/slides/slide1.xml")
        var xml = try String(contentsOf: slide, encoding: .utf8)
        let textbox = "<p:sp><p:nvSpPr><p:cNvPr id=\"2\" name=\"Title\"/><p:cNvSpPr txBox=\"1\"/><p:nvPr/></p:nvSpPr><p:spPr><a:xfrm><a:off x=\"500000\" y=\"500000\"/><a:ext cx=\"7000000\" cy=\"1500000\"/></a:xfrm><a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></p:spPr><p:txBody><a:bodyPr/><a:lstStyle/><a:p><a:r><a:rPr lang=\"en-US\" sz=\"2400\"/><a:t>Hello ShiftDrop</a:t></a:r></a:p></p:txBody></p:sp>"
        xml = xml.replacingOccurrences(of: "(?s)<p:pic>.*?</p:pic>", with: textbox, options: .regularExpression)
        try Data(xml.utf8).write(to: slide)
        let editable = root.appendingPathComponent("editable-slides.pptx")
        try ArchiveConversions.create(FileManager.default.contentsOfDirectory(at: package, includingPropertiesForKeys: nil), destination: editable, format: .zip)
        return try await ConversionEngine().convert(input: editable, to: .odp, outputDirectory: output).outputURLs[0]
    }
    private func resourceFork(_ data: Data, type: String) -> Data {
        let dataOffset = 256, mapOffset = dataOffset + 4 + data.count, mapLength = 50
        var bytes = [UInt8](repeating: 0, count: mapOffset + mapLength)
        func number(_ value: Int, _ offset: Int, _ count: Int) {
            for index in 0..<count { bytes[offset + index] = UInt8((value >> ((count - index - 1) * 8)) & 255) }
        }
        number(dataOffset, 0, 4); number(mapOffset, 4, 4); number(4 + data.count, 8, 4); number(mapLength, 12, 4)
        number(data.count, dataOffset, 4)
        bytes.replaceSubrange((dataOffset + 4)..<(dataOffset + 4 + data.count), with: data)
        for index in 0..<16 { bytes[mapOffset + index] = bytes[index] }
        number(28, mapOffset + 24, 2); number(50, mapOffset + 26, 2)
        let types = mapOffset + 28
        number(0, types, 2)
        bytes.replaceSubrange((types + 2)..<(types + 6), with: type.utf8)
        number(0, types + 6, 2); number(10, types + 8, 2)
        number(256, types + 10, 2); number(0xFFFF, types + 12, 2)
        return Data(bytes)
    }
}
