import Foundation
import Darwin
import CryptoKit

public enum FileTransfer {
    /// Move each explicit original without overwriting a destination. Completed moves remain moved if a later item fails.
    public static func move(_ sources: [URL], to directory: URL) throws -> [URL] {
        let fm = FileManager.default
        guard (try directory.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true else { throw ConversionError.invalidInput("The destination must be a folder.") }
        var results: [URL] = []
        do {
        for source in sources {
            let values = try source.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true, values.isDirectory == true || values.isRegularFile == true else { throw ConversionError.invalidInput("Choose regular files or folders, not symbolic links.") }
            let src = source.resolvingSymlinksInPath().standardizedFileURL
            let dest = directory.resolvingSymlinksInPath().standardizedFileURL
            if src.deletingLastPathComponent() == dest { results.append(source); continue }
            guard dest != src, !dest.path.hasPrefix(src.path + "/") else { throw ConversionError.invalidInput("A folder cannot be moved into itself.") }
            let ext = source.pathExtension
            let base = ext.isEmpty ? source.lastPathComponent : source.deletingPathExtension().lastPathComponent
            var moved: URL?
            for index in 0..<10000 {
                let name = base + (index == 0 ? "" : " (\(index + 1))") + (ext.isEmpty ? "" : "." + ext)
                let target = directory.appendingPathComponent(name)
                let status = source.path.withCString { from in target.path.withCString { to in renamex_np(from, to, UInt32(RENAME_EXCL)) } }
                if status == 0 { moved = target; break }
                if errno == EEXIST { continue }
                if errno == EXDEV {
                    let stage = directory.appendingPathComponent(".shiftdrop-move-\(UUID().uuidString)")
                    defer { try? fm.removeItem(at: stage) }
                    let before = try snapshot(source)
                    try fm.copyItem(at: source, to: stage)
                    let after = try snapshot(source)
                    let copiedSnapshot = try snapshot(stage)
                    guard before == after, before.map(\.content) == copiedSnapshot.map(\.content) else {
                        throw ConversionError.conversionFailed("The source changed while copying. The original was preserved. Retry after other apps finish writing to it.")
                    }
                    let copied = stage.path.withCString { from in target.path.withCString { to in renamex_np(from, to, UInt32(RENAME_EXCL)) } }
                    if copied != 0 { if errno == EEXIST { continue }; throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                    // Removal happens only after the complete copied item is published successfully.
                    do {
                        var coordinationError: NSError?
                        var removalError: Error?
                        NSFileCoordinator().coordinate(writingItemAt: source, options: .forDeleting, error: &coordinationError) { coordinated in
                            do {
                                guard try snapshot(coordinated) == after else { throw ConversionError.conversionFailed("The source changed before removal; both the complete copy and original were retained.") }
                                try fm.removeItem(at: coordinated)
                            } catch { removalError = error }
                        }
                        if let error = coordinationError ?? (removalError as NSError?) { throw error }
                    }
                    catch { throw ConversionError.conversionFailed("A complete copy exists at \(target.path), but the original could not be removed. \(error.localizedDescription)") }
                    moved = target; break
                }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            guard let moved else { throw ConversionError.conversionFailed("Too many files share this name.") }
            results.append(moved)
        }
        } catch {
            let completed = results.isEmpty ? "No prior items were moved." : "Completed destinations:\n" + results.map(\.path).joined(separator: "\n")
            throw ConversionError.conversionFailed(error.localizedDescription + "\n" + completed)
        }
        return results
    }
    private struct Snapshot: Equatable {
        let relative: String
        let size: Int
        let modified: Date?
        let identity: String
        let digest: String
        var content: String { relative + "|" + String(size) + "|" + digest }
    }
    private static func snapshot(_ suppliedRoot: URL) throws -> [Snapshot] {
        let root = suppliedRoot.resolvingSymlinksInPath().standardizedFileURL
        let fm = FileManager.default
        var urls = [root]
        if (try root.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true {
            var enumerationError: Error?
            guard let entries = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey], errorHandler: { _, error in enumerationError = error; return false }) else { throw ConversionError.invalidInput("The folder cannot be inspected before moving.") }
            for case let url as URL in entries { urls.append(url); if urls.count > 100_000 { throw ConversionError.invalidInput("Cross-volume moves are limited to 100,000 entries.") } }
            if let enumerationError { throw enumerationError }
        }
        return try urls.map { suppliedURL in
            let url = suppliedURL.resolvingSymlinksInPath().standardizedFileURL
            let value = try suppliedURL.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey, .fileResourceIdentifierKey])
            guard value.isSymbolicLink != true, value.isDirectory == true || value.isRegularFile == true else { throw ConversionError.invalidInput("Cross-volume moves support regular files and folders without symbolic links.") }
            var hash = SHA256()
            if value.isRegularFile == true {
                let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
                while let data = try file.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
            }
            return Snapshot(relative: String(url.path.dropFirst(root.path.count)).precomposedStringWithCanonicalMapping, size: value.isDirectory == true ? 0 : (value.fileSize ?? 0), modified: value.contentModificationDate, identity: String(describing: value.fileResourceIdentifier), digest: hash.finalize().map { String(format: "%02x", $0) }.joined())
        }.sorted { $0.relative < $1.relative }
    }
}
