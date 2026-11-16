import Foundation
import CryptoKit
import Darwin

/// Tracks operation-owned outputs; changed or unverifiable paths are retained for inspection.
struct PublishedOutput {
    let url: URL
    let device: dev_t
    let inode: ino_t
    let sha256: String?
}

enum OutputTransaction {
    private static let rollbackHashLimit: Int64 = 256 * 1024 * 1024
    static func identity(_ url: URL) throws -> (dev_t, ino_t, String?) {
        var info=stat()
        guard lstat(url.path,&info)==0, (info.st_mode & S_IFMT) != S_IFLNK else {
            throw ConversionError.invalidInput("Output staging identity is unavailable or is a symbolic link.")
        }
        // Directories and very large outputs are left intact on failure rather
        // than recursively deleting contents whose identity cannot be checked.
        guard (info.st_mode & S_IFMT)==S_IFREG, info.st_size>=0, info.st_size<=rollbackHashLimit else { return (info.st_dev,info.st_ino,nil) }
        let fd=Darwin.open(url.path,O_RDONLY | O_NONBLOCK | O_NOFOLLOW)
        guard fd>=0 else { throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO) }
        defer { Darwin.close(fd) }
        var actual=stat()
        guard fstat(fd,&actual)==0, (actual.st_mode & S_IFMT)==S_IFREG, actual.st_dev==info.st_dev, actual.st_ino==info.st_ino else {
            throw ConversionError.invalidInput("Output staging changed while capturing its identity.")
        }
        var hasher=SHA256(), total:Int64=0, buffer=[UInt8](repeating:0,count:65536)
        while true {
            let n=Darwin.read(fd,&buffer,buffer.count)
            if n<0 { throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO) }
            if n==0 { break }
            total += Int64(n)
            guard total<=rollbackHashLimit else { return (info.st_dev,info.st_ino,nil) }
            hasher.update(data:Data(buffer.prefix(n)))
        }
        return (info.st_dev,info.st_ino,hasher.finalize().map { String(format:"%02x",$0) }.joined())
    }
    static func publish(_ staged: URL, directory: URL, basename: String, extension ext: String) throws -> PublishedOutput {
        let (device,inode,sha)=try identity(staged)
        let output=try ConversionEngine.publish(staged,directory:directory,basename:basename,extension:ext)
        return PublishedOutput(url:output,device:device,inode:inode,sha256:sha)
    }
    /// Publish a durable stage without replacing a preexisting destination.
    static func publishPrepared(_ staged: URL, to destination: URL) throws {
        guard Darwin.link(staged.path,destination.path)==0 else { throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO) }
    }
    static func abort(_ error: Error, _ outputs: [PublishedOutput], remove: (URL) throws -> Void = { try FileManager.default.removeItem(at:$0) }) -> Error {
        var retained:[String]=[]
        for output in outputs {
            var info=stat()
            if lstat(output.url.path,&info) != 0 {
                if errno != ENOENT { retained.append("\(output.url.path) (identity unavailable: \(errno))") }
                continue
            }
            guard let expected=output.sha256, (info.st_mode & S_IFMT)==S_IFREG,
                  info.st_dev==output.device, info.st_ino==output.inode else {
                retained.append("\(output.url.path) (identity changed or cannot be checked)");continue
            }
            do {
                let checked=try identity(output.url)
                guard checked.0==output.device, checked.1==output.inode, checked.2==expected else {
                    retained.append("\(output.url.path) (content or identity changed)");continue
                }
            } catch {
                retained.append("\(output.url.path) (identity read failed: \(error.localizedDescription))");continue
            }
            do { try remove(output.url) }
            catch { retained.append("\(output.url.path) (cleanup failed: \(error.localizedDescription))") }
        }
        guard !retained.isEmpty else { return error }
        return ConversionError.conversionFailed("\(error.localizedDescription) Some output paths could not be safely cleaned; inspect: \(retained.joined(separator: ", "))")
    }
}
