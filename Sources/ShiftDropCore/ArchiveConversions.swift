import Foundation
import Darwin

/// Uses the libarchive library supplied by macOS. Entries are streamed into a private
/// staging directory; libarchive's automatic disk extractor is deliberately not used.
enum ArchiveConversions {
    struct Limits {
        var entries = 10_000
        var totalBytes: Int64 = 512 * 1024 * 1024
        var fileBytes: Int64 = 128 * 1024 * 1024
        var expansionRatio: Int64 = 2000
    }
    static var isAvailable: Bool { LibArchive.shared != nil }
    static let outputFormats: [ConversionFormat] = [.zip, .tar, .tgz, .gzip]
    static let extensions: Set<String> = ["zip", "tar", "gz", "tgz", "bz2", "tbz", "tbz2", "xz", "txz", "7z", "rar", "cpio", "xar"]

    static func convert(_ input: URL, destination: URL, format: ConversionFormat, workspace: URL, limits: Limits = Limits()) throws {
        if FormatCatalog.kind(for: input) == "Archive" {
            let extracted = workspace.appendingPathComponent("unpacked", isDirectory: true)
            try extract(input, destination: extracted, limits: limits)
            if format == .folder {
                try FileManager.default.moveItem(at: extracted, to: destination)
            } else {
                let contents = try FileManager.default.contentsOfDirectory(at: extracted, includingPropertiesForKeys: nil).sorted { $0.lastPathComponent < $1.lastPathComponent }
                try create(contents, destination: destination, format: format, limits: limits)
            }
        } else { try create([input], destination: destination, format: format, limits: limits) }
    }

    static func extract(_ input: URL, destination: URL, limits: Limits = Limits()) throws {
        guard let api = LibArchive.shared, let archive = api.readNew() else { throw ConversionError.unsupported("The macOS archive library is unavailable.") }
        defer { _ = api.readFree(archive) }
        for enable in api.readFilters + api.readFormats { try api.check(enable(archive), archive) }
        // A single compressed file is represented by a raw entry after its compression filter.
        let compressedExtension = input.pathExtension.lowercased()
        if ["gz", "bz2", "xz"].contains(compressedExtension) {
            let file = try FileHandle(forReadingFrom: input)
            defer { try? file.close() }
            let prefix = Array(try file.read(upToCount: 6) ?? Data())
            let valid = compressedExtension == "gz" ? prefix.starts(with: [0x1F, 0x8B]) : compressedExtension == "bz2" ? prefix.starts(with: [0x42, 0x5A, 0x68]) : prefix == [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]
            guard valid else { throw ConversionError.invalidInput("The compressed file has an invalid header.") }
            try api.check(api.readRaw(archive), archive)
        }
        try input.path.withCString { try api.check(api.readOpen(archive, $0, 64 * 1024), archive) }
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: false)
        var successful = false
        defer { if !successful { try? fm.removeItem(at: destination) } }
        let compressedSize = Int64((try input.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0)
        let ratioLimit = compressedSize > Int64.max / max(1, limits.expansionRatio) ? Int64.max : compressedSize * max(1, limits.expansionRatio)
        let expandedLimit = min(limits.totalBytes, max(8 * 1024 * 1024, ratioLimit))
        var total: Int64 = 0
        var count = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            try Task.checkCancellation()
            var entry: OpaquePointer?
            let status = api.readNext(archive, &entry)
            if status == 1 { break }
            try api.check(status, archive)
            guard let entry, let namePointer = api.entryPath(entry), let name = String(validatingCString: namePointer) else {
                throw ConversionError.unsafeArchive("An entry has an invalid filename.")
            }
            count += 1
            guard count <= limits.entries else { throw ConversionError.unsafeArchive("The archive exceeds the \(limits.entries)-entry limit.") }
            guard api.entrySymlink(entry) == nil, api.entryHardlink(entry) == nil else { throw ConversionError.unsafeArchive("Links inside archives are not supported.") }
            let type = api.entryType(entry)
            guard type == 0o100000 || type == 0o040000 else { throw ConversionError.unsafeArchive("Special files inside archives are not supported.") }
            var relative = try safePath(name)
            if relative == "data" && count == 1 && api.readFormat(archive) & 0xFF0000 == 0x090000 {
                relative = try safePath(input.deletingPathExtension().lastPathComponent)
            }
            guard !relative.isEmpty else {
                if type == 0o040000 { continue }
                throw ConversionError.unsafeArchive("An archive entry has an empty filename.")
            }
            let url = destination.appendingPathComponent(relative, isDirectory: type == 0o040000)
            if type == 0o040000 {
                guard api.entrySize(entry) == 0 else { throw ConversionError.unsafeArchive("An archive directory has unexpected file content.") }
                if fm.fileExists(atPath: url.path) {
                    guard (try url.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true else { throw ConversionError.unsafeArchive("An entry conflicts with a file.") }
                } else { try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
                continue
            }
            let declared = api.entrySize(entry)
            guard declared >= 0, declared <= limits.fileBytes, declared <= expandedLimit - total else { throw ConversionError.unsafeArchive("The archive exceeds the safe expanded-size limit.") }
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let descriptor = url.path.withCString { Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600) }
            guard descriptor >= 0 else { throw ConversionError.unsafeArchive("Duplicate or unsafe archive entry: \(relative).") }
            let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? file.close() }
            var fileSize: Int64 = 0
            while true {
                try Task.checkCancellation()
                let read = api.readData(archive, &buffer, buffer.count)
                guard read >= 0 else { throw api.failure(archive) }
                if read == 0 { break }
                fileSize += Int64(read)
                total += Int64(read)
                guard fileSize <= limits.fileBytes, total <= expandedLimit else { throw ConversionError.unsafeArchive("The archive exceeds the safe expanded-size limit.") }
                try file.write(contentsOf: Data(buffer.prefix(read)))
            }
            try file.close()
        }
        successful = true
    }

    static func create(_ inputs: [URL], destination: URL, format: ConversionFormat, limits: Limits = Limits(), store: Bool = false) throws {
        guard let api = LibArchive.shared, let archive = api.writeNew() else { throw ConversionError.unsupported("The macOS archive library is unavailable.") }
        defer { _ = api.writeFree(archive) }
        switch format {
        case .zip: try api.check(api.writeZIP(archive), archive)
        case .tar, .tgz: try api.check(api.writeTAR(archive), archive)
        case .gzip:
            guard inputs.count == 1, (try inputs[0].resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else {
                throw ConversionError.unsupported("GZIP holds one file. Use TAR.GZ for a folder or multiple files.")
            }
            try api.check(api.writeRaw(archive), archive)
        default: throw ConversionError.unsupported("Unsupported archive output.")
        }
        if format == .tgz || format == .gzip { try api.check(api.writeGZIP(archive), archive) }
        if store && format == .zip { try api.check(api.writeZIPStore(archive), archive) }
        try destination.path.withCString { try api.check(api.writeOpen(archive, $0), archive) }
        var count = 0
        var total: Int64 = 0
        var names = Set<String>()
        func append(_ url: URL, name: String) throws {
            try Task.checkCancellation()
            let relative = try safePath(name)
            guard names.insert(relative.precomposedStringWithCanonicalMapping.lowercased()).inserted else { throw ConversionError.unsafeArchive("Duplicate archive filename: \(relative).") }
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey, .fileSizeKey])
            guard values.isSymbolicLink != true else { throw ConversionError.unsafeArchive("Symbolic links are not supported.") }
            guard values.isRegularFile == true || values.isDirectory == true else { throw ConversionError.unsafeArchive("Special files are not supported.") }
            count += 1
            guard count <= limits.entries else { throw ConversionError.unsafeArchive("The archive exceeds the \(limits.entries)-entry limit.") }
            guard let entry = api.entryNew() else { throw ConversionError.conversionFailed("Cannot allocate an archive entry.") }
            defer { api.entryFree(entry) }
            relative.withCString { api.entrySetPath(entry, $0) }
            api.entrySetType(entry, values.isDirectory == true ? 0o040000 : 0o100000)
            api.entrySetPerm(entry, values.isDirectory == true ? 0o755 : 0o644)
            if values.isDirectory == true {
                api.entrySetSize(entry, 0)
                try api.check(api.writeHeader(archive, entry), archive)
            } else {
                let descriptor = url.path.withCString { Darwin.open($0, O_RDONLY | O_NOFOLLOW) }
                guard descriptor >= 0 else { throw ConversionError.invalidInput("Cannot open \(url.lastPathComponent).") }
                let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                defer { try? file.close() }
                var stat = Darwin.stat()
                guard fstat(descriptor, &stat) == 0, stat.st_mode & S_IFMT == S_IFREG else { throw ConversionError.unsafeArchive("The source changed while preparing its archive.") }
                let size = stat.st_size
                guard size >= 0, size <= limits.fileBytes, size <= limits.totalBytes - total else { throw ConversionError.unsafeArchive("The source exceeds the safe archive-size limit.") }
                total += size
                api.entrySetSize(entry, size)
                try api.check(api.writeHeader(archive, entry), archive)
                var written: Int64 = 0
                while let data = try file.read(upToCount: 64 * 1024), !data.isEmpty {
                    try Task.checkCancellation()
                    written += Int64(data.count)
                    guard written <= size else { throw ConversionError.invalidInput("The source changed during archiving.") }
                    try data.withUnsafeBytes { bytes in
                        var offset = 0
                        while offset < bytes.count {
                            let result = api.writeData(archive, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                            guard result > 0 else { throw api.failure(archive) }
                            offset += result
                        }
                    }
                }
                guard written == size else { throw ConversionError.invalidInput("The source changed during archiving.") }
            }
            try api.check(api.writeFinish(archive), archive)
        }
        for input in inputs {
            try append(input, name: input.lastPathComponent)
            if (try input.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true {
                let canonical = input.resolvingSymlinksInPath().standardizedFileURL
                let parent = canonical.deletingLastPathComponent().path
                let parentPath = parent.hasSuffix("/") ? parent : parent + "/"
                var enumerationError: Error?
                guard let enumerator = FileManager.default.enumerator(at: canonical, includingPropertiesForKeys: [.isSymbolicLinkKey], errorHandler: { _, error in enumerationError = error; return false }) else { throw ConversionError.invalidInput("Cannot read this folder.") }
                for case let item as URL in enumerator {
                    // FileManager may return /private/var while URL canonicalization returns /var.
                    // Normalize parent components but preserve the final component for link rejection.
                    let path = item.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(item.lastPathComponent).path
                    guard path.hasPrefix(parentPath) else { throw ConversionError.unsafeArchive("Invalid source path.") }
                    try append(item, name: String(path.dropFirst(parentPath.count)))
                }
                if let enumerationError { throw enumerationError }
            }
        }
        try api.check(api.writeClose(archive), archive)
    }

    static func safePath(_ source: String) throws -> String {
        guard !source.hasPrefix("/"), !source.contains("\\"), !source.contains(":"), !source.contains("\0"), source.utf8.count <= 4096 else { throw ConversionError.unsafeArchive("An entry uses an absolute or invalid path.") }
        let parts = source.split(separator: "/", omittingEmptySubsequences: true)
        guard !parts.contains(".."), parts.allSatisfy({ $0.utf8.count <= 255 }) else { throw ConversionError.unsafeArchive("An entry attempts to leave the extraction folder.") }
        return parts.filter { $0 != "." }.joined(separator: "/")
    }
}

/// C ABI bindings are loaded from the system library, avoiding a bundled archive engine.
private final class LibArchive: @unchecked Sendable {
    typealias New = @convention(c) () -> OpaquePointer?
    typealias Status = @convention(c) (OpaquePointer?) -> Int32
    typealias Open = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, Int) -> Int32
    typealias WriteOpen = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?) -> Int32
    typealias Next = @convention(c) (OpaquePointer?, UnsafeMutablePointer<OpaquePointer?>?) -> Int32
    typealias Read = @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?, Int) -> Int
    typealias Write = @convention(c) (OpaquePointer?, UnsafeRawPointer?, Int) -> Int
    typealias Path = @convention(c) (OpaquePointer?) -> UnsafePointer<CChar>?
    typealias Size = @convention(c) (OpaquePointer?) -> Int64
    typealias EntryType = @convention(c) (OpaquePointer?) -> UInt32
    typealias FreeEntry = @convention(c) (OpaquePointer?) -> Void
    typealias SetPath = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?) -> Void
    typealias SetSize = @convention(c) (OpaquePointer?, Int64) -> Void
    typealias SetEntryType = @convention(c) (OpaquePointer?, UInt32) -> Void
    typealias Header = @convention(c) (OpaquePointer?, OpaquePointer?) -> Int32
    static let shared = try? LibArchive()
    let handle: UnsafeMutableRawPointer
    let readNew: New, writeNew: New, entryNew: New
    let readFilters: [Status], readFormats: [Status], readRaw: Status, readFree: Status, readFormat: Status
    let writeZIP: Status, writeZIPStore: Status, writeTAR: Status, writeRaw: Status, writeGZIP: Status, writeFree: Status, writeClose: Status, writeFinish: Status
    let readOpen: Open, writeOpen: WriteOpen, readNext: Next, readData: Read, writeData: Write
    let entryPath: Path, entrySymlink: Path, entryHardlink: Path, errorString: Path
    let entrySize: Size, entryType: EntryType, entryFree: FreeEntry, entrySetPath: SetPath, entrySetSize: SetSize, entrySetType: SetEntryType, entrySetPerm: SetEntryType, writeHeader: Header
    init() throws {
        guard let handle = dlopen("/usr/lib/libarchive.2.dylib", RTLD_NOW | RTLD_LOCAL) else { throw ConversionError.unsupported("The system archive library cannot be loaded.") }
        self.handle = handle
        func bind<T>(_ name: String, _: T.Type) throws -> T {
            guard let symbol = dlsym(handle, name) else { throw ConversionError.unsupported("A system archive API is unavailable: \(name).") }
            return unsafeBitCast(symbol, to: T.self)
        }
        readNew = try bind("archive_read_new", New.self); writeNew = try bind("archive_write_new", New.self); entryNew = try bind("archive_entry_new", New.self)
        // Exclude mtree, which can reference local files, and filters that launch external programs.
        readFilters = try ["none", "gzip", "bzip2", "xz", "lzma"].map { try bind("archive_read_support_filter_" + $0, Status.self) }
        readFormats = try ["zip", "tar", "7zip", "rar", "rar5", "cpio", "xar"].map { try bind("archive_read_support_format_" + $0, Status.self) }
        readRaw = try bind("archive_read_support_format_raw", Status.self); readFree = try bind("archive_read_free", Status.self); readFormat = try bind("archive_format", Status.self)
        writeZIP = try bind("archive_write_set_format_zip", Status.self); writeZIPStore = try bind("archive_write_zip_set_compression_store", Status.self); writeTAR = try bind("archive_write_set_format_pax_restricted", Status.self); writeRaw = try bind("archive_write_set_format_raw", Status.self); writeGZIP = try bind("archive_write_add_filter_gzip", Status.self); writeFree = try bind("archive_write_free", Status.self); writeClose = try bind("archive_write_close", Status.self); writeFinish = try bind("archive_write_finish_entry", Status.self)
        readOpen = try bind("archive_read_open_filename", Open.self); writeOpen = try bind("archive_write_open_filename", WriteOpen.self); readNext = try bind("archive_read_next_header", Next.self); readData = try bind("archive_read_data", Read.self); writeData = try bind("archive_write_data", Write.self)
        entryPath = try bind("archive_entry_pathname_utf8", Path.self); entrySymlink = try bind("archive_entry_symlink", Path.self); entryHardlink = try bind("archive_entry_hardlink", Path.self); errorString = try bind("archive_error_string", Path.self)
        entrySize = try bind("archive_entry_size", Size.self); entryType = try bind("archive_entry_filetype", EntryType.self); entryFree = try bind("archive_entry_free", FreeEntry.self); entrySetPath = try bind("archive_entry_set_pathname", SetPath.self); entrySetSize = try bind("archive_entry_set_size", SetSize.self); entrySetType = try bind("archive_entry_set_filetype", SetEntryType.self); entrySetPerm = try bind("archive_entry_set_perm", SetEntryType.self); writeHeader = try bind("archive_write_header", Header.self)
    }
    func check(_ status: Int32, _ archive: OpaquePointer) throws {
        guard status >= 0 else { throw failure(archive) }
    }
    func failure(_ archive: OpaquePointer) -> ConversionError {
        .conversionFailed(errorString(archive).map { String(cString: $0) } ?? "The archive is damaged or uses an unsupported encoding.")
    }
}
