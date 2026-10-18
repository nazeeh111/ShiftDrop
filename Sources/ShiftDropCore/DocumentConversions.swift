import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import AppKit
import CoreText
import CoreGraphics
import ImageIO

enum DocumentConversions {
    static let nativeOfficeFormats: [ConversionFormat] = [.txt, .rtf, .rtfd, .html, .doc, .docx, .odt]
    static var textutilAvailable: Bool { FileManager.default.isExecutableFile(atPath: "/usr/bin/textutil") && offlineSandboxAvailable }
    static var offlineSandboxAvailable: Bool { FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec") }
    static var officeURL: URL? {
        guard offlineSandboxAvailable else { return nil }
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { URL(fileURLWithPath: String($0)).appendingPathComponent("soffice").path }
        let candidates = paths + [
            "/Applications/LibreOffice.app/Contents/MacOS/soffice",
            NSHomeDirectory() + "/Applications/LibreOffice.app/Contents/MacOS/soffice",
            NSHomeDirectory() + "/.cache/codex-runtimes/codex-primary-runtime/dependencies/bin/override/soffice"
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    static func convert(_ input: URL, destination: URL, format: ConversionFormat, workspace: URL) async throws {
        let kind = FormatCatalog.kind(for: input)
        let inputExtension = input.pathExtension.lowercased()
        let size = try input.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 128 * 1024 * 1024 else { throw ConversionError.invalidInput("Document imports are limited to 128 MB.") }
        if ["docx", "odt", "xlsx", "ods", "pptx", "odp"].contains(inputExtension) {
            // Validate compressed office containers before another parser sees them.
            let checked = workspace.appendingPathComponent("checked-office", isDirectory: true)
            try ArchiveConversions.extract(input, destination: checked)
            try FileManager.default.removeItem(at: checked)
        }
        if kind == "Spreadsheet" || kind == "Presentation" || (["doc", "docx", "odt", "wordml"].contains(inputExtension) && officeURL != nil && [.pdf, .doc, .docx, .odt].contains(format)) {
            try await officeConvert(input, destination: destination, format: format, workspace: workspace)
            return
        }
        if kind == "PDF", format == .pptx {
            let pages = try NativeImages.convertPDF(input, directory: workspace, format: .png, options: ConversionOptions(maxPixelSize: 2048))
            try writeImagePresentation(pages, destination: destination, workspace: workspace)
            return
        }
        if kind == "PDF", format == .xlsx {
            try writeTextWorkbook(try await plainText(input, workspace: workspace), destination: destination, workspace: workspace)
            return
        }
        if kind == "Document", inputExtension != "textclipping", nativeOfficeFormats.contains(format) {
            try await textutil(input, destination: destination, format: format)
            return
        }
        if kind == "Text", ["txt", "rtf", "html", "htm"].contains(inputExtension), [.txt, .rtf, .html].contains(format) {
            try TextConversions.convert(input, destination: destination, format: format)
            return
        }
        let plain = try await plainText(input, workspace: workspace)
        try Task.checkCancellation()
        if format == .epub {
            try writeEPUB(plain, title: input.deletingPathExtension().lastPathComponent, destination: destination, workspace: workspace)
        } else if format == .md {
            // Plain text is escaped so its visible content remains literal Markdown.
            let special = CharacterSet(charactersIn: "\\`*_{}[]<>()#+-.!|")
            let markdown = plain.unicodeScalars.map { special.contains($0) ? "\\" + String($0) : String($0) }.joined()
            try Data(markdown.utf8).write(to: destination)
        } else if format == .pdf {
            let attributed: NSAttributedString
            if inputExtension == "rtf" { attributed = try NSAttributedString(data: Data(contentsOf: input), options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil) }
            else if inputExtension == "rtfd" { attributed = try NSAttributedString(url: input, options: [.documentType: NSAttributedString.DocumentType.rtfd], documentAttributes: nil) }
            else { attributed = NSAttributedString(string: plain, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.black]) }
            try writePDF(attributed, destination: destination)
        } else if format == .html, ["md", "markdown"].contains(inputExtension) {
            try Data(markdownHTML(try TextConversions.decode(Data(contentsOf: input))).utf8).write(to: destination)
        } else {
            let textInput = workspace.appendingPathComponent("document-text.txt")
            try Data(plain.utf8).write(to: textInput)
            if [.txt, .rtf, .html].contains(format) { try TextConversions.convert(textInput, destination: destination, format: format) }
            else { try await textutil(textInput, destination: destination, format: format) }
        }
    }

    private static func plainText(_ input: URL, workspace: URL) async throws -> String {
        let kind = FormatCatalog.kind(for: input)
        if input.pathExtension.lowercased() == "textclipping" { return try clippingText(input) }
        if input.pathExtension.lowercased() == "rtfd" { return try NSAttributedString(url: input, options: [.documentType: NSAttributedString.DocumentType.rtfd], documentAttributes: nil).string.replacingOccurrences(of: "\u{FFFC}", with: "") }
        if kind == "Ebook" { return try readEPUB(input, workspace: workspace) }
        if kind == "Document" {
            let text = workspace.appendingPathComponent("office-text.txt")
            try await textutil(input, destination: text, format: .txt)
            return try TextConversions.decode(Data(contentsOf: text))
        }
        if kind == "PDF" {
            let urls = try NativeImages.convertPDF(input, directory: workspace, format: .txt, options: ConversionOptions())
            return try TextConversions.decode(Data(contentsOf: urls[0]))
        }
        let data = try Data(contentsOf: input)
        guard data.count <= 32 * 1024 * 1024 else { throw ConversionError.invalidInput("Text imports are limited to 32 MB.") }
        switch input.pathExtension.lowercased() {
        case "rtf": return try NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil).string
        case "html", "htm": return HTMLText.plain(try TextConversions.decode(data))
        case "md", "markdown": return HTMLText.plain(try markdownHTML(TextConversions.decode(data)))
        default: return try TextConversions.decode(data)
        }
    }

    private static func textutil(_ input: URL, destination: URL, format: ConversionFormat) async throws {
        guard textutilAvailable, nativeOfficeFormats.contains(format) else { throw ConversionError.unsupported("This route needs the macOS textutil document converter and offline sandbox.") }
        try await runOffline(URL(fileURLWithPath: "/usr/bin/textutil"), arguments: ["-convert", format.rawValue, "-encoding", "UTF-8", "-noload", "-nostore", "-strip", "-output", destination.path, "--", input.path])
        guard FileManager.default.fileExists(atPath: destination.path) else { throw ConversionError.conversionFailed("The document converter did not produce a file.") }
    }

    private static func officeConvert(_ input: URL, destination: URL, format: ConversionFormat, workspace: URL) async throws {
        guard let executable = officeURL else { throw ConversionError.unsupported("Install the free LibreOffice desktop application for this Office conversion.") }
        let fm = FileManager.default
        let sourceDirectory = workspace.appendingPathComponent("office-input", isDirectory: true)
        let exportDirectory = workspace.appendingPathComponent("office-output", isDirectory: true)
        let profile = workspace.appendingPathComponent("office-profile", isDirectory: true)
        let profileUser = profile.appendingPathComponent("user", isDirectory: true)
        for directory in [sourceDirectory, exportDirectory, profileUser] { try fm.createDirectory(at: directory, withIntermediateDirectories: true) }
        let source = sourceDirectory.appendingPathComponent("source." + input.pathExtension.lowercased())
        try fm.copyItem(at: input, to: source)
        let registry = """
        <?xml version="1.0" encoding="UTF-8"?>
        <oor:items xmlns:oor="http://openoffice.org/2001/registry"><item oor:path="/org.openoffice.Office.Common/Security/Scripting"><prop oor:name="MacroSecurityLevel" oor:op="fuse"><value>3</value></prop></item></oor:items>
        """
        try Data(registry.utf8).write(to: profileUser.appendingPathComponent("registrymodifications.xcu"))
        let filter: String
        switch format {
        case .csv: filter = "csv:Text - txt - csv (StarCalc):44,34,76,1"
        case .tsv: filter = "tsv:Text - txt - csv (StarCalc):9,34,76,1"
        default: filter = format.fileExtension
        }
        let arguments = ["-env:UserInstallation=" + profile.absoluteString, "--headless", "--nologo", "--nodefault", "--nolockcheck", "--norestore", "--convert-to", filter, "--outdir", exportDirectory.path, source.path]
        try await runOffline(executable, arguments: arguments)
        let generated = exportDirectory.appendingPathComponent("source." + format.fileExtension)
        guard fm.fileExists(atPath: generated.path), (try generated.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0 > 0 else {
            throw ConversionError.conversionFailed("LibreOffice could not export this document. It may be damaged, password-protected, or unsupported by this installed build.")
        }
        try fm.moveItem(at: generated, to: destination)
    }

    static func renderOfficePages(_ input: URL, directory: URL, format: ConversionFormat, options: ConversionOptions) async throws -> [URL] {
        let size = try input.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 128 * 1024 * 1024 else { throw ConversionError.invalidInput("Document imports are limited to 128 MB.") }
        if ["pptx", "odp"].contains(input.pathExtension.lowercased()) {
            let checked = directory.appendingPathComponent("checked-presentation", isDirectory: true)
            try ArchiveConversions.extract(input, destination: checked)
            try FileManager.default.removeItem(at: checked)
        }
        let pdf = directory.appendingPathComponent("presentation.pdf")
        try await officeConvert(input, destination: pdf, format: .pdf, workspace: directory)
        return try NativeImages.convertPDF(pdf, directory: directory, format: format, options: options)
    }

    static func rasterizeSVG(_ input: URL, destination: URL, options: ConversionOptions) throws {
        let size = try input.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 8 * 1024 * 1024 else { throw ConversionError.invalidInput("SVG imports are limited to 8 MB.") }
        let data = try Data(contentsOf: input)
        let validator = SVGValidator()
        let source = try TextConversions.decode(data)
        guard !source.contains("\\"), !source.uppercased().contains("<!DOCTYPE"), !source.uppercased().contains("<!ENTITY"), !source.lowercased().contains("@import") else { throw ConversionError.invalidInput("SVG entities, escaped CSS, and imported resources are not supported.") }
        let urls = try NSRegularExpression(pattern: "(?i)url\\s*\\(([^)]*)\\)")
        for match in urls.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
            let value = (source as NSString).substring(with: match.range(at: 1)).trimmingCharacters(in: CharacterSet(charactersIn: " \t\n\r\"'"))
            guard value.hasPrefix("#") else { throw ConversionError.invalidInput("SVG external resources are not supported.") }
        }
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = validator
        guard parser.parse(), validator.valid, validator.sawSVG else { throw ConversionError.invalidInput("The SVG is damaged or contains scripts, external resources, or foreign objects.") }
        guard let image = NSImage(data: data), image.size.width.isFinite, image.size.height.isFinite, image.size.width > 0, image.size.height > 0 else { throw ConversionError.invalidInput("This SVG cannot be rendered by macOS.") }
        let maximum = Double(options.maxPixelSize ?? 4096)
        let scale = min(1, maximum / max(image.size.width, image.size.height))
        let width = max(1, Int(ceil(image.size.width * scale)))
        let height = max(1, Int(ceil(image.size.height * scale)))
        guard width <= 16384, height <= 16384, width * height <= 80_000_000,
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { throw ConversionError.invalidInput("The SVG dimensions exceed the safe rendering limit.") }
        try Task.checkCancellation()
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        guard let cgImage = bitmap.cgImage else { throw ConversionError.conversionFailed("Cannot render the SVG artwork.") }
        try NativeImages.write(cgImage, destination: destination, format: .png, quality: options.quality)
    }

    static func clippingText(_ input: URL) throws -> String {
        let data = try Data(contentsOf: input)
        if !data.isEmpty { return try TextConversions.decode(data) }
        let fork: Data
        do { fork = try Data(contentsOf: URL(fileURLWithPath: input.path + "/..namedfork/rsrc")) }
        catch { throw ConversionError.invalidInput("This Finder clipping has no readable text resource.") }
        guard fork.count <= 32 * 1024 * 1024 else { throw ConversionError.invalidInput("The clipping exceeds the text-size limit.") }
        return try resourceText(fork)
    }

    static func resourceText(_ fork: Data) throws -> String {
        func integer(_ position: Int, _ width: Int) throws -> Int {
            guard position >= 0, width <= 4, position <= fork.count - width else { throw ConversionError.invalidInput("The clipping resource map is damaged.") }
            return fork[position..<(position + width)].reduce(0) { ($0 << 8) | Int($1) }
        }
        let dataOffset = try integer(0, 4), mapOffset = try integer(4, 4)
        let dataLength = try integer(8, 4), mapLength = try integer(12, 4)
        guard dataOffset <= fork.count - dataLength, mapOffset <= fork.count - mapLength, mapLength >= 28 else { throw ConversionError.invalidInput("The clipping resource header is damaged.") }
        let types = mapOffset + (try integer(mapOffset + 24, 2))
        let count = try integer(types, 2) + 1
        guard count <= 256 else { throw ConversionError.invalidInput("The clipping has too many resource types.") }
        var found: [String: Data] = [:]
        for index in 0..<count {
            let typeOffset = types + 2 + index * 8
            guard typeOffset <= fork.count - 8 else { throw ConversionError.invalidInput("The clipping resource map is damaged.") }
            let type = String(decoding: fork[typeOffset..<(typeOffset + 4)], as: UTF8.self)
            let resources = try integer(typeOffset + 4, 2) + 1
            let reference = types + (try integer(typeOffset + 6, 2))
            guard resources <= 1024 else { throw ConversionError.invalidInput("The clipping has too many resources.") }
            for resource in 0..<resources {
                let relative = try integer(reference + resource * 12 + 5, 3)
                let offset = dataOffset + relative
                let length = try integer(offset, 4)
                guard length <= 32 * 1024 * 1024, offset + 4 <= fork.count - length else { throw ConversionError.invalidInput("A clipping text resource is damaged.") }
                if ["utxt", "utf8", "TEXT", "RTF "].contains(type) { found[type] = fork.subdata(in: (offset + 4)..<(offset + 4 + length)) }
            }
        }
        if let unicode = found["utxt"], let text = String(data: unicode, encoding: unicode.starts(with: [0xFE, 0xFF]) || unicode.starts(with: [0xFF, 0xFE]) ? .utf16 : .utf16BigEndian) { return text }
        if let utf8 = found["utf8"], let text = String(data: utf8, encoding: .utf8) { return text }
        if let rtf = found["RTF "] { return try NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil).string }
        if let legacy = found["TEXT"], let text = String(data: legacy, encoding: .macOSRoman) { return text }
        throw ConversionError.invalidInput("This Finder clipping has no supported text resource.")
    }

    private static func runOffline(_ executable: URL, arguments: [String]) async throws {
        guard offlineSandboxAvailable else { throw ConversionError.unsupported("The macOS offline process sandbox is unavailable.") }
        try await ProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/sandbox-exec"), arguments: ["-p", "(version 1) (allow default) (deny network*)", executable.path] + arguments)
    }

    private static func writePDF(_ source: NSAttributedString, destination: URL) throws {
        guard source.length > 0 else { throw ConversionError.invalidInput("The document has no text to place in PDF pages.") }
        var bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(destination as CFURL, mediaBox: &bounds, nil) else { throw ConversionError.conversionFailed("Cannot create PDF pages.") }
        defer { context.closePDF() }
        let framesetter = CTFramesetterCreateWithAttributedString(source)
        let path = CGPath(rect: bounds.insetBy(dx: 42, dy: 42), transform: nil)
        var position = 0
        var pages = 0
        while position < source.length {
            try Task.checkCancellation()
            pages += 1
            guard pages <= 1000 else { throw ConversionError.invalidInput("Document PDF exports are limited to 1,000 pages.") }
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: position, length: 0), path, nil)
            let visible = CTFrameGetVisibleStringRange(frame)
            guard visible.length > 0 else { throw ConversionError.conversionFailed("A text segment cannot fit on a PDF page.") }
            context.beginPDFPage(nil)
            CTFrameDraw(frame, context)
            context.endPDFPage()
            position += visible.length
        }
    }

    private static func markdownHTML(_ source: String) throws -> String {
        let parsed = try AttributedString(markdown: source, options: .init(interpretedSyntax: .full))
        var output = "<!doctype html><html><head><meta charset=\"UTF-8\"></head><body>"
        var blockIdentity: Int?
        var closing = ""
        for run in parsed.runs {
            let block = run.presentationIntent?.components.first
            if block?.identity != blockIdentity || blockIdentity == nil {
                output += closing
                blockIdentity = block?.identity
                var opening = "<p>"
                closing = "</p>\n"
                if let block {
                    switch block.kind {
                    case .header(let level): opening = "<h\(level)>"; closing = "</h\(level)>\n"
                    case .codeBlock: opening = "<pre>"; closing = "</pre>\n"
                    default: break
                    }
                }
                output += opening
                if let components = run.presentationIntent?.components, components.contains(where: { if case .listItem = $0.kind { return true }; return false }) { output += "• " }
            }
            var content = xmlEscape(String(parsed[run.range].characters))
            let intents = run.inlinePresentationIntent ?? []
            if intents.contains(.code) { content = "<code>\(content)</code>" }
            if intents.contains(.emphasized) { content = "<em>\(content)</em>" }
            if intents.contains(.stronglyEmphasized) { content = "<strong>\(content)</strong>" }
            if intents.contains(.strikethrough) { content = "<s>\(content)</s>" }
            if let link = run.link, ["http", "https", "mailto"].contains(link.scheme?.lowercased() ?? "") { content = "<a href=\"\(xmlEscape(link.absoluteString))\">\(content)</a>" }
            output += content
        }
        return output + closing + "</body></html>"
    }

    private static func writeEPUB(_ text: String, title: String, destination: URL, workspace: URL) throws {
        let root = workspace.appendingPathComponent("epub", isDirectory: true)
        let meta = root.appendingPathComponent("META-INF", isDirectory: true)
        let content = root.appendingPathComponent("OEBPS", isDirectory: true)
        try FileManager.default.createDirectory(at: meta, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: content, withIntermediateDirectories: true)
        let identifier = UUID().uuidString
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: "+00:00", with: "Z")
        let container = "<?xml version=\"1.0\"?><container version=\"1.0\" xmlns=\"urn:oasis:names:tc:opendocument:xmlns:container\"><rootfiles><rootfile full-path=\"OEBPS/content.opf\" media-type=\"application/oebps-package+xml\"/></rootfiles></container>"
        let package = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><package xmlns=\"http://www.idpf.org/2007/opf\" version=\"3.0\" unique-identifier=\"book-id\"><metadata xmlns:dc=\"http://purl.org/dc/elements/1.1/\"><dc:identifier id=\"book-id\">urn:uuid:\(identifier)</dc:identifier><dc:title>\(xmlEscape(title))</dc:title><dc:language>en</dc:language><meta property=\"dcterms:modified\">\(timestamp)</meta></metadata><manifest><item id=\"chapter\" href=\"chapter.xhtml\" media-type=\"application/xhtml+xml\"/><item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/></manifest><spine><itemref idref=\"chapter\"/></spine></package>"
        let chapter = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><html xmlns=\"http://www.w3.org/1999/xhtml\" lang=\"en\"><head><title>\(xmlEscape(title))</title></head><body><h1>\(xmlEscape(title))</h1><pre style=\"white-space:pre-wrap\">\(xmlEscape(text))</pre></body></html>"
        let nav = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><html xmlns=\"http://www.w3.org/1999/xhtml\" xmlns:epub=\"http://www.idpf.org/2007/ops\"><head><title>Contents</title></head><body><nav epub:type=\"toc\"><h1>Contents</h1><ol><li><a href=\"chapter.xhtml\">\(xmlEscape(title))</a></li></ol></nav></body></html>"
        let mimetype = root.appendingPathComponent("mimetype")
        try Data("application/epub+zip".utf8).write(to: mimetype)
        try Data(container.utf8).write(to: meta.appendingPathComponent("container.xml"))
        for (name, value) in [("content.opf", package), ("chapter.xhtml", chapter), ("nav.xhtml", nav)] { try Data(value.utf8).write(to: content.appendingPathComponent(name)) }
        // EPUB requires its first entry, mimetype, to be stored without compression.
        try ArchiveConversions.create([mimetype, meta, content], destination: destination, format: .zip, store: true)
    }

    private static func writeTextWorkbook(_ text: String, destination: URL, workspace: URL) throws {
        let root = workspace.appendingPathComponent("xlsx", isDirectory: true)
        let lines = text.components(separatedBy: .newlines)
        guard lines.count <= 1_048_576 else { throw ConversionError.invalidInput("The extracted text exceeds Excel's row limit.") }
        var rows = ""
        for (index, line) in lines.enumerated() {
            try Task.checkCancellation()
            guard line.utf16.count <= 32_767 else { throw ConversionError.invalidInput("A PDF text line exceeds Excel's 32,767-character cell limit.") }
            rows += "<row r=\"\(index + 1)\"><c r=\"A\(index + 1)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(xmlEscape(line))</t></is></c></row>"
        }
        try part(root, "[Content_Types].xml", "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/><Override PartName=\"/xl/worksheets/sheet1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/></Types>")
        try part(root, "_rels/.rels", relationships([("rId1", "officeDocument", "xl/workbook.xml")]))
        try part(root, "xl/workbook.xml", "<workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\"><sheets><sheet name=\"PDF text\" sheetId=\"1\" r:id=\"rId1\"/></sheets></workbook>")
        try part(root, "xl/_rels/workbook.xml.rels", relationships([("rId1", "worksheet", "worksheets/sheet1.xml")]))
        try part(root, "xl/worksheets/sheet1.xml", "<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><cols><col min=\"1\" max=\"1\" width=\"110\" customWidth=\"1\"/></cols><sheetData>\(rows)</sheetData></worksheet>")
        try zipPackage(root, destination: destination)
    }

    private static func writeImagePresentation(_ pages: [URL], destination: URL, workspace: URL) throws {
        let root = workspace.appendingPathComponent("pptx", isDirectory: true)
        let namespace = "xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\" xmlns:p=\"http://schemas.openxmlformats.org/presentationml/2006/main\""
        let group = "<p:nvGrpSpPr><p:cNvPr id=\"1\" name=\"\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"0\" cy=\"0\"/><a:chOff x=\"0\" y=\"0\"/><a:chExt cx=\"0\" cy=\"0\"/></a:xfrm></p:grpSpPr>"
        guard let first = pages.first, let source = CGImageSourceCreateWithURL(first as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw ConversionError.conversionFailed("Cannot read the PDF slide artwork.") }
        let longest = Double(max(image.width, image.height))
        let width = max(914_400, Int(12_192_000 * Double(image.width) / longest))
        let height = max(914_400, Int(12_192_000 * Double(image.height) / longest))
        var ids = ""
        var presentationRels: [(String, String, String)] = [("rIdMaster", "slideMaster", "slideMasters/slideMaster1.xml")]
        var overrides = "<Override PartName=\"/ppt/presentation.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml\"/><Override PartName=\"/ppt/slideMasters/slideMaster1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml\"/><Override PartName=\"/ppt/slideLayouts/slideLayout1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml\"/><Override PartName=\"/ppt/theme/theme1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.theme+xml\"/>"
        for (index, page) in pages.enumerated() {
            try Task.checkCancellation()
            let number = index + 1
            let imageSource = CGImageSourceCreateWithURL(page as CFURL, nil)!
            guard let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else { throw ConversionError.conversionFailed("Cannot read PDF page \(number).") }
            let scale = min(Double(width) / Double(cgImage.width), Double(height) / Double(cgImage.height))
            let imageWidth = Int(Double(cgImage.width) * scale), imageHeight = Int(Double(cgImage.height) * scale)
            let x = (width - imageWidth) / 2, y = (height - imageHeight) / 2
            let slide = "<p:sld \(namespace)><p:cSld><p:spTree>\(group)<p:pic><p:nvPicPr><p:cNvPr id=\"2\" name=\"PDF page \(number)\" descr=\"Rendered PDF page \(number)\"/><p:cNvPicPr><a:picLocks noChangeAspect=\"1\"/></p:cNvPicPr><p:nvPr/></p:nvPicPr><p:blipFill><a:blip r:embed=\"rIdImage\"/><a:stretch><a:fillRect/></a:stretch></p:blipFill><p:spPr><a:xfrm><a:off x=\"\(x)\" y=\"\(y)\"/><a:ext cx=\"\(imageWidth)\" cy=\"\(imageHeight)\"/></a:xfrm><a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></p:spPr></p:pic></p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>"
            try part(root, "ppt/slides/slide\(number).xml", slide)
            try part(root, "ppt/slides/_rels/slide\(number).xml.rels", relationships([("rIdLayout", "slideLayout", "../slideLayouts/slideLayout1.xml"), ("rIdImage", "image", "../media/page\(number).png")]))
            let media = root.appendingPathComponent("ppt/media")
            try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: page, to: media.appendingPathComponent("page\(number).png"))
            ids += "<p:sldId id=\"\(256 + index)\" r:id=\"rIdSlide\(number)\"/>"
            presentationRels.append(("rIdSlide\(number)", "slide", "slides/slide\(number).xml"))
            overrides += "<Override PartName=\"/ppt/slides/slide\(number).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slide+xml\"/>"
        }
        try part(root, "[Content_Types].xml", "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Default Extension=\"png\" ContentType=\"image/png\"/>\(overrides)</Types>")
        try part(root, "_rels/.rels", relationships([("rId1", "officeDocument", "ppt/presentation.xml")]))
        try part(root, "ppt/presentation.xml", "<p:presentation \(namespace)><p:sldMasterIdLst><p:sldMasterId id=\"2147483648\" r:id=\"rIdMaster\"/></p:sldMasterIdLst><p:sldIdLst>\(ids)</p:sldIdLst><p:sldSz cx=\"\(width)\" cy=\"\(height)\"/><p:notesSz cx=\"6858000\" cy=\"9144000\"/></p:presentation>")
        try part(root, "ppt/_rels/presentation.xml.rels", relationships(presentationRels))
        try part(root, "ppt/slideMasters/slideMaster1.xml", "<p:sldMaster \(namespace)><p:cSld name=\"ShiftDrop\"><p:spTree>\(group)</p:spTree></p:cSld><p:clrMap accent1=\"accent1\" accent2=\"accent2\" accent3=\"accent3\" accent4=\"accent4\" accent5=\"accent5\" accent6=\"accent6\" bg1=\"lt1\" bg2=\"lt2\" folHlink=\"folHlink\" hlink=\"hlink\" tx1=\"dk1\" tx2=\"dk2\"/><p:sldLayoutIdLst><p:sldLayoutId id=\"2147483649\" r:id=\"rIdLayout\"/></p:sldLayoutIdLst><p:txStyles><p:titleStyle/><p:bodyStyle/><p:otherStyle/></p:txStyles></p:sldMaster>")
        try part(root, "ppt/slideMasters/_rels/slideMaster1.xml.rels", relationships([("rIdLayout", "slideLayout", "../slideLayouts/slideLayout1.xml"), ("rIdTheme", "theme", "../theme/theme1.xml")]))
        try part(root, "ppt/slideLayouts/slideLayout1.xml", "<p:sldLayout \(namespace) type=\"blank\" preserve=\"1\"><p:cSld name=\"Blank\"><p:spTree>\(group)</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>")
        try part(root, "ppt/slideLayouts/_rels/slideLayout1.xml.rels", relationships([("rIdMaster", "slideMaster", "../slideMasters/slideMaster1.xml")]))
        let colors = [("dk1", "000000"), ("lt1", "FFFFFF"), ("dk2", "111E16"), ("lt2", "F4F5EE"), ("accent1", "586B57"), ("accent2", "AABFA2"), ("accent3", "D6EAAE"), ("accent4", "87956D"), ("accent5", "C4CEBA"), ("accent6", "425348"), ("hlink", "345EAA"), ("folHlink", "744B91")].map { "<a:\($0.0)><a:srgbClr val=\"\($0.1)\"/></a:\($0.0)>" }.joined()
        let fill = "<a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill>"
        let line = "<a:ln w=\"12700\">\(fill)<a:prstDash val=\"solid\"/></a:ln>"
        let effect = "<a:effectStyle><a:effectLst/></a:effectStyle>"
        try part(root, "ppt/theme/theme1.xml", "<a:theme xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" name=\"ShiftDrop\"><a:themeElements><a:clrScheme name=\"ShiftDrop\">\(colors)</a:clrScheme><a:fontScheme name=\"System\"><a:majorFont><a:latin typeface=\"Arial\"/><a:ea typeface=\"\"/><a:cs typeface=\"\"/></a:majorFont><a:minorFont><a:latin typeface=\"Arial\"/><a:ea typeface=\"\"/><a:cs typeface=\"\"/></a:minorFont></a:fontScheme><a:fmtScheme name=\"ShiftDrop\"><a:fillStyleLst>\(String(repeating: fill, count: 3))</a:fillStyleLst><a:lnStyleLst>\(String(repeating: line, count: 3))</a:lnStyleLst><a:effectStyleLst>\(String(repeating: effect, count: 3))</a:effectStyleLst><a:bgFillStyleLst>\(String(repeating: fill, count: 3))</a:bgFillStyleLst></a:fmtScheme></a:themeElements></a:theme>")
        try zipPackage(root, destination: destination)
    }

    private static func relationships(_ entries: [(String, String, String)]) -> String {
        "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">" + entries.map { "<Relationship Id=\"\($0.0)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/\($0.1)\" Target=\"\($0.2)\"/>" }.joined() + "</Relationships>"
    }
    private static func part(_ root: URL, _ path: String, _ xml: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>" + xml).utf8).write(to: url)
    }
    private static func zipPackage(_ root: URL, destination: URL) throws {
        let entries = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).sorted { $0.lastPathComponent < $1.lastPathComponent }
        try ArchiveConversions.create(entries, destination: destination, format: .zip)
    }

    private static func readEPUB(_ input: URL, workspace: URL) throws -> String {
        let root = workspace.appendingPathComponent("epub-import", isDirectory: true)
        try ArchiveConversions.extract(input, destination: root)
        let container = try XMLItems(url: root.appendingPathComponent("META-INF/container.xml"))
        guard let packagePath = container.items.first(where: { $0.name == "rootfile" })?.attributes["full-path"] else { throw ConversionError.invalidInput("The EPUB has no package document.") }
        let packageURL = try containedURL(packagePath, relativeTo: root, root: root)
        let package = try XMLItems(url: packageURL)
        let manifest = Dictionary(package.items.filter { $0.name == "item" }.compactMap { item -> (String, [String: String])? in
            guard let id = item.attributes["id"] else { return nil }; return (id, item.attributes)
        }, uniquingKeysWith: { first, _ in first })
        var chapters: [String] = []
        var textBytes = 0
        for item in package.items where item.name == "itemref" {
            try Task.checkCancellation()
            guard let id = item.attributes["idref"], let entry = manifest[id], let href = entry["href"], entry["media-type"] == "application/xhtml+xml" || entry["media-type"] == "text/html" else { continue }
            let url = try containedURL(href.components(separatedBy: "#")[0], relativeTo: packageURL.deletingLastPathComponent(), root: root)
            let data = try Data(contentsOf: url)
            textBytes += data.count
            guard textBytes <= 32 * 1024 * 1024 else { throw ConversionError.invalidInput("The EPUB exceeds the text-size limit.") }
            chapters.append(HTMLText.plain(try TextConversions.decode(data)))
        }
        guard !chapters.isEmpty else { throw ConversionError.invalidInput("No readable text chapters were found in the EPUB spine.") }
        return chapters.joined(separator: "\n\n")
    }

    private static func containedURL(_ href: String, relativeTo base: URL, root: URL) throws -> URL {
        guard let decoded = href.removingPercentEncoding, !decoded.contains(":"), !decoded.hasPrefix("/"), !decoded.contains("\\") else { throw ConversionError.unsafeArchive("An EPUB resource uses an external or invalid path.") }
        let url = base.appendingPathComponent(decoded).standardizedFileURL
        guard url.path.hasPrefix(root.standardizedFileURL.path + "/") else { throw ConversionError.unsafeArchive("An EPUB resource leaves its container.") }
        return url
    }

    private static func xmlEscape(_ source: String) -> String {
        let legal = String(String.UnicodeScalarView(source.unicodeScalars.filter { $0.value == 9 || $0.value == 10 || $0.value == 13 || ($0.value >= 32 && $0.value != 0xFFFE && $0.value != 0xFFFF) }))
        return legal.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}

private final class SVGValidator: NSObject, XMLParserDelegate {
    var valid = true
    var sawSVG = false
    private var styleDepth = 0
    private var styleText = ""

    // XMLParser supplies decoded values. Validate here, before AppKit receives
    // the document, so character references cannot conceal a CSS resource URL.
    private func safeResources(_ source: String) -> Bool {
        let folded = source.lowercased()
        guard !folded.contains("\\"), !folded.contains("/*"), !folded.contains("@import") else { return false }
        guard let regex = try? NSRegularExpression(pattern: "(?i)url\\s*\\(([^)]*)\\)") else { return false }
        for match in regex.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
            let target = (source as NSString).substring(with: match.range(at: 1)).trimmingCharacters(in: CharacterSet(charactersIn: " \t\n\r\"'"))
            guard target.hasPrefix("#"), target.count > 1 else { return false }
        }
        return true
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        let name = elementName.components(separatedBy: ":").last?.lowercased() ?? ""
        if !sawSVG { sawSVG = name == "svg"; if !sawSVG { valid = false; parser.abortParsing() } }
        if ["script", "foreignobject", "animate", "animatemotion", "animatetransform", "set", "discard"].contains(name) { valid = false; parser.abortParsing() }
        if name == "style" { styleDepth += 1; if styleDepth == 1 { styleText = "" } }
        for (key, value) in attributeDict {
            let attribute = key.components(separatedBy: ":").last?.lowercased() ?? ""
            if (attribute == "href" && !value.hasPrefix("#")) || attribute == "base" || attribute.hasPrefix("on") || !safeResources(value) { valid = false; parser.abortParsing() }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if styleDepth > 0 { styleText += string }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if styleDepth > 0 { styleText += String(decoding: CDATABlock, as: UTF8.self) }
    }

    func parser(_ parser: XMLParser, foundProcessingInstructionWithTarget target: String, data: String?) {
        valid = false
        parser.abortParsing()
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName.components(separatedBy: ":").last?.lowercased() == "style", styleDepth > 0 {
            styleDepth -= 1
            if styleDepth == 0, !safeResources(styleText) { valid = false; parser.abortParsing() }
        }
    }
}

private final class XMLItems: NSObject, XMLParserDelegate {
    struct Item { let name: String; let attributes: [String: String] }
    var items: [Item] = []
    init(url: URL) throws {
        super.init()
        let data = try Data(contentsOf: url)
        guard data.count <= 8 * 1024 * 1024 else { throw ConversionError.invalidInput("An EPUB manifest exceeds the size limit.") }
        let declaration = String(decoding: data, as: UTF8.self).uppercased()
        guard !declaration.contains("<!DOCTYPE"), !declaration.contains("<!ENTITY") else { throw ConversionError.invalidInput("EPUB manifests with document-type or entity declarations are not supported.") }
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = self
        guard parser.parse() else { throw ConversionError.invalidInput("An EPUB XML manifest is damaged.") }
    }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        items.append(Item(name: elementName.components(separatedBy: ":").last ?? elementName, attributes: attributeDict))
    }
}
