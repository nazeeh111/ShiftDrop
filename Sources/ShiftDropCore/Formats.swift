import Foundation
import ImageIO

public enum ConversionFormat: String, CaseIterable, Identifiable, Codable, Sendable {
    case png, jpeg, tiff, heic, bmp, webp, avif, pdf, txt, rtf, rtfd, html, md, doc, docx, odt, epub
    case xlsx, xls, ods, csv, tsv, pptx, ppt, odp
    case srt, vtt, zip, tar, tgz, gzip, folder
    case mp4, mov, mkv, webm, avi, wmv, m4a, mp3, wav, flac, ogg, opus, aiff, wma, gif
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .jpeg: return "JPEG"
        case .md: return "Markdown"
        case .tgz: return "TAR.GZ"
        case .gzip: return "GZIP"
        case .folder: return "Extract files"
        default: return rawValue.uppercased()
        }
    }
    public var fileExtension: String {
        switch self {
        case .jpeg: return "jpg"
        case .tgz: return "tar.gz"
        case .gzip: return "gz"
        case .folder: return ""
        default: return rawValue
        }
    }
    public var category: String {
        switch self {
        case .png, .jpeg, .tiff, .heic, .bmp, .webp, .avif, .gif: return "Image"
        case .pdf, .txt, .rtf, .rtfd, .html, .md, .doc, .docx, .odt, .epub: return "Document"
        case .xlsx, .xls, .ods, .csv, .tsv: return "Spreadsheet"
        case .pptx, .ppt, .odp: return "Presentation"
        case .srt, .vtt: return "Subtitle"
        case .zip, .tar, .tgz, .gzip, .folder: return "Archive"
        case .mp4, .mov, .mkv, .webm, .avi, .wmv: return "Video"
        case .m4a, .mp3, .wav, .flac, .ogg, .opus, .aiff, .wma: return "Audio"
        }
    }
    public var symbol: String {
        switch category {
        case "Image": return "photo"
        case "Document": return "doc.text"
        case "Spreadsheet": return "tablecells"
        case "Presentation": return "rectangle.on.rectangle"
        case "Subtitle": return "captions.bubble"
        case "Archive": return "archivebox"
        case "Video": return "film"
        default: return "waveform"
        }
    }
}

public struct ConversionOptions: Sendable {
    public var quality: Double
    public var maxPixelSize: Int?
    public init(quality: Double = 0.85, maxPixelSize: Int? = nil) {
        self.quality = quality
        self.maxPixelSize = maxPixelSize
    }
}

public struct ConversionResult: Sendable {
    public let outputURLs: [URL]
    public let inputBytes: Int64
    public let outputBytes: Int64
}

public enum ConversionError: LocalizedError, Sendable {
    case invalidInput(String)
    case unsupported(String)
    case invalidOptions(String)
    case conversionFailed(String)
    case unsafeArchive(String)
    case toolMissing

    public var errorDescription: String? {
        switch self {
        case .invalidInput(let detail): return "Cannot read this file. \(detail)"
        case .unsupported(let detail): return "Unsupported conversion. \(detail)"
        case .invalidOptions(let detail): return "Invalid settings. \(detail)"
        case .conversionFailed(let detail): return "Conversion failed. \(detail)"
        case .unsafeArchive(let detail): return "Cannot safely archive this item. \(detail)"
        case .toolMissing: return "This conversion needs FFmpeg. Install a free FFmpeg executable and reopen ShiftDrop."
        }
    }
}

public enum FormatCatalog {
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "tif", "tiff", "heic", "heif", "bmp", "gif", "webp", "avif", "jp2", "j2k", "ico", "icns", "svg"]
    static let textExtensions: Set<String> = ["txt", "md", "markdown", "rtf", "html", "htm"]
    static let videoExtensions: Set<String> = ["mp4", "mov", "mkv", "webm", "avi", "wmv", "m4v", "mpeg", "mpg", "ts", "mts", "m2ts", "flv", "3gp"]
    static let audioExtensions: Set<String> = ["m4a", "mp3", "wav", "flac", "aiff", "aif", "aac", "ogg", "opus", "wma"]
    static let imageFormats: [ConversionFormat] = [.png, .jpeg, .tiff, .heic, .bmp]
    static let audioFormats: [ConversionFormat] = [.m4a, .mp3, .wav, .flac, .ogg, .opus, .aiff, .wma]
    static let videoFormats: [ConversionFormat] = [.mp4, .mov, .mkv, .webm, .avi, .wmv]
    static let documentExtensions: Set<String> = ["doc", "docx", "odt", "wordml", "rtfd", "textclipping"]
    static let spreadsheetExtensions: Set<String> = ["xlsx", "xls", "ods", "csv", "tsv"]
    static let presentationExtensions: Set<String> = ["pptx", "ppt", "odp"]

    /// FFmpeg is optional. Native image, document, subtitle and ZIP routes never depend on it.
    public static var ffmpegURL: URL? {
        let fm = FileManager.default
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for directory in paths + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", NSHomeDirectory() + "/.local/bin"] {
            let url = URL(fileURLWithPath: directory).appendingPathComponent("ffmpeg")
            if fm.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }

    public static func kind(for input: URL) -> String {
        if input.pathExtension.lowercased() == "rtfd" { return "Document" }
        if (try? input.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { return "Folder" }
        let ext = input.pathExtension.lowercased()
        if imageExtensions.contains(ext) { return "Image" }
        if ext == "pdf" { return "PDF" }
        if ext == "epub" { return "Ebook" }
        if documentExtensions.contains(ext) { return "Document" }
        if spreadsheetExtensions.contains(ext) { return "Spreadsheet" }
        if presentationExtensions.contains(ext) { return "Presentation" }
        if ArchiveConversions.extensions.contains(ext) { return "Archive" }
        if textExtensions.contains(ext) { return "Text" }
        if ext == "srt" || ext == "vtt" { return "Subtitle" }
        if videoExtensions.contains(ext) { return "Video" }
        if audioExtensions.contains(ext) { return "Audio" }
        return "File"
    }

    public static func formats(for input: URL) -> [ConversionFormat] {
        let ext = input.pathExtension.lowercased()
        var formats: [ConversionFormat] = []
        switch kind(for: input) {
        case "Image":
            let writable = Set(CGImageDestinationCopyTypeIdentifiers() as! [String])
            formats = imageFormats.filter { writable.contains($0.imageType) } + [.pdf]
            if ffmpegURL != nil { formats += [.webp, .avif, .gif] }
            if ffmpegURL != nil && ext == "gif" { formats += [.mp4, .mov, .gif] }
        case "PDF": formats = [.png, .jpeg, .tiff, .txt, .docx, .rtf, .html, .md, .epub, .pptx, .xlsx]
        case "Text", "Document", "Ebook":
            formats = [.txt, .rtf, .html, .md, .pdf, .epub]
            if DocumentConversions.textutilAvailable { formats += [.docx, .doc, .odt, .rtfd] }
            if kind(for: input) == "Document" && !DocumentConversions.textutilAvailable && DocumentConversions.officeURL == nil { formats = [] }
        case "Spreadsheet":
            if DocumentConversions.officeURL != nil { formats = [.pdf, .xlsx, .xls, .ods, .csv, .tsv] }
        case "Presentation":
            if DocumentConversions.officeURL != nil { formats = [.pdf, .pptx, .ppt, .odp, .png, .jpeg] }
        case "Subtitle": formats = [.srt, .vtt, .txt]
        case "Video": if ffmpegURL != nil { formats = videoFormats + audioFormats + [.gif] }
        case "Audio": if ffmpegURL != nil { formats = audioFormats }
        case "Archive": if ArchiveConversions.isAvailable { formats = [.folder, .zip, .tar, .tgz] }
        default: break
        }
        if ArchiveConversions.isAvailable && kind(for: input) != "Archive" {
            formats += [.zip, .tar, .tgz]
            if (try? input.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true { formats.append(.gzip) }
        }
        var seen = Set<ConversionFormat>()
        return formats.filter { seen.insert($0).inserted }
    }

    /// Input-specific fidelity limits for the UI and generated route documentation.
    public static func note(for input: URL, to format: ConversionFormat) -> String? {
        let kind = kind(for: input)
        if kind == "PDF" && format == .pptx { return "Each PDF page becomes a slide image. Text and individual page elements are not editable in the presentation." }
        if kind == "PDF" && format == .xlsx { return "Places each line of selectable PDF text into a spreadsheet row. Tables, formulas, scanned text, and original layout are not reconstructed." }
        if kind == "PDF" && [.docx, .rtf, .html, .md, .epub].contains(format) { return "Extracts selectable text into a new document. PDF layout, images, and scanned text are not reconstructed." }
        if [.csv, .tsv].contains(format), kind == "Spreadsheet" { return "Exports the first sheet's values. Multiple sheets, formulas, and formatting do not fit in delimited text." }
        if format == .md || format == .epub || kind == "Ebook" { return "Reflows document text. Embedded images and original page layout are not preserved." }
        if input.pathExtension.lowercased() == "svg" { return "Rasterizes the vector artwork at a bounded size. External resources, scripts, and SVG foreign objects are rejected." }
        if input.pathExtension.lowercased() == "textclipping" { return "Reads the text carried by a Finder clipping. Original drag-source metadata is not exported." }
        if input.pathExtension.lowercased() == "rtfd" && format == .pdf { return "Reflows the text and supported rich-text styling. Attached images are not placed in the native text PDF." }
        if input.pathExtension.lowercased() == "gif" && (imageFormats + [.webp, .avif]).contains(format) { return "Exports the first animation frame as a still image." }
        if kind == "Document" && format == .pdf && DocumentConversions.officeURL == nil { return "Reflows the document's text and supported rich-text styling into PDF pages. Original Office pagination is not preserved." }
        if [.webp, .avif, .m4a, .mp3, .ogg, .opus, .wma, .mp4, .mov, .webm, .avi, .wmv].contains(format) { return "Uses the installed FFmpeg build. Lossy encoding can change quality; unavailable codecs produce a clear error." }
        return nil
    }
}

extension ConversionFormat {
    var imageType: String {
        switch self {
        case .png: return "public.png"
        case .jpeg: return "public.jpeg"
        case .tiff: return "public.tiff"
        case .heic: return "public.heic"
        case .bmp: return "com.microsoft.bmp"
        default: return ""
        }
    }
}
