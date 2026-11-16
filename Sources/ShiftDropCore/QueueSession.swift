import Foundation
import CryptoKit
import Darwin

private struct QueuePersistenceError: LocalizedError {
    let detail: String
    var errorDescription: String? { detail }
}

/// One explicitly owned, resumable batch. The manifest contains paths, not access authority.
@MainActor public final class QueueSession {
    public enum State: String, Codable { case ready, running, prepared, complete, failed, interrupted }
    public struct Job: Codable, Identifiable {
        public let id: UUID
        public let input: URL
        public var format: ConversionFormat
        public var state: State
        public var message: String?
        public let inputSHA256: String
        public var inputBytes: Int
        public var recoverable: Bool
        public var oneShotOutputs: [URL]?
        public var quality: Double?
        public var maxPixelSize: Int?
        public var destination: URL?
        public var stageID: UUID?
        public var stagedName: String?
        public var outputName: String?
        public var outputSHA256: String?
        public var outputBytes: Int?
        public var cleanupWarning: String?
    }
    private struct Document: Codable { var schema: Int; var jobs: [Job] }
    public private(set) var jobs: [Job]
    public let directory: URL
    private let lockFD: Int32
    private let maxBytes = 32 * 1024 * 1024
    private let fm = FileManager.default
    // Internal test seam; production leaves this unset.
    var beforeManifestWrite: (() throws -> Void)?
    var beforeOwnedCleanup: ((URL) throws -> Void)?
    var afterStageConversion: (() throws -> Void)?

    public init(directory: URL) throws {
        self.directory = directory.standardizedFileURL
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        let lock = self.directory.appendingPathComponent("owner.lock").path
        let fd = Darwin.open(lock, O_CREAT | O_RDWR | O_NOFOLLOW | O_NONBLOCK, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var lockInfo=stat()
        guard fstat(fd,&lockInfo)==0, (lockInfo.st_mode & S_IFMT)==S_IFREG else { Darwin.close(fd); throw ConversionError.invalidInput("Batch lock must be a regular file.") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { Darwin.close(fd); throw ConversionError.invalidInput("This batch is already open in another process.") }
        lockFD = fd
        var initialized = false
        defer { if !initialized { flock(fd, LOCK_UN); Darwin.close(fd) } }
        let manifest = self.directory.appendingPathComponent("manifest.json")
        if FileManager.default.fileExists(atPath: manifest.path) {
            let data = try Self.readRegular(manifest, maximum: 1_000_000)
            let document = try JSONDecoder().decode(Document.self, from: data)
            guard document.schema == 1, document.jobs.count <= 100 else { throw ConversionError.invalidInput("Invalid batch manifest.") }
            jobs = document.jobs
            guard Set(jobs.map(\.id)).count == jobs.count else { throw ConversionError.invalidInput("Duplicate job identifiers.") }
            for job in jobs {
                guard job.input.isFileURL, job.destination == nil || job.destination!.isFileURL,
                      job.stagedName == nil || Self.safeName(job.stagedName!), job.outputName == nil || Self.safeName(job.outputName!) else {
                    throw ConversionError.invalidInput("Invalid saved job paths.")
                }
            }
            var changed = false
            for i in jobs.indices where jobs[i].state == .running || (jobs[i].state == .ready && !jobs[i].recoverable) {
                jobs[i].state = .interrupted
                jobs[i].message = jobs[i].recoverable ? "Interrupted. Review and retry explicitly." : "One-shot job cannot be resumed. Inspect its destination and create a new job."
                changed = true
            }
            if changed { try save() }
        } else {
            jobs = []
            try save()
        }
        initialized = true
    }
    deinit { flock(lockFD, LOCK_UN); Darwin.close(lockFD) }

    private static func safeName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\\")
    }
    private static func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func readRegular(_ url: URL, maximum: Int) throws -> Data {
        let fd = Darwin.open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size >= 0, info.st_size <= maximum else {
            throw ConversionError.invalidInput("Input must be a bounded regular file, not a link or special file.")
        }
        var data = Data(); var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = Darwin.read(fd, &buffer, min(buffer.count, maximum - data.count + 1))
            if n < 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            if n == 0 { break }
            data.append(contentsOf: buffer.prefix(n))
            guard data.count <= maximum else { throw ConversionError.invalidInput("Input exceeded the byte limit while reading.") }
        }
        return data
    }
    private func cleanupError(_ primary: Error, owned: URL) -> Error {
        var info=stat()
        if lstat(owned.path,&info) != 0 {
            if errno == ENOENT { return primary }
            return QueuePersistenceError(detail: "\(primary.localizedDescription) Cannot inspect owned staging path \(owned.path); it may remain.")
        }
        do { try beforeOwnedCleanup?(owned);try fm.removeItem(at:owned); return primary }
        catch { return QueuePersistenceError(detail: "\(primary.localizedDescription) Owned staging path retained at \(owned.path): \(error.localizedDescription)") }
    }
    private func save() throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(Document(schema: 1, jobs: jobs))
        guard data.count <= 1_000_000 else { throw QueuePersistenceError(detail:"Batch manifest exceeds its size limit.") }
        let temp = directory.appendingPathComponent(".manifest-\(UUID().uuidString)")
        do {
            try beforeManifestWrite?()
            try data.write(to: temp, options: .withoutOverwriting)
            let handle = try FileHandle(forWritingTo: temp); try handle.synchronize(); try handle.close()
            guard Darwin.rename(temp.path, directory.appendingPathComponent("manifest.json").path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        } catch {
            let primary=QueuePersistenceError(detail:"Cannot persist batch manifest: \(error.localizedDescription)")
            throw cleanupError(primary,owned:temp)
        }
    }
    private func transaction(_ change: () -> Void) throws {
        let before=jobs
        change()
        do { try save() } catch { jobs=before; throw error }
    }
    private func inputDirectory(_ id: UUID) -> URL { directory.appendingPathComponent("input-\(id.uuidString)", isDirectory:true) }
    private func inputFile(_ id: UUID, name: String) -> URL { inputDirectory(id).appendingPathComponent(name) }
    private func resultDirectory(_ id: UUID) -> URL { directory.appendingPathComponent("result-\(id.uuidString)", isDirectory: true) }

    nonisolated public static func supports(input: URL, format: ConversionFormat) -> Bool {
        FormatCatalog.formats(for: input).contains(format)
    }
    nonisolated public static func directCaptured(input: URL, format: ConversionFormat) -> Bool {
        let ext=input.pathExtension.lowercased()
        if ["srt","vtt"].contains(ext) { return [.srt,.vtt,.txt].contains(format) }
        if ["txt","rtf","html","htm"].contains(ext) { return [.txt,.rtf,.html].contains(format) }
        if ["png","jpg","jpeg","tif","tiff","heic","bmp"].contains(ext) { return [.png,.jpeg,.tiff,.heic,.bmp].contains(format) }
        return false
    }
    nonisolated public static func singleOutput(input: URL, format: ConversionFormat) -> Bool {
        if format == .folder || format == .rtfd { return false }
        let ext=input.pathExtension.lowercased()
        if ext == "pdf" && [.png,.jpeg,.tiff].contains(format) { return false }
        if ["ppt","pptx","odp"].contains(ext) && [.png,.jpeg].contains(format) { return false }
        return true
    }
    @discardableResult public func enqueue(input: URL, format: ConversionFormat, id: UUID = UUID()) throws -> Job {
        guard jobs.count < 100, input.isFileURL, !jobs.contains(where: { $0.id == id }) else { throw ConversionError.invalidInput("Batch limit or duplicate job.") }
        guard Self.supports(input: input, format: format) else { throw ConversionError.unsupported("This format is not supported by the durable batch.") }
        let access = input.startAccessingSecurityScopedResource(); defer { if access { input.stopAccessingSecurityScopedResource() } }
        var info=stat()
        guard lstat(input.path,&info)==0, (info.st_mode & S_IFMT)==S_IFREG || (info.st_mode & S_IFMT)==S_IFDIR else { throw ConversionError.invalidInput("Choose a regular file or folder, not a link or special file.") }
        let name=input.lastPathComponent
        guard Self.safeName(name) else { throw ConversionError.invalidInput("Invalid input name.") }
        let recoverable = (info.st_mode & S_IFMT)==S_IFREG && info.st_size >= 0 && info.st_size <= maxBytes && Self.singleOutput(input:input,format:format)
        var data=Data()
        if recoverable {
            data=try Self.readRegular(input,maximum:maxBytes)
            let folder=inputDirectory(id);try fm.createDirectory(at:folder,withIntermediateDirectories:false)
            do { try data.write(to:inputFile(id,name:name),options:.withoutOverwriting) }
            catch { throw cleanupError(error,owned:folder) }
        }
        let note = recoverable ? nil : "One-shot operation: interrupted work cannot be resumed safely; inspect the destination and retained staging before creating a new job."
        let job = Job(id:id,input:input.standardizedFileURL,format:format,state:.ready,message:note,inputSHA256:recoverable ? Self.sha(data) : "",inputBytes:data.count,recoverable:recoverable)
        jobs.append(job)
        do { try save() } catch {
            jobs.removeLast()
            if recoverable { throw cleanupError(error,owned:inputDirectory(id)) }
            throw error
        }
        return job
    }
    public func changeFormat(_ id: UUID, format: ConversionFormat) throws {
        guard let i = jobs.firstIndex(where: { $0.id == id && $0.state == .ready && $0.stagedName == nil }), Self.supports(input: jobs[i].input, format: format) else { throw ConversionError.unsupported("The durable job cannot use that format.") }
        try transaction {
            jobs[i].format = format
            jobs[i].recoverable = !jobs[i].inputSHA256.isEmpty && Self.singleOutput(input:jobs[i].input,format:format)
            jobs[i].message = jobs[i].recoverable ? nil : "One-shot operation: interrupted work cannot be resumed safely; inspect the destination and retained staging before creating a new job."
        }
    }
    public func remove(_ id: UUID) throws {
        guard let i=jobs.firstIndex(where: { $0.id == id }), jobs[i].state != .running else { throw ConversionError.invalidInput("A running job cannot be removed.") }
        if jobs[i].state != .complete, let stageID=jobs[i].stageID, let staged=jobs[i].stagedName,
           let dest=jobs[i].destination, let name=jobs[i].outputName,
           sameFile(resultDirectory(stageID).appendingPathComponent(staged),dest.appendingPathComponent(name)) {
            throw ConversionError.invalidInput("A published output is awaiting receipt recovery; retry it before removing the job.")
        }
        try transaction { jobs.remove(at:i) } // Keep snapshots/stages; never remove an uncertain output.
    }
    public func retry(_ id: UUID) throws {
        guard let i=jobs.firstIndex(where: { $0.id == id && ($0.state == .failed || $0.state == .interrupted || $0.state == .prepared) }) else { throw ConversionError.invalidInput("Job is not retryable.") }
        guard jobs[i].recoverable else { throw ConversionError.invalidInput("One-shot job cannot be resumed safely. Inspect its destination and create a new job.") }
        try transaction { jobs[i].state = .ready; jobs[i].message = nil }
    }
    private func sameFile(_ a: URL, _ b: URL) -> Bool {
        var x=stat(), y=stat()
        return lstat(a.path, &x) == 0 && lstat(b.path, &y) == 0 && (x.st_mode & S_IFMT) == S_IFREG && (y.st_mode & S_IFMT) == S_IFREG && x.st_dev == y.st_dev && x.st_ino == y.st_ino
    }
    public func sourceStatus(_ id: UUID) -> String {
        guard let job=jobs.first(where: { $0.id == id }), job.recoverable else { return "not_verified" }
        let access=job.input.startAccessingSecurityScopedResource();defer { if access { job.input.stopAccessingSecurityScopedResource() } }
        guard let bytes=try? Self.readRegular(job.input,maximum:maxBytes) else { return "unavailable" }
        return Self.sha(bytes)==job.inputSHA256 ? "unchanged" : "changed"
    }
    public func verifiedResult(_ id: UUID) throws -> ConversionResult {
        guard let job=jobs.first(where: { $0.id == id && $0.state == .complete && $0.recoverable }),
              let stageID=job.stageID, let staged=job.stagedName, let name=job.outputName,
              let directory=job.destination, let expected=job.outputSHA256, let count=job.outputBytes else {
            throw ConversionError.invalidInput("Completed output receipt is incomplete.")
        }
        let stage=resultDirectory(stageID).appendingPathComponent(staged), output=directory.appendingPathComponent(name)
        let bytes=try Self.readRegular(stage,maximum:maxBytes)
        guard count >= 0, count == bytes.count, sameFile(stage,output), Self.sha(bytes)==expected else {
            throw ConversionError.invalidInput("Published output or retained evidence changed; review before continuing.")
        }
        return ConversionResult(outputURLs:[output],inputBytes:Int64(job.inputBytes),outputBytes:Int64(bytes.count),cleanupWarning:job.cleanupWarning)
    }
    public func oneShotResult(_ id: UUID) throws -> ConversionResult {
        guard let job=jobs.first(where: { $0.id == id && $0.state == .complete && !$0.recoverable }),
              let urls=job.oneShotOutputs, !urls.isEmpty else { throw ConversionError.invalidInput("One-shot output record is unavailable.") }
        return ConversionResult(outputURLs:urls,inputBytes:Int64(job.inputBytes),outputBytes:Int64(job.outputBytes ?? 0),cleanupWarning:job.cleanupWarning)
    }
    public func execute(_ id: UUID, destination: URL, options: ConversionOptions = .init()) async throws -> ConversionResult {
        do { return try await executeOwned(id, destination: destination, options: options) }
        catch {
            let primary=error
            if primary is QueuePersistenceError { throw primary }
            if let i=jobs.firstIndex(where: { $0.id == id }), jobs[i].state != .complete {
                if !jobs[i].recoverable {
                    jobs[i].state = .interrupted
                    jobs[i].message = "\(primary.localizedDescription) One-shot operation may have left outputs or staging. Inspect the destination before creating a new job."
                } else {
                    if jobs[i].state != .prepared { jobs[i].state = Task.isCancelled ? .interrupted : .failed }
                    jobs[i].message = error.localizedDescription
                }
                do { try save() }
                catch { throw QueuePersistenceError(detail:"\(primary.localizedDescription) The job state could not be recorded: \(error.localizedDescription). Reopen after resolving the error.") }
            }
            throw primary
        }
    }
    private func executeOwned(_ id: UUID, destination requestedDestination: URL, options: ConversionOptions) async throws -> ConversionResult {
        guard var index=jobs.firstIndex(where: { $0.id == id && ($0.state == .ready || $0.state == .prepared) }) else { throw ConversionError.invalidInput("Job is not ready.") }
        let sourceURL=jobs[index].input
        if !jobs[index].recoverable {
            jobs[index].state = .running; jobs[index].destination = requestedDestination.standardizedFileURL; try save()
            let result=try await ConversionEngine().convert(input:sourceURL,to:jobs[index].format,outputDirectory:requestedDestination,options:options)
            guard let current=jobs.firstIndex(where: { $0.id == id && $0.state == .running }) else { throw ConversionError.invalidInput("Job owner changed during conversion.") }
            index=current
            jobs[index].state = .complete; jobs[index].oneShotOutputs=result.outputURLs; jobs[index].inputBytes=Int(result.inputBytes); jobs[index].outputBytes=Int(result.outputBytes)
            jobs[index].cleanupWarning=result.cleanupWarning
            jobs[index].message="One-shot output published; retained paths are not independently verified after restart." + (result.cleanupWarning.map { " " + $0 } ?? "")
            do { try save() } catch { jobs[index].state = .interrupted; throw QueuePersistenceError(detail:"Output was published but its receipt could not be recorded: \(error.localizedDescription). Inspect the destination before creating a new job.") }
            return result
        }
        let access=sourceURL.startAccessingSecurityScopedResource();defer { if access { sourceURL.stopAccessingSecurityScopedResource() } }
        let destAccess=requestedDestination.startAccessingSecurityScopedResource();defer { if destAccess { requestedDestination.stopAccessingSecurityScopedResource() } }
        let destination=requestedDestination.standardizedFileURL
        func checkDestination() throws {
            try fm.createDirectory(at:destination,withIntermediateDirectories:true)
            var sourceDevice=stat(),destinationDevice=stat()
            guard stat(directory.path,&sourceDevice)==0, stat(destination.path,&destinationDevice)==0,
                  (destinationDevice.st_mode & S_IFMT)==S_IFDIR, sourceDevice.st_dev==destinationDevice.st_dev else {
                throw ConversionError.invalidInput("Durable batch and destination must be on the same volume; choose a destination on that volume.")
            }
        }
        func validateSource() throws -> Data {
            let current=try Self.readRegular(jobs[index].input, maximum:maxBytes)
            guard Self.sha(current)==jobs[index].inputSHA256 else { throw ConversionError.invalidInput("Source changed since this batch was planned; create a new job.") }
            let snapshot=inputFile(id,name:jobs[index].input.lastPathComponent)
            let captured=try Self.readRegular(snapshot,maximum:maxBytes)
            guard Self.sha(captured)==jobs[index].inputSHA256 else { throw ConversionError.invalidInput("Captured source differs from the saved job.") }
            return captured
        }
        let output: URL
        if let staged=jobs[index].stagedName, let name=jobs[index].outputName, let expected=jobs[index].outputSHA256, let saved=jobs[index].destination {
            guard saved.standardizedFileURL == destination.standardizedFileURL else { throw ConversionError.invalidInput("Prepared output belongs to a different destination.") }
            guard let stageID=jobs[index].stageID else { throw ConversionError.invalidInput("Prepared stage identity missing.") }
            let stage=resultDirectory(stageID).appendingPathComponent(staged);output=destination.appendingPathComponent(name)
            let bytes=try Self.readRegular(stage,maximum:maxBytes)
            guard let count=jobs[index].outputBytes, count >= 0, count == bytes.count, Self.sha(bytes)==expected else { throw ConversionError.invalidInput("Prepared output or receipt changed; recovery refused.") }
            jobs[index].state = .prepared;try save()
            if !sameFile(stage,output) {
                _ = try validateSource();try checkDestination()
                try OutputTransaction.publishPrepared(stage,to:output)
            }
        } else {
            let captured=try validateSource();try checkDestination()
            jobs[index].state = .running; jobs[index].destination = destination.standardizedFileURL
            if jobs[index].quality == nil { jobs[index].quality = options.quality; jobs[index].maxPixelSize = options.maxPixelSize }
            let fixedOptions=ConversionOptions(quality:jobs[index].quality!,maxPixelSize:jobs[index].maxPixelSize)
            try save()
            do {
                let stageID=UUID();let resultDir=resultDirectory(stageID)
                jobs[index].stageID=stageID;try save()
                try fm.createDirectory(at:resultDir,withIntermediateDirectories:false)
                let stage: URL
                var conversionWarning: String?
                if Self.directCaptured(input:sourceURL,format:jobs[index].format) {
                    stage=resultDir.appendingPathComponent("converted." + jobs[index].format.fileExtension)
                    try await ConversionEngine().convertCaptured(captured,input:sourceURL,to:jobs[index].format,destination:stage,options:fixedOptions)
                } else {
                    let result=try await ConversionEngine().convert(input:inputFile(id,name:sourceURL.lastPathComponent),to:jobs[index].format,outputDirectory:resultDir,options:fixedOptions)
                    guard result.outputURLs.count == 1 else { throw ConversionError.unsupported("Output has multiple files; inspect the retained stage and use a one-shot operation.") }
                    stage=result.outputURLs[0]
                    conversionWarning=result.cleanupWarning
                }
                try afterStageConversion?()
                guard Self.sha(try Self.readRegular(inputFile(id,name:sourceURL.lastPathComponent),maximum:maxBytes)) == Self.sha(captured) else { throw ConversionError.invalidInput("Private source snapshot changed during conversion; publication refused.") }
                guard let current=jobs.firstIndex(where: { $0.id == id && $0.state == .running }) else { throw ConversionError.invalidInput("Job owner changed during conversion.") }
                index=current
                jobs[index].cleanupWarning=conversionWarning
                let bytes=try Self.readRegular(stage,maximum:maxBytes)
                let base=jobs[index].format == .gzip ? jobs[index].input.lastPathComponent : jobs[index].input.deletingPathExtension().lastPathComponent
                let ext=jobs[index].format.fileExtension
                let safeBase=String((base.isEmpty ? "Converted" : base).prefix(160))
                guard Self.safeName(safeBase), Self.safeName(stage.lastPathComponent) else { throw ConversionError.invalidInput("Invalid destination name.") }
                var chosen: String?
                for suffix in 0..<10000 {
                    let name=safeBase + (suffix == 0 ? "" : " (\(suffix + 1))") + (ext.isEmpty ? "" : "."+ext)
                    var entry=stat();let path=destination.appendingPathComponent(name)
                    if lstat(path.path,&entry) != 0 {
                        if errno == ENOENT { chosen=name;break }
                        throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO)
                    }
                }
                guard let name=chosen else { throw ConversionError.conversionFailed("Too many files share this name in the destination.") }
                output=destination.appendingPathComponent(name)
                jobs[index].stagedName=stage.lastPathComponent; jobs[index].outputName=name; jobs[index].outputSHA256=Self.sha(bytes);jobs[index].outputBytes=bytes.count;jobs[index].state = .prepared
                try save() // The prepared receipt precedes any public link.
                try Task.checkCancellation()
                try OutputTransaction.publishPrepared(stage,to:output)
            } catch { throw error }
        }
        // Once linked, do not relabel publication as a failed conversion if receipt persistence fails.
        jobs[index].state = .complete; jobs[index].message = jobs[index].cleanupWarning
        do { try save() } catch { jobs[index].state = .prepared; throw QueuePersistenceError(detail:"Output was published; reopen and reconcile its receipt before retrying. \(error.localizedDescription)") }
        return ConversionResult(outputURLs:[output], inputBytes:Int64(jobs[index].inputBytes), outputBytes:Int64(jobs[index].outputBytes ?? 0), cleanupWarning:jobs[index].cleanupWarning)
    }
}
