import Foundation
import PDFKit
import CoreGraphics
import ImageIO

public enum PDFTools {
    public static func run(_ request: ToolRequest) async throws -> ConversionResult {
        try Task.checkCancellation()
        guard !request.inputs.isEmpty, request.inputs.count <= 32, request.outputDirectory.isFileURL else {
            throw ConversionError.invalidInput("Choose 1–32 local PDFs and a local output folder.")
        }
        guard [.mergePDF, .organizePDF, .compress, .metadata].contains(request.tool) else { throw ConversionError.unsupported("\(request.tool.title) is not a PDF tool.") }
        let access = (request.inputs + [request.outputDirectory]).filter { $0.startAccessingSecurityScopedResource() }
        defer { access.forEach { $0.stopAccessingSecurityScopedResource() } }
        var documents: [PDFDocument] = []
        var totalPages = 0
        for input in request.inputs {
            guard input.isFileURL, (try input.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else { throw ConversionError.invalidInput("Choose local regular PDF files.") }
            _ = try ConversionEngine.byteCount(input)
            guard let document = PDFDocument(url: input), !document.isLocked, document.pageCount > 0 else { throw ConversionError.invalidInput("\(input.lastPathComponent) is not a readable, unlocked, nonempty PDF.") }
            totalPages += document.pageCount
            guard totalPages <= 1000 else { throw ConversionError.invalidInput("PDF tools support at most 1,000 source pages per operation.") }
            documents.append(document)
        }
        let stage = try ToolOutput.stage(in: request.outputDirectory)
        defer { try? FileManager.default.removeItem(at: stage) }
        var outputs: [URL] = []
        if request.tool == .mergePDF {
            guard documents.count >= 2 else { throw ConversionError.invalidInput("Choose at least two PDFs to merge.") }
            let merged = PDFDocument()
            for document in documents {
                for index in 0..<document.pageCount {
                    try Task.checkCancellation()
                    try appendCopy(document.page(at: index), to: merged)
                }
            }
            merged.documentAttributes = documents[0].documentAttributes
            applyMetadata(request.settings, to: merged)
            let output = stage.appendingPathComponent("merged.pdf")
            try write(merged, to: output)
            outputs = [output]
        } else {
            for (index, document) in documents.enumerated() {
                try Task.checkCancellation()
                let output = stage.appendingPathComponent("pdf-\(index).pdf")
                switch request.tool {
                case .organizePDF:
                    guard request.settings.rotation.isMultiple(of: 90) else { throw ConversionError.invalidOptions("Page rotation must be a multiple of 90 degrees.") }
                    let order = try pageOrder(request.settings.pageOrder, count: document.pageCount)
                    let rotations = try pageRotations(request.settings.pageRotations, count: order.count)
                    let organized = PDFDocument()
                    for (position, number) in order.enumerated() {
                        try Task.checkCancellation()
                        guard let copy = document.page(at: number - 1)?.copy() as? PDFPage else { throw ConversionError.conversionFailed("Cannot copy page \(number).") }
                        copy.rotation = ((copy.rotation + request.settings.rotation % 360 + (rotations[position + 1] ?? 0)) % 360 + 360) % 360
                        organized.insert(copy, at: organized.pageCount)
                    }
                    organized.documentAttributes = document.documentAttributes
                    applyMetadata(request.settings, to: organized)
                    try write(organized, to: output)
                    outputs.append(output)
                case .metadata:
                    if !request.settings.removeMetadata && request.settings.metadataTitle.isEmpty {
                        let report = stage.appendingPathComponent("pdf-\(index).json")
                        let rawAttributes: [AnyHashable: Any] = document.documentAttributes ?? [:]
                        let attributes = rawAttributes.reduce(into: [String: String]()) { $0[String(describing: $1.key)] = String(describing: $1.value) }
                        let pages: [[String: Any]] = (0..<document.pageCount).compactMap { page in
                            guard let value = document.page(at: page) else { return nil }
                            let bounds = value.bounds(for: .mediaBox)
                            return ["page": page + 1, "widthPoints": bounds.width, "heightPoints": bounds.height, "rotation": value.rotation]
                        }
                        let reportData: [String: Any] = ["file": request.inputs[index].lastPathComponent, "pageCount": document.pageCount, "encrypted": document.isEncrypted, "documentInfo": attributes, "pages": pages, "scope": "PDF document-info attributes; not an audit of embedded objects, attachments, or XMP."]
                        try JSONSerialization.data(withJSONObject: reportData, options: [.prettyPrinted, .sortedKeys]).write(to: report)
                        outputs.append(report)
                    } else {
                        applyMetadata(request.settings, to: document)
                        try write(document, to: output)
                        outputs.append(output)
                    }
                case .compress:
                    try rasterize(document, to: output, settings: request.settings)
                    outputs.append(output)
                default: break
                }
            }
        }
        try Task.checkCancellation()
        return try ToolOutput.publish(outputs, request: request)
    }

    private static func pageOrder(_ value: String, count: Int) throws -> [Int] {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return Array(1...count) }
        let tokens = value.split(separator: ",", omittingEmptySubsequences: false)
        guard tokens.count <= 1000 else { throw ConversionError.invalidOptions("Output is limited to 1,000 pages.") }
        var order: [Int] = []
        for token in tokens {
            let ends = token.split(separator: "-", omittingEmptySubsequences: false)
            guard (1...2).contains(ends.count), let first = Int(ends[0].trimmingCharacters(in: .whitespacesAndNewlines)), (1...count).contains(first) else { throw ConversionError.invalidOptions("Use page numbers or ranges such as 1-3,5,3-1. Pages must be from 1 to \(count); repeats are allowed.") }
            let last: Int
            if ends.count == 2 {
                guard let end = Int(ends[1].trimmingCharacters(in: .whitespacesAndNewlines)), (1...count).contains(end) else { throw ConversionError.invalidOptions("Page ranges must stay between 1 and \(count).") }
                last = end
            } else { last = first }
            let additions = abs(last - first) + 1
            guard additions <= 1000 - order.count else { throw ConversionError.invalidOptions("Output is limited to 1,000 pages.") }
            order += stride(from: first, through: last, by: first <= last ? 1 : -1)
        }
        return order
    }

    /// Rotation keys identify output positions, so repeated copies can rotate independently.
    private static func pageRotations(_ value: String, count: Int) throws -> [Int: Int] {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [:] }
        let tokens = value.split(separator: ",", omittingEmptySubsequences: false)
        guard tokens.count <= 1000 else { throw ConversionError.invalidOptions("At most 1,000 page rotations are supported.") }
        var rotations: [Int: Int] = [:]
        for token in tokens {
            let pair = token.split(separator: ":", omittingEmptySubsequences: false)
            guard pair.count == 2, let page = Int(pair[0].trimmingCharacters(in: .whitespacesAndNewlines)), (1...count).contains(page), let angle = Int(pair[1].trimmingCharacters(in: .whitespacesAndNewlines)), angle.isMultiple(of: 90), rotations[page] == nil else { throw ConversionError.invalidOptions("Use one rotation per output page, such as 1:90,3:180. Pages must exist and angles must be multiples of 90.") }
            rotations[page] = angle % 360
        }
        return rotations
    }

    private static func appendCopy(_ page: PDFPage?, to document: PDFDocument) throws {
        guard let copy = page?.copy() as? PDFPage else { throw ConversionError.conversionFailed("Cannot copy a PDF page.") }
        document.insert(copy, at: document.pageCount)
    }

    private static func applyMetadata(_ settings: ToolSettings, to document: PDFDocument) {
        if settings.removeMetadata { document.documentAttributes = [:] }
        if !settings.metadataTitle.isEmpty {
            var attributes = document.documentAttributes ?? [:]
            attributes[PDFDocumentAttribute.titleAttribute] = settings.metadataTitle
            document.documentAttributes = attributes
        }
    }

    private static func write(_ document: PDFDocument, to output: URL) throws {
        guard document.write(to: output), let verification = PDFDocument(url: output), verification.pageCount == document.pageCount else { throw ConversionError.conversionFailed("The PDF could not be saved completely.") }
    }

    /// Intentionally rasterizes into JPEG pages. This removes selectable text and interactive links/forms; visible annotations are flattened.
    private static func rasterize(_ document: PDFDocument, to output: URL, settings: ToolSettings) throws {
        guard settings.quality.isFinite, (0.05...1).contains(settings.quality), (64...8192).contains(settings.width) else { throw ConversionError.invalidOptions("PDF raster compression needs quality 0.05–1 and a maximum dimension of 64–8,192 pixels.") }
        var pageBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        var metadata: [CFString: Any] = [:]
        if !settings.metadataTitle.isEmpty { metadata[kCGPDFContextTitle] = settings.metadataTitle }
        guard let pdf = CGContext(output as CFURL, mediaBox: &pageBox, metadata as CFDictionary) else { throw ConversionError.conversionFailed("Cannot create the compressed PDF.") }
        defer { pdf.closePDF() }
        var totalPixels = 0
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            try autoreleasepool {
                guard let page = document.page(at: index), let source = page.pageRef else { throw ConversionError.conversionFailed("Cannot read page \(index + 1).") }
                let bounds = source.getBoxRect(.mediaBox)
                guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else { throw ConversionError.invalidInput("Page \(index + 1) has invalid dimensions.") }
                let rotated = abs(source.rotationAngle % 180) == 90
                let display = CGSize(width: rotated ? bounds.height : bounds.width, height: rotated ? bounds.width : bounds.height)
                let scale = min(2, Double(settings.width) / max(display.width, display.height))
                let width = max(1, Int(ceil(display.width * scale))), height = max(1, Int(ceil(display.height * scale)))
                guard width * height <= 32_000_000 else { throw ConversionError.invalidOptions("A PDF raster page exceeds 32 million pixels. Use a smaller maximum dimension.") }
                totalPixels += width * height
                guard totalPixels <= 500_000_000 else { throw ConversionError.invalidOptions("PDF raster compression is limited to 500 million total pixels per file. Use a smaller maximum dimension.") }
                guard let canvas = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw ConversionError.conversionFailed("Cannot allocate a PDF page canvas.") }
                canvas.setFillColor(CGColor(gray: 1, alpha: 1)); canvas.fill(CGRect(x: 0, y: 0, width: width, height: height))
                canvas.scaleBy(x: CGFloat(width) / display.width, y: CGFloat(height) / display.height)
                canvas.concatenate(source.getDrawingTransform(.mediaBox, rect: CGRect(origin: .zero, size: display), rotate: 0, preserveAspectRatio: true))
                canvas.drawPDFPage(source)
                // Draw annotations into the pixels so their visible content survives rasterization.
                // Structural interactivity and text semantics are intentionally not retained.
                if !page.annotations.isEmpty {
                    for annotation in page.annotations { annotation.draw(with: .mediaBox, in: canvas) }
                }
                guard let image = canvas.makeImage() else { throw ConversionError.conversionFailed("Cannot render PDF page \(index + 1).") }
                let encoded = NSMutableData()
                guard let encoder = CGImageDestinationCreateWithData(encoded, "public.jpeg" as CFString, 1, nil) else { throw ConversionError.conversionFailed("JPEG encoding is unavailable.") }
                CGImageDestinationAddImage(encoder, image, [kCGImageDestinationLossyCompressionQuality: settings.quality] as CFDictionary)
                guard CGImageDestinationFinalize(encoder), let consumer = CGDataProvider(data: encoded), let jpeg = CGImage(jpegDataProviderSource: consumer, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { throw ConversionError.conversionFailed("Cannot encode PDF page \(index + 1).") }
                var media = CGRect(origin: .zero, size: display)
                let box = Data(bytes: &media, count: MemoryLayout<CGRect>.size)
                pdf.beginPDFPage([kCGPDFContextMediaBox: box] as CFDictionary)
                pdf.draw(jpeg, in: media)
                pdf.endPDFPage()
            }
        }
    }
}
