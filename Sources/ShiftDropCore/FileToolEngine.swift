import Foundation

public enum FileToolEngine {
    public static func run(_ request: ToolRequest) async throws -> ConversionResult {
        try Task.checkCancellation()
        guard !request.inputs.isEmpty, request.inputs.count <= 1000 else { throw ConversionError.invalidInput("Choose between 1 and 1,000 files.") }
        for url in request.inputs {
            guard url.isFileURL else { throw ConversionError.invalidInput("Only local files are supported.") }
            let attributes = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey])
            guard attributes.isSymbolicLink != true, attributes.isRegularFile == true || attributes.isDirectory == true else { throw ConversionError.invalidInput("Choose regular files or folders, not symbolic links.") }
        }
        guard FileTool.available(for: request.inputs).contains(request.tool) else { throw ConversionError.unsupported("This tool cannot process the selected file types together.") }
        if request.outputBesideInputs { return try await runBesideInputs(request) }
        let kinds = Set(request.inputs.map { FormatCatalog.kind(for: $0) })
        let kind = kinds.count == 1 ? FormatCatalog.kind(for: request.inputs[0]) : "Mixed"
        if request.tool.family == "Image" || (kind == "Image" && [.compress, .metadata].contains(request.tool)) { return try await ImageTools.run(request) }
        if request.tool.family == "PDF" || (kind == "PDF" && [.compress, .metadata].contains(request.tool)) { return try await PDFTools.run(request) }
        if request.tool.family == "Video" || request.tool.family == "Audio" || (["Video", "Audio"].contains(kind) && [.compress, .metadata].contains(request.tool) && FormatCatalog.ffmpegURL != nil) { return try await MediaTools.run(request) }
        if request.tool == .compress {
            for url in request.inputs where (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                try ConversionEngine.validateArchiveInput(url, outputDirectory: request.outputDirectory)
            }
        }
        let staging = try ToolOutput.stage(in: request.outputDirectory)
        defer { try? FileManager.default.removeItem(at: staging) }
        var files: [URL] = []
        if request.tool == .compress {
            // Reuse validated archive conversion; then republish through this tool's output policy.
            for url in request.inputs {
                let result = try await ConversionEngine().convert(input: url, to: .zip, outputDirectory: staging)
                files += result.outputURLs
            }
        } else if request.tool == .metadata {
            for (index, url) in request.inputs.enumerated() {
                let values = try url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey, .contentModificationDateKey, .isDirectoryKey, .typeIdentifierKey])
                let report: [String: Any] = ["filename": url.lastPathComponent, "bytes": values.fileSize ?? 0, "directory": values.isDirectory ?? false, "type": values.typeIdentifier ?? "unknown", "created": values.creationDate.map { ISO8601DateFormatter().string(from: $0) } ?? "unknown", "modified": values.contentModificationDate.map { ISO8601DateFormatter().string(from: $0) } ?? "unknown", "note": "Filesystem information only. This report does not modify or sanitize the source."]
                let output = staging.appendingPathComponent("report-\(index).json")
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output)
                files.append(output)
            }
        }
        guard !files.isEmpty else { throw ConversionError.unsupported("No output was produced for this tool.") }
        return try ToolOutput.publish(files, request: request)
    }

    private static func runBesideInputs(_ request: ToolRequest) async throws -> ConversionResult {
        if request.tool.requiresMultiple {
            var combined = request
            combined.outputBesideInputs = false
            combined.outputDirectory = request.inputs[0].deletingLastPathComponent()
            return try await run(combined)
        }

        // Prepare every source before publishing anything. Each owned scratch folder
        // is outside the source, so folder compression cannot archive its own output.
        let folders = request.inputs.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        var scratchDirectories: [URL] = []
        var prepared: [(request: ToolRequest, files: [URL])] = []
        var published: [URL] = []
        var inputBytes: Int64 = 0
        var outputBytes: Int64 = 0
        defer { for directory in scratchDirectories { try? FileManager.default.removeItem(at: directory) } }
        do {
            for input in request.inputs {
                try Task.checkCancellation()
                let destination = input.deletingLastPathComponent()
                var scratchParent = destination.resolvingSymlinksInPath().standardizedFileURL
                // Nested selections must not place temporary files inside another
                // selected source folder while that folder is being archived.
                while folders.contains(where: { folder in
                    let source = folder.resolvingSymlinksInPath().standardizedFileURL.path
                    return scratchParent.path == source || scratchParent.path.hasPrefix(source + "/")
                }) {
                    let parent = scratchParent.deletingLastPathComponent()
                    guard parent != scratchParent else { throw ConversionError.invalidInput("Choose files with a writable folder outside the selected source folders.") }
                    scratchParent = parent
                }
                let scratch = try ToolOutput.stage(in: scratchParent)
                scratchDirectories.append(scratch)
                var single = request
                single.inputs = [input]
                single.outputDirectory = scratch
                single.outputBesideInputs = false
                let result = try await run(single)
                inputBytes += result.inputBytes
                single.outputDirectory = destination
                prepared.append((single, result.outputURLs))
            }
            for group in prepared {
                try Task.checkCancellation()
                let result = try ToolOutput.publish(group.files, request: group.request)
                published += result.outputURLs
                outputBytes += result.outputBytes
            }
            try Task.checkCancellation()
            return ConversionResult(outputURLs: published, inputBytes: inputBytes, outputBytes: outputBytes)
        } catch {
            for output in published { try? FileManager.default.removeItem(at: output) }
            throw error
        }
    }

}
