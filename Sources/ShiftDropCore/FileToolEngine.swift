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
}
