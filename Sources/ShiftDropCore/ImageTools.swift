import Foundation
import CoreGraphics
import CoreImage
import CoreText
import ImageIO
import Vision

/// Native image operations. Coordinates exposed to callers use a top-left origin.
public enum ImageTools {
    public static func run(_ request: ToolRequest) async throws -> ConversionResult {
        try Task.checkCancellation()
        guard !request.inputs.isEmpty, request.inputs.count <= 1000 else {
            throw ConversionError.invalidInput("Choose between 1 and 1,000 images.")
        }
        let locations = request.inputs + [request.outputDirectory] + (request.settings.backgroundImage.map { [$0] } ?? []) + request.settings.marks.compactMap(\.imageURL)
        let access = locations.filter { $0.startAccessingSecurityScopedResource() }
        defer { access.forEach { $0.stopAccessingSecurityScopedResource() } }
        let supported: Set<FileTool> = [.editImage, .annotateImage, .frameImage, .cropImage, .redactImage, .collage, .imagesPDF, .compress, .metadata]
        guard supported.contains(request.tool) else { throw ConversionError.unsupported("This is not an image tool.") }
        for input in request.inputs {
            guard input.isFileURL, FormatCatalog.kind(for: input) == "Image" else { throw ConversionError.invalidInput("This tool needs local image files.") }
            let attributes = try input.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard attributes.isRegularFile == true, attributes.isSymbolicLink != true else { throw ConversionError.invalidInput("Choose regular image files, not links or folders.") }
        }
        try validate(request.settings)
        let staging = try ToolOutput.stage(in: request.outputDirectory)
        defer { try? FileManager.default.removeItem(at: staging) }
        let outputs: [URL]
        switch request.tool {
        case .collage:
            let url = staging.appendingPathComponent("collage.png")
            try collage(request, destination: url)
            outputs = [url]
        case .imagesPDF:
            let url = staging.appendingPathComponent("images.pdf")
            try imagesPDF(request.inputs, destination: url)
            outputs = [url]
        default:
            var files: [URL] = []
            for (index, input) in request.inputs.enumerated() {
                try Task.checkCancellation()
                let file = try autoreleasepool { () throws -> URL in
                    let inspection = request.tool == .metadata && !request.settings.removeMetadata && request.settings.metadataTitle.isEmpty
                    let ext = inspection ? "json" : request.tool == .compress ? "jpg" : "png"
                    let url = staging.appendingPathComponent("image-\(index).\(ext)")
                    if inspection { try inspectMetadata(input, destination: url); return url }
                    let image = try load(input)
                    switch request.tool {
                    case .compress: try compress(image, destination: url, settings: request.settings)
                    case .metadata: try metadata(image, input: input, destination: url, settings: request.settings)
                    case .cropImage:
                        let rect = try checkedRect(request.settings, image: image)
                        guard let crop = image.cropping(to: rect) else { throw ConversionError.conversionFailed("Cannot crop this image.") }
                        try write(crop, url)
                    case .editImage: try write(adjust(image, settings: request.settings), url)
                    case .frameImage: try write(frame(image, settings: request.settings), url)
                    case .annotateImage: try write(annotate(image, settings: request.settings), url)
                    case .redactImage: try write(redact(image, settings: request.settings), url)
                    default: throw ConversionError.unsupported("Unknown image operation.")
                    }
                    return url
                }
                files.append(file)
            }
            outputs = files
        }
        try Task.checkCancellation()
        return try ToolOutput.publish(outputs, request: request)
    }

    private static func validate(_ settings: ToolSettings) throws {
        guard settings.quality.isFinite, (0...1).contains(settings.quality), settings.targetBytes >= 0,
              settings.exposure.isFinite, (-10...10).contains(settings.exposure),
              settings.brightness.isFinite, (-1...1).contains(settings.brightness),
              settings.sharpness.isFinite, (0...2).contains(settings.sharpness),
              settings.noiseReduction.isFinite, (0...1).contains(settings.noiseReduction),
              settings.dehaze.isFinite, (0...1).contains(settings.dehaze),
              settings.clarity.isFinite, (0...1).contains(settings.clarity),
              settings.grain.isFinite, (0...1).contains(settings.grain),
              settings.frameBlur.isFinite, (0...100).contains(settings.frameBlur),
              settings.frameShadow.isFinite, (0...100).contains(settings.frameShadow),
              settings.saturation.isFinite, (0...3).contains(settings.saturation),
              settings.contrast.isFinite, (0...4).contains(settings.contrast),
              settings.fontSize.isFinite, (1...2048).contains(settings.fontSize),
              settings.lineWidth.isFinite, (0.5...1024).contains(settings.lineWidth),
              (0...4096).contains(settings.padding), (0...8192).contains(settings.cornerRadius),
              (1...100).contains(settings.columns), settings.text.utf8.count <= 50_000,
              settings.metadataTitle.utf8.count <= 16_384, settings.marks.count <= 256,
              settings.regions.count <= 4096, settings.points.count <= 100_000,
              settings.marks.reduce(0, { $0 + $1.points.count }) <= 1_000_000 else {
            throw ConversionError.invalidOptions("Image adjustments, quality, padding, or text are outside the supported limits.")
        }
    }
    private static func dimensions(_ width: Int, _ height: Int) throws {
        guard (1...16384).contains(width), (1...16384).contains(height), Double(width) * Double(height) <= 80_000_000 else {
            throw ConversionError.invalidOptions("The canvas must be at most 16,384 pixels per side and 80 million pixels total.")
        }
    }
    private static func load(_ url: URL) throws -> CGImage {
        if url.pathExtension.lowercased() == "svg" {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ShiftDropSVG-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: directory) }
            let raster = directory.appendingPathComponent("source.png")
            try DocumentConversions.rasterizeSVG(url, destination: raster, options: ConversionOptions(quality: 1, maxPixelSize: 16384))
            return try NativeImages.load(raster, options: ConversionOptions())
        }
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 1 {
            throw ConversionError.unsupported("Image tools work on still images. Extract a frame or page before editing animated or multipage images.")
        }
        return try NativeImages.load(url, options: ConversionOptions())
    }
    private static func write(_ image: CGImage, _ url: URL) throws { try NativeImages.write(image, destination: url, format: .png, quality: 1) }
    private static func context(_ width: Int, _ height: Int) throws -> CGContext {
        try dimensions(width, height)
        guard let value = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ConversionError.conversionFailed("Cannot allocate an image canvas.")
        }
        value.interpolationQuality = .high
        return value
    }
    private static func image(_ context: CGContext) throws -> CGImage {
        guard let image = context.makeImage() else { throw ConversionError.conversionFailed("Cannot finish rendering this image.") }
        return image
    }
    private static func color(_ text: String) throws -> CGColor {
        let value = text.hasPrefix("#") ? String(text.dropFirst()) : text
        guard value.count == 6, let rgb = UInt32(value, radix: 16) else { throw ConversionError.invalidOptions("Use a six-digit hexadecimal color, such as 17211B.") }
        return CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [
            CGFloat((rgb >> 16) & 255) / 255, CGFloat((rgb >> 8) & 255) / 255, CGFloat(rgb & 255) / 255, 1])!
    }
    private static func checkedRect(_ settings: ToolSettings, image: CGImage) throws -> CGRect {
        guard settings.x >= 0, settings.y >= 0, settings.width > 0, settings.height > 0,
              settings.x <= image.width, settings.y <= image.height,
              settings.width <= image.width - settings.x, settings.height <= image.height - settings.y else {
            throw ConversionError.invalidOptions("The rectangle must fit inside the image. Coordinates start at its top-left corner.")
        }
        return CGRect(x: settings.x, y: settings.y, width: settings.width, height: settings.height)
    }
    private static func bottomRect(_ top: CGRect, height: Int) -> CGRect {
        CGRect(x: top.minX, y: CGFloat(height) - top.maxY, width: top.width, height: top.height)
    }
    private static func fit(_ image: CGImage, into rect: CGRect, fill: Bool = false) -> CGRect {
        let factors = [rect.width / CGFloat(image.width), rect.height / CGFloat(image.height)]
        let scale = fill ? factors.max()! : factors.min()!
        let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        return CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height)
    }

    private static func adjust(_ source: CGImage, settings: ToolSettings) throws -> CGImage {
        let input = CIImage(cgImage: source)
        var result = input.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: settings.exposure])
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: settings.saturation,
                kCIInputContrastKey: settings.contrast, kCIInputBrightnessKey: settings.brightness])
        if settings.noiseReduction > 0 {
            result = result.applyingFilter("CINoiseReduction", parameters: ["inputNoiseLevel": settings.noiseReduction * 0.1, "inputSharpness": 0])
        }
        if settings.sharpness > 0 {
            result = result.applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: settings.sharpness])
        }
        if settings.dehaze > 0 {
            // A bounded tonal correction for low-contrast haze, not depth estimation.
            result = result.applyingFilter("CIToneCurve", parameters: [
                "inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: 0.25, y: 0.25 - settings.dehaze * 0.08),
                "inputPoint2": CIVector(x: 0.5, y: 0.5), "inputPoint3": CIVector(x: 0.75, y: 0.75 + settings.dehaze * 0.03), "inputPoint4": CIVector(x: 1, y: 1)])
        }
        if settings.clarity > 0 {
            result = result.clampedToExtent().applyingFilter("CIUnsharpMask", parameters: [kCIInputRadiusKey: 20, kCIInputIntensityKey: settings.clarity * 1.5]).cropped(to: input.extent)
        }
        if settings.grain > 0 {
            guard let random = CIFilter(name: "CIRandomGenerator")?.outputImage else { throw ConversionError.unsupported("This Mac cannot generate grain.") }
            let noise = random.cropped(to: input.extent).applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: settings.grain, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: settings.grain, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: settings.grain, w: 0),
                    "inputBiasVector": CIVector(x: 0.5 - settings.grain / 2, y: 0.5 - settings.grain / 2, z: 0.5 - settings.grain / 2, w: 0)])
            result = noise.applyingFilter("CISoftLightBlendMode", parameters: [kCIInputBackgroundImageKey: result])
                .applyingFilter("CISourceInCompositing", parameters: [kCIInputBackgroundImageKey: input])
        }
        try Task.checkCancellation()
        guard let image = CIContext(options: [.cacheIntermediates: false]).createCGImage(result, from: input.extent) else { throw ConversionError.conversionFailed("Cannot apply image adjustments.") }
        return image
    }
    private static func frame(_ source: CGImage, settings: ToolSettings) throws -> CGImage {
        let canvas = try context(settings.width, settings.height)
        let bounds = CGRect(x: 0, y: 0, width: settings.width, height: settings.height)
        canvas.setFillColor(try color(settings.backgroundHex)); canvas.fill(bounds)
        if let background = settings.backgroundImage {
            let values = try background.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { throw ConversionError.invalidInput("Choose a regular image for the background.") }
            let image = try load(background)
            canvas.draw(image, in: fit(image, into: bounds, fill: true))
        } else if settings.frameBlur > 0 {
            canvas.draw(source, in: fit(source, into: bounds, fill: true))
        }
        if settings.frameBlur > 0 {
            let background = CIImage(cgImage: try image(canvas))
            let blurred = background.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: settings.frameBlur]).cropped(to: background.extent)
            guard let rendered = CIContext(options: [.cacheIntermediates: false]).createCGImage(blurred, from: background.extent) else { throw ConversionError.conversionFailed("Cannot blur the frame background.") }
            canvas.draw(rendered, in: bounds)
        }
        let content = bounds.insetBy(dx: CGFloat(settings.padding), dy: CGFloat(settings.padding))
        guard content.width >= 1, content.height >= 1 else { throw ConversionError.invalidOptions("Padding leaves no room for the image.") }
        let rect = fit(source, into: content)
        let card = try context(max(1, Int(ceil(rect.width))), max(1, Int(ceil(rect.height))))
        let cardBounds = CGRect(x: 0, y: 0, width: card.width, height: card.height)
        card.addPath(CGPath(roundedRect: cardBounds, cornerWidth: CGFloat(settings.cornerRadius), cornerHeight: CGFloat(settings.cornerRadius), transform: nil))
        card.clip(); card.draw(source, in: cardBounds)
        if settings.frameShadow > 0 {
            canvas.setShadow(offset: CGSize(width: 0, height: -settings.frameShadow * 0.4), blur: settings.frameShadow, color: CGColor(gray: 0, alpha: 0.4))
        }
        canvas.draw(try image(card), in: rect)
        return try image(canvas)
    }
    private static func annotate(_ source: CGImage, settings: ToolSettings) throws -> CGImage {
        let canvas = try context(source.width, source.height)
        canvas.draw(source, in: CGRect(x: 0, y: 0, width: source.width, height: source.height))
        if settings.marks.isEmpty {
            try drawAnnotation(source, canvas: canvas, settings: settings)
        } else {
            for mark in settings.marks {
                try Task.checkCancellation()
                var local = settings
                local.annotation = mark.kind; local.x = mark.region.x; local.y = mark.region.y
                local.width = mark.region.width; local.height = mark.region.height
                local.text = mark.text; local.colorHex = mark.colorHex; local.fontSize = mark.fontSize
                local.lineWidth = mark.lineWidth; local.rotation = mark.rotation; local.points = mark.points
                local.backgroundImage = mark.imageURL
                guard local.fontSize.isFinite, (1...2048).contains(local.fontSize), local.lineWidth.isFinite,
                      (0.5...1024).contains(local.lineWidth), local.text.utf8.count <= 50_000, local.points.count <= 100_000 else {
                    throw ConversionError.invalidOptions("An annotation layer has invalid text, font, or stroke settings.")
                }
                try drawAnnotation(source, canvas: canvas, settings: local)
            }
        }
        return try image(canvas)
    }
    private static func drawAnnotation(_ source: CGImage, canvas: CGContext, settings: ToolSettings) throws {
        canvas.saveGState(); defer { canvas.restoreGState() }
        if settings.annotation == "freehand" || settings.annotation == "highlight" {
            guard settings.points.count >= 2, settings.points.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.x >= 0 && $0.y >= 0 && $0.x < Double(source.width) && $0.y < Double(source.height) }) else {
                throw ConversionError.invalidOptions("Draw a path with at least two points inside the image.")
            }
            canvas.setStrokeColor(try color(settings.colorHex)); canvas.setLineWidth(settings.lineWidth)
            canvas.setLineCap(.round); canvas.setLineJoin(.round)
            if settings.annotation == "highlight" { canvas.setAlpha(0.35); canvas.setBlendMode(.multiply) }
            for (index, point) in settings.points.enumerated() {
                let location = CGPoint(x: point.x, y: Double(source.height) - point.y)
                if index == 0 { canvas.move(to: location) } else { canvas.addLine(to: location) }
            }
            canvas.strokePath(); return
        }
        let top = try checkedRect(settings, image: source)
        let rect = bottomRect(top, height: source.height)
        canvas.setStrokeColor(try color(settings.colorHex)); canvas.setFillColor(try color(settings.colorHex))
        canvas.setLineWidth(settings.lineWidth); canvas.setLineJoin(.round); canvas.setLineCap(.round)
        if ["rectangle", "ellipse", "arrow", "magnifier"].contains(settings.annotation), settings.lineWidth > min(rect.width, rect.height) {
            throw ConversionError.invalidOptions("The stroke must fit inside the annotation rectangle.")
        }
        switch settings.annotation {
        case "text":
            guard !settings.text.isEmpty else { throw ConversionError.invalidOptions("Enter annotation text.") }
            let font = CTFontCreateWithName("Helvetica-Bold" as CFString, settings.fontSize, nil)
            let text = NSAttributedString(string: settings.text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): try color(settings.colorHex)])
            let setter = CTFramesetterCreateWithAttributedString(text)
            let path = CGPath(rect: rect, transform: nil)
            let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), path, nil)
            let visible = CTFrameGetVisibleStringRange(frame)
            guard visible.length >= text.length else { throw ConversionError.invalidOptions("The text does not fit. Enlarge its rectangle or reduce font size.") }
            CTFrameDraw(frame, canvas)
        case "rectangle": canvas.stroke(rect.insetBy(dx: settings.lineWidth / 2, dy: settings.lineWidth / 2))
        case "ellipse": canvas.strokeEllipse(in: rect.insetBy(dx: settings.lineWidth / 2, dy: settings.lineWidth / 2))
        case "marker", "number", "numberedMarker":
            guard !settings.text.isEmpty, settings.text.count <= 8 else { throw ConversionError.invalidOptions("A numbered marker needs a label of 1 to 8 characters.") }
            canvas.fillEllipse(in: rect)
            let font = CTFontCreateWithName("Helvetica-Bold" as CFString, min(settings.fontSize, rect.height * 0.65), nil)
            let components = try color(settings.colorHex).components ?? [0, 0, 0, 1]
            let luminance = components[0] * 0.2126 + components[1] * 0.7152 + components[2] * 0.0722
            let text = NSAttributedString(string: settings.text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: luminance > 0.55 ? 0 : 1, alpha: 1)])
            let line = CTLineCreateWithAttributedString(text)
            var ascent: CGFloat = 0, descent: CGFloat = 0
            let width = CTLineGetTypographicBounds(line, &ascent, &descent, nil)
            let scale = min(1, rect.width * 0.8 / max(1, width))
            canvas.translateBy(x: rect.midX, y: rect.midY)
            canvas.scaleBy(x: scale, y: scale)
            canvas.textPosition = CGPoint(x: -width / 2, y: -(ascent - descent) / 2)
            CTLineDraw(line, canvas)
        case "magnifier":
            guard let crop = source.cropping(to: top) else { throw ConversionError.conversionFailed("Cannot create a magnifier lens.") }
            canvas.addEllipse(in: rect); canvas.clip()
            canvas.draw(crop, in: rect.insetBy(dx: -rect.width / 2, dy: -rect.height / 2))
            canvas.resetClip(); canvas.strokeEllipse(in: rect.insetBy(dx: settings.lineWidth / 2, dy: settings.lineWidth / 2))
        case "overlay", "image", "imageOverlay":
            guard let url = settings.backgroundImage, url.isFileURL else { throw ConversionError.invalidOptions("Choose a local overlay image.") }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { throw ConversionError.invalidInput("Choose a regular overlay image, not a link.") }
            let overlay = try load(url)
            canvas.draw(overlay, in: fit(overlay, into: rect))
        case "arrow":
            let start: CGPoint, end: CGPoint
            switch settings.rotation {
            case 0: start = CGPoint(x: rect.minX, y: rect.maxY); end = CGPoint(x: rect.maxX, y: rect.minY)
            case 90: start = CGPoint(x: rect.maxX, y: rect.maxY); end = CGPoint(x: rect.minX, y: rect.minY)
            case 180: start = CGPoint(x: rect.maxX, y: rect.minY); end = CGPoint(x: rect.minX, y: rect.maxY)
            case 270: start = CGPoint(x: rect.minX, y: rect.minY); end = CGPoint(x: rect.maxX, y: rect.maxY)
            default: throw ConversionError.invalidOptions("Arrow direction must be 0, 90, 180, or 270 degrees.")
            }
            let angle = atan2(end.y - start.y, end.x - start.x)
            let head = min(max(12, settings.lineWidth * 4), min(rect.width, rect.height) * 0.65)
            canvas.move(to: start); canvas.addLine(to: end); canvas.strokePath()
            canvas.move(to: CGPoint(x: end.x - head * cos(angle - .pi/6), y: end.y - head * sin(angle - .pi/6)))
            canvas.addLine(to: end)
            canvas.addLine(to: CGPoint(x: end.x - head * cos(angle + .pi/6), y: end.y - head * sin(angle + .pi/6))); canvas.strokePath()
        default: throw ConversionError.invalidOptions("Unknown annotation kind.")
        }
    }
    private static func redact(_ source: CGImage, settings: ToolSettings) throws -> CGImage {
        var rectangles: [CGRect] = []
        for region in settings.regions {
            var local = settings
            local.x = region.x; local.y = region.y; local.width = region.width; local.height = region.height
            rectangles.append(try bottomRect(checkedRect(local, image: source), height: source.height))
        }
        if settings.detectFaces || settings.detectText {
            let handler = VNImageRequestHandler(cgImage: source)
            if settings.detectFaces {
                let request = VNDetectFaceRectanglesRequest()
                try handler.perform([request]); try Task.checkCancellation()
                rectangles += (request.results ?? []).map { observation in
                    let box = observation.boundingBox
                    return CGRect(x: box.minX * CGFloat(source.width), y: box.minY * CGFloat(source.height), width: box.width * CGFloat(source.width), height: box.height * CGFloat(source.height)).insetBy(dx: -8, dy: -8)
                }
            }
            if settings.detectText {
                let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate
                request.usesLanguageCorrection = false
                try handler.perform([request]); try Task.checkCancellation()
                rectangles += (request.results ?? []).map { observation in
                    let box = observation.boundingBox
                    return CGRect(x: box.minX * CGFloat(source.width), y: box.minY * CGFloat(source.height), width: box.width * CGFloat(source.width), height: box.height * CGFloat(source.height)).insetBy(dx: -4, dy: -4)
                }
            }
            guard !rectangles.isEmpty else { throw ConversionError.conversionFailed("No matching faces or text were detected. Check the preview and use a manual rectangle.") }
        } else if rectangles.isEmpty { rectangles = [try bottomRect(checkedRect(settings, image: source), height: source.height)] }
        let canvas = try context(source.width, source.height)
        let bounds = CGRect(x: 0, y: 0, width: source.width, height: source.height)
        canvas.draw(source, in: bounds)
        if settings.blur {
            // Blur is an aesthetic obscuring effect, not guaranteed secure redaction.
            let ci = CIImage(cgImage: source)
            let filtered = ci.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 24]).cropped(to: ci.extent)
            guard let blurred = CIContext(options: [.cacheIntermediates: false]).createCGImage(filtered, from: ci.extent) else { throw ConversionError.conversionFailed("Cannot blur the selected regions.") }
            for rect in rectangles {
                try Task.checkCancellation(); canvas.saveGState(); canvas.clip(to: rect.intersection(bounds)); canvas.draw(blurred, in: bounds); canvas.restoreGState()
            }
        } else {
            canvas.setFillColor(try color(settings.colorHex))
            for rect in rectangles { try Task.checkCancellation(); canvas.fill(rect.intersection(bounds).integral) }
        }
        return try image(canvas)
    }
    private static func collage(_ request: ToolRequest, destination: URL) throws {
        let settings = request.settings
        try dimensions(settings.width, settings.height)
        let columns = min(settings.columns, request.inputs.count)
        let rows = (request.inputs.count + columns - 1) / columns
        let totalWidth = columns * settings.width + (columns + 1) * settings.padding
        let totalHeight = rows * settings.height + (rows + 1) * settings.padding
        let canvas = try context(totalWidth, totalHeight)
        canvas.setFillColor(try color(settings.backgroundHex)); canvas.fill(CGRect(x: 0, y: 0, width: totalWidth, height: totalHeight))
        for (index, input) in request.inputs.enumerated() {
            try Task.checkCancellation()
            try autoreleasepool {
                let source = try load(input)
                let top = CGRect(x: settings.padding + (index % columns) * (settings.width + settings.padding),
                    y: settings.padding + (index / columns) * (settings.height + settings.padding), width: settings.width, height: settings.height)
                let rect = fit(source, into: bottomRect(top, height: totalHeight))
                canvas.saveGState()
                canvas.addPath(CGPath(roundedRect: rect, cornerWidth: CGFloat(settings.cornerRadius), cornerHeight: CGFloat(settings.cornerRadius), transform: nil)); canvas.clip()
                canvas.draw(source, in: rect); canvas.restoreGState()
            }
        }
        try write(image(canvas), destination)
    }
    private static func imagesPDF(_ inputs: [URL], destination: URL) throws {
        guard let pdf = CGContext(destination as CFURL, mediaBox: nil, nil) else { throw ConversionError.conversionFailed("Cannot create the PDF.") }
        defer { pdf.closePDF() }
        for input in inputs {
            try Task.checkCancellation()
            try autoreleasepool {
                let source = try load(input)
                var bounds = CGRect(x: 0, y: 0, width: source.width, height: source.height)
                let mediaBox = Data(bytes: &bounds, count: MemoryLayout<CGRect>.size)
                pdf.beginPDFPage([kCGPDFContextMediaBox as String: mediaBox] as CFDictionary)
                pdf.draw(source, in: bounds); pdf.endPDFPage()
            }
        }
    }
    private static func jpegData(_ image: CGImage, quality: Double) throws -> Data {
        let canvas = try context(image.width, image.height)
        canvas.setFillColor(CGColor(gray: 1, alpha: 1)); canvas.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        canvas.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { throw ConversionError.conversionFailed("Cannot create JPEG encoder.") }
        CGImageDestinationAddImage(destination, try self.image(canvas), [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ConversionError.conversionFailed("JPEG encoding failed.") }
        return data as Data
    }
    private static func compress(_ source: CGImage, destination: URL, settings: ToolSettings) throws {
        guard (1...16384).contains(settings.width), (1...16384).contains(settings.height) else {
            throw ConversionError.invalidOptions("Compression bounds must be between 1 and 16,384 pixels.")
        }
        var current = source
        let ratio = min(1, Double(settings.width) / Double(source.width), Double(settings.height) / Double(source.height))
        if ratio < 1 {
            let width = max(1, Int(floor(Double(source.width) * ratio)))
            let height = max(1, Int(floor(Double(source.height) * ratio)))
            let resized = try context(width, height)
            resized.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
            current = try image(resized)
        }
        for _ in 0..<12 {
            try Task.checkCancellation()
            let highest = try jpegData(current, quality: settings.quality)
            if settings.targetBytes == 0 || highest.count <= settings.targetBytes { try highest.write(to: destination); return }
            var low = 0.0, high = settings.quality
            var best: Data?
            let smallest = try jpegData(current, quality: low)
            if smallest.count <= settings.targetBytes {
                best = smallest
                for _ in 0..<9 {
                    try Task.checkCancellation()
                    let mid = (low + high) / 2
                    let encoded = try jpegData(current, quality: mid)
                    if encoded.count <= settings.targetBytes { low = mid; best = encoded } else { high = mid }
                }
                if let best { try best.write(to: destination); return }
            }
            let ratio = max(0.1, min(0.8, sqrt(Double(settings.targetBytes) / Double(smallest.count)) * 0.9))
            let width = max(1, Int(Double(current.width) * ratio)), height = max(1, Int(Double(current.height) * ratio))
            if width == current.width && height == current.height { break }
            let canvas = try context(width, height); canvas.draw(current, in: CGRect(x: 0, y: 0, width: width, height: height)); current = try image(canvas)
        }
        throw ConversionError.invalidOptions("The byte target is too small for a JPEG. Increase the target size.")
    }
    private static func metadata(_ image: CGImage, input: URL, destination: URL, settings: ToolSettings) throws {
        var properties: [CFString: Any] = [:]
        if !settings.removeMetadata, let source = CGImageSourceCreateWithURL(input as CFURL, nil), let original = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            properties = original
            properties[kCGImagePropertyOrientation] = 1
            properties[kCGImagePropertyPixelWidth] = image.width; properties[kCGImagePropertyPixelHeight] = image.height
            if var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                tiff[kCGImagePropertyTIFFOrientation] = 1
                properties[kCGImagePropertyTIFFDictionary] = tiff
            }
            if var exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
                exif[kCGImagePropertyExifPixelXDimension] = image.width
                exif[kCGImagePropertyExifPixelYDimension] = image.height
                properties[kCGImagePropertyExifDictionary] = exif
            }
        }
        if !settings.metadataTitle.isEmpty {
            var png = properties[kCGImagePropertyPNGDictionary] as? [CFString: Any] ?? [:]
            png[kCGImagePropertyPNGTitle] = settings.metadataTitle
            properties[kCGImagePropertyPNGDictionary] = png
            var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
            tiff[kCGImagePropertyTIFFImageDescription] = settings.metadataTitle
            properties[kCGImagePropertyTIFFDictionary] = tiff
        }
        guard let encoder = CGImageDestinationCreateWithURL(destination as CFURL, "public.png" as CFString, 1, nil) else { throw ConversionError.conversionFailed("Cannot create metadata output.") }
        CGImageDestinationAddImage(encoder, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(encoder) else { throw ConversionError.conversionFailed("Cannot save image metadata.") }
    }
    private static func inspectMetadata(_ input: URL, destination: URL) throws {
        if input.pathExtension.lowercased() == "svg" {
            let image = try load(input)
            let report: [String: Any] = ["file": input.lastPathComponent, "rasterWidth": image.width, "rasterHeight": image.height,
                "bytes": (try input.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0,
                "note": "Validated SVG file information and raster dimensions only. Embedded vector metadata is not inspected."]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: destination)
            return
        }
        guard let source = CGImageSourceCreateWithURL(input as CFURL, nil), let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) else { throw ConversionError.invalidInput("Cannot read image metadata.") }
        func json(_ value: Any) -> Any {
            if let dictionary = value as? [String: Any] { return dictionary.mapValues { json($0) } }
            if let array = value as? [Any] { return array.map { json($0) } }
            if value is String || value is NSNumber { return value }
            return String(describing: value)
        }
        let report: [String: Any] = ["file": input.lastPathComponent, "frameCount": CGImageSourceGetCount(source), "metadata": json(properties)]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]).write(to: destination)
    }
}
