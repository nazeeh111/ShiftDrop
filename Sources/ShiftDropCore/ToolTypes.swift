import Foundation

public enum FileTool: String, CaseIterable, Identifiable, Sendable {
    case compress, metadata, editImage, annotateImage, frameImage, cropImage, redactImage, collage, imagesPDF
    case trimVideo, cropVideo, videoSpeed, joinVideo, videoFrames, splitVideo, redactVideo
    case normalizeAudio, audioVisualizer, trimAudio, audioChannels, bleepAudio
    case mergePDF, organizePDF
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .compress: return "Compress"
        case .metadata: return "Metadata"
        case .editImage: return "Adjust photo"
        case .annotateImage: return "Annotate photo"
        case .frameImage: return "Add background"
        case .cropImage: return "Crop image"
        case .redactImage: return "Redact photo"
        case .collage: return "Make collage"
        case .imagesPDF: return "Images to PDF"
        case .trimVideo: return "Trim video"
        case .cropVideo: return "Crop video"
        case .videoSpeed: return "Change speed"
        case .joinVideo: return "Join videos"
        case .videoFrames: return "Save frames"
        case .splitVideo: return "Split video"
        case .redactVideo: return "Redact video"
        case .normalizeAudio: return "Normalize volume"
        case .audioVisualizer: return "Audio visualizer"
        case .trimAudio: return "Trim audio"
        case .audioChannels: return "Audio channels"
        case .bleepAudio: return "Bleep audio"
        case .mergePDF: return "Merge PDFs"
        case .organizePDF: return "Organize pages"
        }
    }
    public var family: String {
        switch self {
        case .compress, .metadata: return "General"
        case .editImage, .annotateImage, .frameImage, .cropImage, .redactImage, .collage, .imagesPDF: return "Image"
        case .trimVideo, .cropVideo, .videoSpeed, .joinVideo, .videoFrames, .splitVideo, .redactVideo: return "Video"
        case .normalizeAudio, .audioVisualizer, .trimAudio, .audioChannels, .bleepAudio: return "Audio"
        case .mergePDF, .organizePDF: return "PDF"
        }
    }
    public var requiresMultiple: Bool { [.collage, .imagesPDF, .joinVideo, .mergePDF].contains(self) }
    public static func available(for inputs: [URL]) -> [FileTool] {
        guard !inputs.isEmpty else { return [] }
        let kinds = Set(inputs.map { FormatCatalog.kind(for: $0) })
        var tools: [FileTool] = [.compress, .metadata]
        if kinds == ["Image"] { tools += [.editImage, .annotateImage, .frameImage, .cropImage, .redactImage, .collage, .imagesPDF] }
        if kinds == ["PDF"] { tools += [.mergePDF, .organizePDF] }
        if FormatCatalog.ffmpegURL != nil {
            if kinds == ["Video"] { tools += [.trimVideo, .cropVideo, .videoSpeed, .joinVideo, .videoFrames, .splitVideo, .redactVideo] }
            if kinds == ["Audio"] { tools += [.normalizeAudio, .audioVisualizer, .trimAudio, .audioChannels, .bleepAudio] }
        }
        return tools
    }
}

public struct ToolPoint: Sendable, Equatable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

public struct ToolRegion: Sendable, Equatable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int
    public init(x: Int, y: Int, width: Int, height: Int) { self.x = x; self.y = y; self.width = width; self.height = height }
}

/// Annotation layers are drawn in their array order over the source image.
public struct ImageMark: Sendable, Equatable {
    public var kind: String
    public var region: ToolRegion
    public var text: String
    public var colorHex: String
    public var fontSize: Double
    public var lineWidth: Double
    public var rotation: Int
    public var points: [ToolPoint]
    public var imageURL: URL?
    public init(kind: String, region: ToolRegion, text: String = "1", colorHex: String = "17211B", fontSize: Double = 32,
                lineWidth: Double = 4, rotation: Int = 0, points: [ToolPoint] = [], imageURL: URL? = nil) {
        self.kind = kind; self.region = region; self.text = text; self.colorHex = colorHex; self.fontSize = fontSize
        self.lineWidth = lineWidth; self.rotation = rotation; self.points = points; self.imageURL = imageURL
    }
}

/// Pixel coordinates use a top-left origin. Time values are in seconds.
public struct ToolSettings: Sendable {
    public var width = 1280
    public var height = 720
    public var x = 0
    public var y = 0
    public var start = 0.0
    public var end = 10.0
    public var speed = 2.0
    public var quality = 0.8
    public var targetBytes: Int64 = 0
    public var exposure = 0.0
    public var brightness = 0.0
    public var sharpness = 0.0
    public var noiseReduction = 0.0
    public var dehaze = 0.0
    public var clarity = 0.0
    public var grain = 0.0
    public var frameBlur = 0.0
    public var frameShadow = 0.0
    public var saturation = 1.0
    public var contrast = 1.0
    public var text = "ShiftDrop"
    public var annotation = "text"
    public var fontSize = 32.0
    public var lineWidth = 4.0
    public var colorHex = "111E16"
    public var backgroundHex = "F4F5EE"
    public var padding = 40
    public var cornerRadius = 16
    public var columns = 2
    public var parts = 2
    public var channels = 1
    public var leftGain = 1.0
    public var rightGain = 1.0
    public var loudness = -16.0
    public var truePeak = -1.5
    public var loudnessRange = 11.0
    public var pageOrder = ""
    public var rotation = 0
    public var removeMetadata = true
    public var detectFaces = false
    public var detectText = false
    public var blur = false
    public var removeSilence = false
    public var limitTimeRange = false
    public var metadataTitle = ""
    public var backgroundImage: URL?
    public var marks: [ImageMark] = []
    public var regions: [ToolRegion] = []
    public var points: [ToolPoint] = []
    public var waveform = true
    public var splitPoints = ""
    public var pageRotations = ""
    public init() {}
}

public struct ToolRequest: Sendable {
    public var tool: FileTool
    public var inputs: [URL]
    public var outputDirectory: URL
    public var settings: ToolSettings
    /// Per-input tools save beside each source; combined tools use the first source parent.
    public var outputBesideInputs: Bool
    public init(tool: FileTool, inputs: [URL], outputDirectory: URL, settings: ToolSettings = ToolSettings(), outputBesideInputs: Bool = false) {
        self.tool = tool; self.inputs = inputs; self.outputDirectory = outputDirectory; self.settings = settings
        self.outputBesideInputs = outputBesideInputs
    }
}

/// Generated output is staged beside its destination and published without replacing files.
public enum ToolOutput {
    public static func stage(in directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let staging = directory.appendingPathComponent(".shiftdrop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        return staging
    }
    public static func publish(_ staged: [URL], request: ToolRequest) throws -> ConversionResult {
        var outputs: [URL] = []
        do {
            for (index, url) in staged.enumerated() {
                try Task.checkCancellation()
                let base = request.inputs.first?.deletingPathExtension().lastPathComponent ?? "Files"
                let suffix = staged.count > 1 ? "-\(index + 1)" : ""
                outputs.append(try ConversionEngine.publish(url, directory: request.outputDirectory, basename: base + "-" + request.tool.rawValue + suffix, extension: url.pathExtension))
            }
            return ConversionResult(outputURLs: outputs, inputBytes: try request.inputs.reduce(0) { try $0 + ConversionEngine.byteCount($1) }, outputBytes: try outputs.reduce(0) { try $0 + ConversionEngine.byteCount($1) })
        } catch {
            for url in outputs { try? FileManager.default.removeItem(at: url) }
            throw error
        }
    }
}
