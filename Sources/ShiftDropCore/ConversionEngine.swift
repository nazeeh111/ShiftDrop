import Foundation
import Darwin

public actor ConversionEngine {
    public init() {}

    public func convert(input: URL, to format: ConversionFormat, outputDirectory: URL, options: ConversionOptions = ConversionOptions()) async throws -> ConversionResult {
        try Task.checkCancellation()
        guard options.quality.isFinite, (0...1).contains(options.quality) else {
            throw ConversionError.invalidOptions("Quality must be between 0 and 1.")
        }
        if let size = options.maxPixelSize, !(1...16384).contains(size) {
            throw ConversionError.invalidOptions("Maximum image dimension must be between 1 and 16,384 pixels.")
        }
        let inputAccess = input.startAccessingSecurityScopedResource()
        let outputAccess = outputDirectory.startAccessingSecurityScopedResource()
        defer {
            if inputAccess { input.stopAccessingSecurityScopedResource() }
            if outputAccess { outputDirectory.stopAccessingSecurityScopedResource() }
        }
        let fm = FileManager.default
        let values: URLResourceValues
        do { values = try input.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]) }
        catch { throw ConversionError.invalidInput(error.localizedDescription) }
        guard values.isRegularFile == true || values.isDirectory == true else {
            throw ConversionError.invalidInput("Choose a regular file or folder.")
        }
        guard FormatCatalog.formats(for: input).contains(format) else {
            throw ConversionError.unsupported("\(FormatCatalog.kind(for: input)) to \(format.title) is not available.")
        }
        if values.isDirectory == true { try Self.validateArchiveInput(input, outputDirectory: outputDirectory) }
        try fm.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        guard (try outputDirectory.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true else {
            throw ConversionError.invalidInput("The destination must be a folder.")
        }
        // Stage beside the destination so publication can use an exclusive atomic rename.
        let staging = outputDirectory.appendingPathComponent(".shiftdrop-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: staging) }
        let inputBytes = try Self.byteCount(input)
        let temporary = staging.appendingPathComponent("converted.\(format.fileExtension)")
        let staged: [URL]
        if ArchiveConversions.outputFormats.contains(format) || format == .folder {
            try Self.validateArchiveInput(input, outputDirectory: outputDirectory)
            try ArchiveConversions.convert(input, destination: temporary, format: format, workspace: staging)
            staged = [temporary]
        } else {
            switch FormatCatalog.kind(for: input) {
            case "Image" where input.pathExtension.lowercased() == "svg":
                let raster = staging.appendingPathComponent("svg-render.png")
                try DocumentConversions.rasterizeSVG(input, destination: raster, options: options)
                if format == .pdf { try NativeImages.imageToPDF(raster, destination: temporary, options: options) }
                else if FormatCatalog.imageFormats.contains(format) { try NativeImages.convert(raster, destination: temporary, format: format, options: options) }
                else {
                    guard let executable = FormatCatalog.ffmpegURL else { throw ConversionError.toolMissing }
                    try await ProcessRunner.run(executable: executable, arguments: Self.ffmpegArguments(input: raster, destination: temporary, format: format, options: options))
                }
                staged = [temporary]
            case "Image" where format == .pdf:
                do { try NativeImages.imageToPDF(input, destination: temporary, options: options) }
                catch where ["avif", "webp"].contains(input.pathExtension.lowercased()) && FormatCatalog.ffmpegURL != nil {
                    let decoded = staging.appendingPathComponent("decoded.png")
                    try await ProcessRunner.run(executable: FormatCatalog.ffmpegURL!, arguments: Self.ffmpegArguments(input: input, destination: decoded, format: .png, options: options))
                    try NativeImages.imageToPDF(decoded, destination: temporary, options: options)
                }
                staged = [temporary]
            case "Image" where FormatCatalog.imageFormats.contains(format):
                do { try NativeImages.convert(input, destination: temporary, format: format, options: options) }
                catch where ["avif", "webp"].contains(input.pathExtension.lowercased()) && FormatCatalog.ffmpegURL != nil {
                    let decoded = staging.appendingPathComponent("decoded.png")
                    try await ProcessRunner.run(executable: FormatCatalog.ffmpegURL!, arguments: Self.ffmpegArguments(input: input, destination: decoded, format: .png, options: options))
                    try NativeImages.convert(decoded, destination: temporary, format: format, options: options)
                }
                staged = [temporary]
            case "Image" where [.webp, .avif].contains(format) || (format == .gif && input.pathExtension.lowercased() != "gif"):
                guard let executable = FormatCatalog.ffmpegURL else { throw ConversionError.toolMissing }
                let normalized = staging.appendingPathComponent("normalized.png")
                try NativeImages.convert(input, destination: normalized, format: .png, options: options)
                try await ProcessRunner.run(executable: executable, arguments: Self.ffmpegArguments(input: normalized, destination: temporary, format: format, options: options))
                staged = [temporary]
            case "PDF" where [.png, .jpeg, .tiff, .txt].contains(format):
                staged = try NativeImages.convertPDF(input, directory: staging, format: format, options: options)
            case "Subtitle":
                try TextConversions.convert(input, destination: temporary, format: format)
                staged = [temporary]
            case "Presentation" where [.png, .jpeg].contains(format):
                staged = try await DocumentConversions.renderOfficePages(input, directory: staging, format: format, options: options)
            case "PDF", "Text", "Document", "Spreadsheet", "Presentation", "Ebook":
                try await DocumentConversions.convert(input, destination: temporary, format: format, workspace: staging)
                staged = [temporary]
            default:
                guard let ffmpeg = FormatCatalog.ffmpegURL else { throw ConversionError.toolMissing }
                try await ProcessRunner.run(executable: ffmpeg, arguments: Self.ffmpegArguments(input: input, destination: temporary, format: format, options: options))
                staged = [temporary]
            }
        }
        try Task.checkCancellation()
        var published: [URL] = []
        do {
            let basename = format == .gzip ? input.lastPathComponent : input.deletingPathExtension().lastPathComponent
            for (index, file) in staged.enumerated() {
                try Task.checkCancellation()
                let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size > 0 || format == .folder || format == .rtfd else { throw ConversionError.conversionFailed("The converter produced an empty file.") }
                let page = staged.count > 1 ? "-page-\(index + 1)" : ""
                published.append(try Self.publish(file, directory: outputDirectory, basename: basename + page, extension: format.fileExtension))
            }
            try Task.checkCancellation()
            let outputBytes = try published.reduce(Int64(0)) { try $0 + Self.byteCount($1) }
            return ConversionResult(outputURLs: published, inputBytes: inputBytes, outputBytes: outputBytes)
        } catch {
            for url in published { try? fm.removeItem(at: url) }
            throw error
        }
    }

    static func publish(_ staged: URL, directory: URL, basename: String, extension ext: String) throws -> URL {
        // RENAME_EXCL never replaces an existing path, including a symlink or concurrent output.
        let safeBase = String((basename.isEmpty ? "Converted" : basename).prefix(160))
        for suffix in 0..<10000 {
            let name = safeBase + (suffix == 0 ? "" : " (\(suffix + 1))") + (ext.isEmpty ? "" : "." + ext)
            let destination = directory.appendingPathComponent(name)
            let status = staged.path.withCString { source in destination.path.withCString { target in Darwin.renamex_np(source, target, UInt32(RENAME_EXCL)) } }
            if status == 0 { return destination }
            let code = errno
            if code != EEXIST { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
        }
        throw ConversionError.conversionFailed("Too many files share this name in the destination.")
    }

    static func byteCount(_ url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .isSymbolicLinkKey])
        if values.isSymbolicLink == true { throw ConversionError.invalidInput("Symbolic links are not supported.") }
        if values.isDirectory != true { return Int64(values.fileSize ?? 0) }
        guard let entries = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]) else {
            throw ConversionError.invalidInput("The folder cannot be read.")
        }
        var total: Int64 = 0
        for case let file as URL in entries {
            try Task.checkCancellation()
            let resource = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey, .fileSizeKey])
            guard resource.isSymbolicLink != true else { throw ConversionError.unsafeArchive("The folder contains a symbolic link: \(file.lastPathComponent).") }
            guard resource.isRegularFile == true || resource.isDirectory == true else {
                throw ConversionError.unsafeArchive("The folder contains a special file: \(file.lastPathComponent).")
            }
            if resource.isRegularFile == true { total += Int64(resource.fileSize ?? 0) }
        }
        return total
    }

    static func validateArchiveInput(_ input: URL, outputDirectory: URL) throws {
        let attributes = try input.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard attributes.isSymbolicLink != true else { throw ConversionError.unsafeArchive("Symbolic links are not supported.") }
        if attributes.isDirectory == true {
            let source = input.resolvingSymlinksInPath().standardizedFileURL.path + "/"
            let output = outputDirectory.resolvingSymlinksInPath().standardizedFileURL.path + "/"
            guard !output.hasPrefix(source) else {
                throw ConversionError.unsafeArchive("Choose a destination outside the folder being archived.")
            }
        }
    }

    private static func ffmpegArguments(input: URL, destination: URL, format: ConversionFormat, options: ConversionOptions) -> [String] {
        var args = ["-hide_banner", "-loglevel", "error", "-nostdin", "-n", "-protocol_whitelist", "file,pipe", "-i", input.path, "-map_metadata", "-1"]
        switch format {
        case .mp4, .mov, .mkv, .webm, .avi, .wmv:
            let scale = options.maxPixelSize.map { "scale=w='min(iw,\($0))':h='min(ih,\($0))':force_original_aspect_ratio=decrease:force_divisible_by=2" } ?? "scale=trunc(iw/2)*2:trunc(ih/2)*2"
            args += ["-map", "0:v:0", "-map", "0:a:0?", "-pix_fmt", "yuv420p", "-vf", scale]
            switch format {
            case .webm: args += ["-c:v", "libvpx-vp9", "-crf", String(Int(20 + (1 - options.quality) * 20)), "-b:v", "0", "-c:a", "libopus"]
            case .avi: args += ["-c:v", "mpeg4", "-q:v", String(Int(2 + (1 - options.quality) * 10)), "-c:a", "libmp3lame"]
            case .wmv: args += ["-c:v", "wmv2", "-b:v", "3M", "-c:a", "wmav2"]
            default: args += ["-c:v", "libx264", "-crf", String(Int(18 + (1 - options.quality) * 16)), "-c:a", "aac"]
            }
            if format == .mp4 || format == .mov { args += ["-movflags", "+faststart"] }
        case .m4a: args += ["-vn", "-c:a", "aac", "-b:a", "192k"]
        case .mp3: args += ["-vn", "-c:a", "libmp3lame", "-q:a", "2"]
        case .wav: args += ["-vn", "-c:a", "pcm_s16le"]
        case .flac: args += ["-vn", "-c:a", "flac"]
        case .ogg: args += ["-vn", "-c:a", "libvorbis", "-q:a", "5"]
        case .opus: args += ["-vn", "-c:a", "libopus", "-b:a", "128k"]
        case .aiff: args += ["-vn", "-c:a", "pcm_s16be"]
        case .wma: args += ["-vn", "-c:a", "wmav2", "-b:a", "192k"]
        case .png:
            args += ["-frames:v", "1", "-c:v", "png"]
            if let max = options.maxPixelSize { args += ["-vf", "scale=w='min(iw,\(max))':h='min(ih,\(max))':force_original_aspect_ratio=decrease"] }
        case .webp: args += ["-frames:v", "1", "-c:v", "libwebp", "-quality", String(Int(options.quality * 100))]
        case .avif: args += ["-frames:v", "1", "-c:v", "libaom-av1", "-still-picture", "1", "-cpu-used", "6", "-crf", String(Int(15 + (1 - options.quality) * 35))]
        case .gif:
            if FormatCatalog.kind(for: input) == "Image" && input.pathExtension.lowercased() != "gif" {
                args += ["-frames:v", "1", "-c:v", "gif"]
                break
            }
            let size = min(options.maxPixelSize ?? 720, 1280)
            let filter = "fps=12,scale=w='min(iw,\(size))':h='min(ih,\(size))':force_original_aspect_ratio=decrease:flags=lanczos,split[a][b];[a]palettegen=stats_mode=single[p];[b][p]paletteuse=new=1:dither=sierra2_4a"
            args += ["-an", "-filter_complex", filter, "-loop", "0"]
        default: break
        }
        return args + [destination.path]
    }
}
