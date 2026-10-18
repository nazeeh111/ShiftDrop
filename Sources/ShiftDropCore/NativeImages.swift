import Foundation
import CoreGraphics
import ImageIO
import PDFKit

enum NativeImages {
    static func load(_ input: URL, options: ConversionOptions) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(input as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0 else {
            throw ConversionError.invalidInput("The image is damaged or its decoder is unavailable.")
        }
        let maximum = min(options.maxPixelSize ?? max(width, height), max(width, height))
        let ratio = min(1, Double(maximum) / Double(max(width, height)))
        guard maximum <= 16384, Double(width) * Double(height) * ratio * ratio <= 80_000_000 else {
            throw ConversionError.invalidOptions("This image is too large to decode safely. Set a smaller maximum dimension.")
        }
        let propertiesForDecode: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximum,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, propertiesForDecode as CFDictionary) else {
            throw ConversionError.invalidInput("The image could not be decoded.")
        }
        return image
    }

    static func convert(_ input: URL, destination: URL, format: ConversionFormat, options: ConversionOptions) throws {
        try Task.checkCancellation()
        let image = try load(input, options: options)
        try write(image, destination: destination, format: format, quality: options.quality)
    }

    static func write(_ source: CGImage, destination: URL, format: ConversionFormat, quality: Double) throws {
        try Task.checkCancellation()
        let image: CGImage
        if format == .jpeg || format == .bmp {
            guard let context = CGContext(data: nil, width: source.width, height: source.height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
                throw ConversionError.conversionFailed("Cannot allocate an image canvas.")
            }
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: source.width, height: source.height))
            context.draw(source, in: CGRect(x: 0, y: 0, width: source.width, height: source.height))
            guard let flattened = context.makeImage() else { throw ConversionError.conversionFailed("Cannot flatten image transparency.") }
            image = flattened
        } else { image = source }
        guard let output = CGImageDestinationCreateWithURL(destination as CFURL, format.imageType as CFString, 1, nil) else {
            throw ConversionError.unsupported("This Mac cannot encode \(format.title).")
        }
        CGImageDestinationAddImage(output, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(output) else { throw ConversionError.conversionFailed("The image encoder could not finish.") }
    }

    static func imageToPDF(_ input: URL, destination: URL, options: ConversionOptions) throws {
        let image = try load(input, options: options)
        var bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        guard let context = CGContext(destination as CFURL, mediaBox: &bounds, nil) else {
            throw ConversionError.conversionFailed("Cannot create the PDF.")
        }
        context.beginPDFPage(nil)
        context.draw(image, in: bounds)
        context.endPDFPage()
        context.closePDF()
        try Task.checkCancellation()
    }

    static func convertPDF(_ input: URL, directory: URL, format: ConversionFormat, options: ConversionOptions) throws -> [URL] {
        guard let document = PDFDocument(url: input), !document.isLocked, document.pageCount > 0 else {
            throw ConversionError.invalidInput("The PDF is damaged, empty, or locked. Unlock it before converting.")
        }
        guard document.pageCount <= 1000 else { throw ConversionError.invalidInput("PDF exports are limited to 1,000 pages per job.") }
        if format == .txt {
            var pages: [String] = []
            for index in 0..<document.pageCount {
                try Task.checkCancellation()
                pages.append(document.page(at: index)?.string ?? "")
            }
            let text = pages.joined(separator: "\n\n")
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ConversionError.conversionFailed("The PDF has no selectable text. Text recognition (OCR) is not included.")
            }
            let url = directory.appendingPathComponent("text.txt")
            try Data(text.utf8).write(to: url)
            return [url]
        }
        var outputs: [URL] = []
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            let url = directory.appendingPathComponent("page-\(index + 1).\(format.fileExtension)")
            try autoreleasepool {
                guard let page = document.page(at: index), let pageRef = page.pageRef else { throw ConversionError.conversionFailed("Cannot read PDF page \(index + 1).") }
                let bounds = pageRef.getBoxRect(.mediaBox)
                guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else {
                    throw ConversionError.invalidInput("PDF page \(index + 1) has invalid dimensions.")
                }
                let rotation = ((pageRef.rotationAngle % 360) + 360) % 360
                let quarterTurn = rotation == 90 || rotation == 270
                let displayWidth = quarterTurn ? bounds.height : bounds.width
                let displayHeight = quarterTurn ? bounds.width : bounds.height
                let maxPixels = Double(options.maxPixelSize ?? 2048)
                let scale = min(2, maxPixels / max(displayWidth, displayHeight))
                let width = max(1, Int(ceil(displayWidth * scale)))
                let height = max(1, Int(ceil(displayHeight * scale)))
                guard width <= 16384, height <= 16384, width * height <= 80_000_000,
                      let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                    throw ConversionError.conversionFailed("PDF page \(index + 1) is too large to render safely.")
                }
                context.setFillColor(CGColor(gray: 1, alpha: 1))
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))
                // Core Graphics applies the PDF's own rotation and nonzero media-box origin.
                // Scale explicitly: getDrawingTransform centers a small page without enlarging it.
                context.scaleBy(x: CGFloat(width) / displayWidth, y: CGFloat(height) / displayHeight)
                context.concatenate(pageRef.getDrawingTransform(.mediaBox, rect: CGRect(x: 0, y: 0, width: displayWidth, height: displayHeight), rotate: 0, preserveAspectRatio: true))
                context.drawPDFPage(pageRef)
                guard let image = context.makeImage() else { throw ConversionError.conversionFailed("Cannot render PDF page \(index + 1).") }
                try write(image, destination: url, format: format, quality: options.quality)
            }
            outputs.append(url)
        }
        return outputs
    }
}
