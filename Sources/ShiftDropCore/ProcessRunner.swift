import Foundation
import Darwin

enum ProcessRunner {
    static func run(executable: URL, arguments: [String]) async throws {
        let state = ProcessState()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                state.start(executable: executable, arguments: arguments, continuation: continuation)
            }
        } onCancel: { state.cancel() }
        try Task.checkCancellation()
    }
}

private final class ProcessState: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private var completed = false

    func start(executable: URL, arguments: [String], continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        if cancelled { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
        let task = Process()
        task.executableURL = executable
        task.arguments = arguments
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = FileHandle.nullDevice
        let pipe = Pipe()
        task.standardError = pipe
        process = task
        let buffer = BoundedDiagnosticBuffer()
        let readGroup = DispatchGroup()
        readGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { readGroup.leave(); try? pipe.fileHandleForReading.close() }
            while true {
                let data = pipe.fileHandleForReading.readData(ofLength: 4096)
                if data.isEmpty { break }
                buffer.append(data)
            }
        }
        task.terminationHandler = { [self] finished in
            readGroup.wait()
            lock.lock()
            guard !completed else { lock.unlock(); return }
            completed = true
            let wasCancelled = cancelled
            process = nil
            lock.unlock()
            if wasCancelled { continuation.resume(throwing: CancellationError()) }
            else if finished.terminationStatus == 0 { continuation.resume() }
            else {
                let detail = buffer.message.trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(throwing: ConversionError.conversionFailed(detail.isEmpty ? "The conversion tool exited with code \(finished.terminationStatus)." : detail))
            }
        }
        do {
            try task.run()
            try? pipe.fileHandleForWriting.close()
            lock.unlock()
        } catch {
            completed = true
            process = nil
            try? pipe.fileHandleForWriting.close()
            lock.unlock()
            readGroup.wait()
            continuation.resume(throwing: ConversionError.conversionFailed("Cannot start \(executable.lastPathComponent): \(error.localizedDescription)"))
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let task = process
        if let task, task.isRunning { task.terminate() }
        lock.unlock()
        if let task {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
                // A converter that ignores SIGTERM must not outlive a cancelled job.
                if task.isRunning { Darwin.kill(task.processIdentifier, SIGKILL) }
            }
        }
    }
}

private final class BoundedDiagnosticBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    func append(_ data: Data) {
        lock.lock()
        bytes.append(data)
        if bytes.count > 16_384 { bytes.removeFirst(bytes.count - 16_384) }
        lock.unlock()
    }
    var message: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: bytes, as: UTF8.self)
    }
}
