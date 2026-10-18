import Foundation
import ImageIO

/// Local FFmpeg transformations. Video output is H.264/AAC MP4; edited audio is float PCM WAV.
public enum MediaTools {
    public static func run(_ request: ToolRequest) async throws -> ConversionResult {
        try Task.checkCancellation()
        guard let ffmpeg = FormatCatalog.ffmpegURL else { throw ConversionError.toolMissing }
        guard !request.inputs.isEmpty, request.inputs.count <= 32, request.outputDirectory.isFileURL else {
            throw ConversionError.invalidInput("Choose between 1 and 32 local media files and a local output folder.")
        }
        let access = (request.inputs + [request.outputDirectory] + [request.settings.backgroundImage].compactMap { $0 }).filter { $0.startAccessingSecurityScopedResource() }
        defer { access.forEach { $0.stopAccessingSecurityScopedResource() } }
        for input in request.inputs {
            guard input.isFileURL, (try input.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])).isRegularFile == true else {
                throw ConversionError.invalidInput("Media tools require local regular files.")
            }
            _ = try ConversionEngine.byteCount(input)
        }
        let s = request.settings
        guard s.quality.isFinite, (0...1).contains(s.quality), s.targetBytes >= 0 else {
            throw ConversionError.invalidOptions("Quality must be between 0 and 1, and the target byte count cannot be negative.")
        }
        let stage = try ToolOutput.stage(in: request.outputDirectory)
        defer { try? FileManager.default.removeItem(at: stage) }
        let infos = try await request.inputs.asyncMap { try await MediaInspection.read($0, ffmpeg: ffmpeg, stage: stage) }
        var outputs: [URL] = []
        if request.tool == .joinVideo {
            outputs = [try await join(request, infos: infos, ffmpeg: ffmpeg, stage: stage)]
        } else {
            for (index, input) in request.inputs.enumerated() {
                try Task.checkCancellation()
                outputs += try await transform(input, info: infos[index], request: request, index: index, ffmpeg: ffmpeg, stage: stage)
            }
        }
        guard !outputs.isEmpty else { throw ConversionError.conversionFailed("No media output was generated.") }
        for output in outputs {
            guard (try output.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0 > 0 else {
                throw ConversionError.conversionFailed("The media tool produced an empty output.")
            }
        }
        try Task.checkCancellation()
        return try ToolOutput.publish(outputs, request: request)
    }

    private static func transform(_ input: URL, info: MediaInspection, request: ToolRequest, index: Int, ffmpeg: URL, stage: URL) async throws -> [URL] {
        let s = request.settings
        let videoTools: [FileTool] = [.trimVideo, .cropVideo, .videoSpeed, .videoFrames, .splitVideo, .redactVideo]
        let audioTools: [FileTool] = [.normalizeAudio, .audioVisualizer, .trimAudio, .audioChannels, .bleepAudio]
        if videoTools.contains(request.tool), !info.hasVideo { throw ConversionError.invalidInput("\(input.lastPathComponent) has no video stream.") }
        if audioTools.contains(request.tool), !info.hasAudio { throw ConversionError.invalidInput("\(input.lastPathComponent) has no audio stream.") }
        let output = stage.appendingPathComponent("media-\(index).\(videoTools.contains(request.tool) ? "mp4" : "wav")")
        var args = base + localInput(input)
        switch request.tool {
        case .trimVideo, .trimAudio:
            var span = try range(s, duration: info.duration)
            if request.tool == .trimAudio && s.removeSilence { span = try await audibleEdges(input, span: span, ffmpeg: ffmpeg) }
            args += ["-ss", number(span.0), "-t", number(span.1 - span.0)]
            args += request.tool == .trimVideo ? videoEncoding(info: info, quality: s.quality) : audioEncoding
        case .cropVideo:
            try rectangle(s, info: info)
            guard s.width.isMultiple(of: 2), s.height.isMultiple(of: 2) else { throw ConversionError.invalidOptions("Video crop width and height must be even numbers.") }
            args += ["-vf", "crop=\(s.width):\(s.height):\(s.x):\(s.y)"] + videoEncoding(info: info, quality: s.quality, scale: false)
        case .videoSpeed:
            guard s.speed.isFinite, (0.125...8).contains(s.speed) else { throw ConversionError.invalidOptions("Speed must be between 0.125× and 8×.") }
            args += ["-vf", "setpts=(PTS-STARTPTS)/\(number(s.speed))"]
            if info.hasAudio { args += ["-af", tempo(s.speed)] }
            args += videoEncoding(info: info, quality: s.quality) + ["-fps_mode", "vfr"]
        case .videoFrames:
            let span = try range(s, duration: info.duration)
            guard (1...120).contains(s.parts), request.inputs.count * s.parts <= 240 else { throw ConversionError.invalidOptions("Save 1–120 frames per file, with at most 240 frames per operation.") }
            var frames: [URL] = []
            for frame in 0..<s.parts {
                let time = span.0 + (span.1 - span.0) * Double(frame) / Double(s.parts)
                let destination = stage.appendingPathComponent("frame-\(index)-\(frame).png")
                try await ProcessRunner.run(executable: ffmpeg, arguments: base + localInput(input) + ["-ss", number(time), "-map", "0:\(info.videoIndex)", "-frames:v", "1", "-an", "-update", "1", destination.path])
                frames.append(destination)
            }
            return frames
        case .splitVideo:
            let boundaries = try splitBoundaries(s, duration: info.duration)
            guard request.inputs.count * (boundaries.count - 1) <= 128 else { throw ConversionError.invalidOptions("Split operations are limited to 128 output files.") }
            var parts: [URL] = []
            for part in 0..<(boundaries.count - 1) {
                let begin = boundaries[part]
                let end = boundaries[part + 1]
                let destination = stage.appendingPathComponent("part-\(index)-\(part).mp4")
                try await ProcessRunner.run(executable: ffmpeg, arguments: base + localInput(input) + ["-ss", number(begin), "-t", number(end - begin)] + videoEncoding(info: info, quality: s.quality) + [destination.path])
                parts.append(destination)
            }
            return parts
        case .redactVideo:
            try rectangle(s, info: info)
            var enable = ""
            if s.limitTimeRange {
                let span = try range(s, duration: info.duration)
                enable = ":enable='between(t,\(number(span.0)),\(number(span.1)))'"
            }
            if s.blur {
                guard s.width >= 4, s.height >= 4 else { throw ConversionError.invalidOptions("A blur rectangle must be at least 4 × 4 pixels.") }
                let radius = max(1, min(20, min(s.width, s.height) / 4))
                let filter = "[0:\(info.videoIndex)]split[base][region];[region]crop=\(s.width):\(s.height):\(s.x):\(s.y),boxblur=\(radius):1[blur];[base][blur]overlay=\(s.x):\(s.y)\(enable)[redacted]"
                args += ["-filter_complex", filter, "-map", "[redacted]"]
                if info.hasAudio { args += ["-map", "0:a:0"] }
                args += videoEncoding(info: info, quality: s.quality, map: false)
            } else {
                guard validHex(s.colorHex) else { throw ConversionError.invalidOptions("Cover color must contain six hexadecimal digits.") }
                args += ["-vf", "drawbox=x=\(s.x):y=\(s.y):w=\(s.width):h=\(s.height):color=0x\(s.colorHex):t=fill\(enable)"] + videoEncoding(info: info, quality: s.quality)
            }
        case .normalizeAudio:
            guard s.loudness.isFinite, (-70 ... -5).contains(s.loudness), s.truePeak.isFinite, (-9...0).contains(s.truePeak), s.loudnessRange.isFinite, (1...50).contains(s.loudnessRange) else {
                throw ConversionError.invalidOptions("Loudness must be −70 to −5 LUFS, true peak −9 to 0 dBTP, and loudness range 1–50 LU.")
            }
            var filters: [String] = []
            if s.removeSilence {
                let span = try await audibleEdges(input, span: (0, info.duration), ffmpeg: ffmpeg)
                args += ["-ss", number(span.0), "-t", number(span.1 - span.0)]
            }
            filters.append("loudnorm=I=\(number(s.loudness)):TP=\(number(s.truePeak)):LRA=\(number(s.loudnessRange)):linear=false")
            args += ["-af", filters.joined(separator: ","), "-ar", "48000"] + audioEncoding
        case .audioChannels:
            guard [1, 2].contains(s.channels), s.leftGain.isFinite, s.rightGain.isFinite, (0...4).contains(s.leftGain), (0...4).contains(s.rightGain) else { throw ConversionError.invalidOptions("Choose mono or stereo with channel gains between 0 and 4.") }
            // Normalize arbitrary source layouts to stereo first, then apply independent channel gains.
            let left = number(s.leftGain), right = number(s.rightGain)
            let pan = s.channels == 1 ? "pan=mono|c0=0.5*\(left)*c0+0.5*\(right)*c1" : "pan=stereo|c0=\(left)*c0|c1=\(right)*c1"
            args += ["-af", "aformat=channel_layouts=stereo,\(pan)"] + audioEncoding
        case .bleepAudio:
            let span = try range(s, duration: info.duration)
            let begin = number(span.0), end = number(span.1)
            // Sample expressions replace the selected interval, rather than mixing speech under a tone.
            let filter = "aformat=sample_fmts=flt:channel_layouts=stereo,aeval=exprs='if(between(t,\(begin),\(end)),0.2*sin(2*PI*1000*t),val(0))|if(between(t,\(begin),\(end)),0.2*sin(2*PI*1000*t),val(1))':c=stereo"
            args += ["-af", filter] + audioEncoding
        case .audioVisualizer:
            try canvas(s.width, s.height)
            guard validHex(s.colorHex), validHex(s.backgroundHex) else { throw ConversionError.invalidOptions("Visualizer colors must contain six hexadecimal digits.") }
            var extraInput: [String] = []
            if let background = s.backgroundImage {
                guard background.isFileURL, (try background.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else { throw ConversionError.invalidInput("Choose a local background image.") }
                _ = try ConversionEngine.byteCount(background)
                guard let source = CGImageSourceCreateWithURL(background as CFURL, nil), let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any], let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0, width <= 16384, height <= 16384, width * height <= 80_000_000 else { throw ConversionError.invalidInput("Choose a readable background image with at most 80 million pixels and dimensions up to 16,384 pixels.") }
                extraInput = ["-loop", "1"] + localInput(background)
            }
            var filter = s.backgroundImage != nil
                ? "[1:v:0]scale=\(s.width):\(s.height):force_original_aspect_ratio=increase,crop=\(s.width):\(s.height),setsar=1,format=rgba[background]"
                : "color=c=0x\(s.backgroundHex):s=\(s.width)x\(s.height):r=30,format=rgba[background]"
            if s.waveform {
                // showwaves has transparent pixels outside the line; preserve that alpha over the background.
                filter += ";[0:a:0]showwaves=s=\(s.width)x\(s.height):mode=line:r=30:colors=0x\(s.colorHex),format=rgba[visual];[background][visual]overlay=shortest=1[out]"
            } else { filter += ";[background]null[out]" }
            let destination = stage.appendingPathComponent("visualizer-\(index).mp4")
            args += extraInput + ["-filter_complex", filter, "-map", "[out]", "-map", "0:a:0", "-c:v", "libx264", "-crf", crf(s.quality), "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "192k", "-t", number(info.duration), "-shortest", "-movflags", "+faststart", "-map_metadata", "-1", destination.path]
            try await ProcessRunner.run(executable: ffmpeg, arguments: args)
            return [destination]
        case .compress:
            return [try await compress(input, info: info, settings: s, ffmpeg: ffmpeg, stage: stage, index: index)]
        case .metadata:
            if !s.removeMetadata && s.metadataTitle.isEmpty {
                let report = stage.appendingPathComponent("metadata-\(index).json")
                try info.rawJSON.write(to: report)
                return [report]
            }
            let ext = input.pathExtension.lowercased()
            guard !ext.isEmpty else { throw ConversionError.unsupported("A media extension is needed to preserve its container.") }
            let destination = stage.appendingPathComponent("metadata-\(index).\(ext)")
            args += ["-map", "0", "-c", "copy"]
            if s.removeMetadata { args += ["-map_metadata", "-1", "-map_chapters", "-1"] }
            if !s.metadataTitle.isEmpty { args += ["-metadata", "title=\(s.metadataTitle)"] }
            args += [destination.path]
            try await ProcessRunner.run(executable: ffmpeg, arguments: args)
            return [destination]
        default: throw ConversionError.unsupported("\(request.tool.title) is not a media tool.")
        }
        args += ["-map_metadata", "-1", output.path]
        try await ProcessRunner.run(executable: ffmpeg, arguments: args)
        if request.tool == .normalizeAudio {
            let sourceLevels = try await levels(input, duration: info.duration, ffmpeg: ffmpeg)
            let outputInfo = try await MediaInspection.read(output, ffmpeg: ffmpeg, stage: stage)
            let outputLevels = try await levels(output, duration: outputInfo.duration, ffmpeg: ffmpeg)
            let report = stage.appendingPathComponent("levels-\(index).json")
            let payload: [String: Any] = ["file": input.lastPathComponent, "measurement": "FFmpeg EBU R128 integrated loudness, loudness range, sample peak and true peak", "input": sourceLevels, "output": outputLevels, "targetIntegratedLUFS": s.loudness, "maximumTruePeakDBTP": s.truePeak, "targetLoudnessRangeLU": s.loudnessRange]
            try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]).write(to: report)
            return [output, report]
        }
        return [output]
    }

    private static func join(_ request: ToolRequest, infos: [MediaInspection], ffmpeg: URL, stage: URL) async throws -> URL {
        guard infos.count >= 2, infos.allSatisfy(\.hasVideo) else { throw ConversionError.invalidInput("Join requires at least two videos.") }
        let width = infos[0].width / 2 * 2, height = infos[0].height / 2 * 2
        try canvas(width, height)
        let audio = infos.contains(where: \.hasAudio)
        var args = base
        request.inputs.forEach { args += localInput($0) }
        var filters: [String] = []
        for (index, info) in infos.enumerated() {
            let duration = number(info.duration)
            filters.append("[\(index):\(info.videoIndex)]scale=\(width):\(height):force_original_aspect_ratio=decrease:force_divisible_by=2,pad=\(width):\(height):(ow-iw)/2:(oh-ih)/2,setsar=1,fps=30,trim=duration=\(duration),setpts=PTS-STARTPTS[v\(index)]")
            if audio {
                if info.hasAudio { filters.append("[\(index):a:0]aresample=48000,aformat=sample_fmts=fltp:channel_layouts=stereo,apad,atrim=duration=\(duration),asetpts=PTS-STARTPTS[a\(index)]") }
                else { filters.append("anullsrc=r=48000:cl=stereo,atrim=duration=\(duration),asetpts=PTS-STARTPTS[a\(index)]") }
            }
        }
        let labels = infos.indices.map { "[v\($0)]" + (audio ? "[a\($0)]" : "") }.joined()
        filters.append("\(labels)concat=n=\(infos.count):v=1:a=\(audio ? 1 : 0)[video]" + (audio ? "[audio]" : ""))
        args += ["-filter_complex", filters.joined(separator: ";"), "-map", "[video]"]
        if audio { args += ["-map", "[audio]"] }
        args += ["-c:v", "libx264", "-crf", crf(request.settings.quality), "-pix_fmt", "yuv420p"]
        if audio { args += ["-c:a", "aac", "-b:a", "192k"] }
        let output = stage.appendingPathComponent("joined.mp4")
        args += ["-map_metadata", "-1", "-movflags", "+faststart", output.path]
        try await ProcessRunner.run(executable: ffmpeg, arguments: args)
        return output
    }

    private static func compress(_ input: URL, info: MediaInspection, settings: ToolSettings, ffmpeg: URL, stage: URL, index: Int) async throws -> URL {
        let sourceBytes = try ConversionEngine.byteCount(input)
        let target = settings.targetBytes > 0 ? min(settings.targetBytes, sourceBytes - 1) : sourceBytes - 1
        guard target >= 16_384 else { throw ConversionError.invalidOptions("Media compression needs a target and source larger than 16 KiB.") }
        let output = stage.appendingPathComponent("compressed-\(index).\(info.hasVideo ? "mp4" : "m4a")")
        var bitrate = Int(min(1_000_000_000, Double(target) * 8 / info.duration * 0.90))
        for attempt in 0..<3 {
            try Task.checkCancellation()
            var args = base + localInput(input)
            if info.hasVideo {
                let audioRate = info.hasAudio ? min(128_000, max(32_000, bitrate / 5)) : 0
                let videoRate = bitrate - audioRate
                guard videoRate >= 16_000 else { throw ConversionError.invalidOptions("The requested size is too small for this video's duration.") }
                args += videoEncoding(info: info, quality: settings.quality)
                if settings.targetBytes > 0 || attempt > 0 { args += ["-b:v", "\(videoRate)", "-maxrate", "\(videoRate)", "-bufsize", "\(videoRate * 2)"] }
                if info.hasAudio { args += ["-b:a", "\(audioRate)"] }
            } else {
                guard info.hasAudio, bitrate >= 8_000 else { throw ConversionError.invalidOptions("The requested size is too small for this audio's duration.") }
                let rate = min(bitrate, settings.targetBytes > 0 ? 320_000 : Int(64_000 + settings.quality * 128_000))
                args += ["-vn", "-map", "0:a:0", "-c:a", "aac", "-b:a", "\(rate)"]
            }
            args += ["-map_metadata", "-1", output.path]
            try await ProcessRunner.run(executable: ffmpeg, arguments: args)
            let actual = try ConversionEngine.byteCount(output)
            if actual <= target { return output }
            try FileManager.default.removeItem(at: output)
            bitrate = Int(Double(bitrate) * min(0.85, Double(target) / Double(actual) * 0.90))
        }
        throw ConversionError.conversionFailed("Cannot reach a smaller file at this size target. Increase the target size or choose another source.")
    }

    /// Detect edges separately so pauses inside the recording are preserved and no full-audio reverse buffer is needed.
    private static func audibleEdges(_ input: URL, span: (Double, Double), ffmpeg: URL) async throws -> (Double, Double) {
        let text = try await analysis(input, ffmpeg: ffmpeg, filter: "atrim=start=\(number(span.0)):end=\(number(span.1)),asetpts=PTS-STARTPTS,silencedetect=noise=-50dB:duration=0.1")
        var events: [(start: Bool, time: Double)] = []
        for line in text.split(separator: "\n") {
            let pieces = line.split(separator: "=", maxSplits: 1)
            guard pieces.count == 2, let time = Double(pieces[1]), time.isFinite else { continue }
            if pieces[0] == "lavfi.silence_start" { events.append((true, time)) }
            if pieces[0] == "lavfi.silence_end" { events.append((false, time)) }
        }
        let duration = span.1 - span.0
        var lower = 0.0, upper = duration
        if let first = events.first, first.start, first.time <= 0.02 {
            lower = events.dropFirst().first(where: { !$0.start })?.time ?? duration
        }
        if let last = events.last, last.start { upper = last.time }
        guard upper - lower >= 0.01 else { throw ConversionError.invalidInput("The selected audio contains no audible content above −50 dB for at least 0.01 seconds.") }
        return (span.0 + max(0, lower), span.0 + min(duration, upper))
    }

    private static func levels(_ input: URL, duration: Double, ffmpeg: URL) async throws -> [String: Any] {
        guard duration >= 0.4 else { return ["available": false, "reason": "EBU R128 integration needs at least 0.4 seconds of audio."] }
        let text = try await analysis(input, ffmpeg: ffmpeg, filter: "ebur128=metadata=1:peak=sample+true,aselect='gte(t,\(number(max(0, duration - 0.3))))'")
        var values: [String: Double] = [:]
        let keys = ["lavfi.r128.I": "integratedLUFS", "lavfi.r128.LRA": "loudnessRangeLU", "lavfi.r128.sample_peak": "samplePeakAmplitude", "lavfi.r128.true_peak": "truePeakAmplitude"]
        for line in text.split(separator: "\n") {
            let pair = line.split(separator: "=", maxSplits: 1)
            if pair.count == 2, let key = keys[String(pair[0])], let value = Double(pair[1]), value.isFinite { values[key] = value }
        }
        guard values.count == keys.count else { throw ConversionError.conversionFailed("FFmpeg could not measure complete EBU R128 levels. Audio shorter than 0.1 seconds cannot be measured.") }
        if let peak = values["truePeakAmplitude"], peak > 0 { values["truePeakDBTP"] = 20 * log10(peak) }
        return values.reduce(into: [String: Any]()) { $0[$1.key] = $1.value }
    }

    private static func analysis(_ input: URL, ffmpeg: URL, filter: String) async throws -> String {
        // A generated ASCII path avoids filter-language quoting problems in user-selected paths.
        let directory = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("shiftdrop-analysis-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let report = directory.appendingPathComponent("analysis.txt")
        try await ProcessRunner.run(executable: ffmpeg, arguments: base + localInput(input) + ["-map", "0:a:0", "-vn", "-af", filter + ",ametadata=mode=print:file=" + report.path, "-f", "null", "-"])
        guard (try report.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0 <= 67_108_864 else { throw ConversionError.invalidInput("The audio analysis exceeds its 64 MiB report limit.") }
        return try String(contentsOf: report, encoding: .utf8)
    }

    private static func splitBoundaries(_ s: ToolSettings, duration: Double) throws -> [Double] {
        let custom = s.splitPoints.trimmingCharacters(in: .whitespacesAndNewlines)
        var points: [Double]
        if custom.isEmpty {
            guard (2...32).contains(s.parts) else { throw ConversionError.invalidOptions("Choose 2–32 equal parts or comma-separated custom split times.") }
            points = (0...s.parts).map { duration * Double($0) / Double(s.parts) }
        } else {
            let tokens = custom.split(separator: ",", omittingEmptySubsequences: false)
            guard tokens.count <= 31 else { throw ConversionError.invalidOptions("Choose at most 31 split points, creating at most 32 parts.") }
            let parsed = try tokens.map { token -> Double in
                guard let time = Double(token.trimmingCharacters(in: .whitespacesAndNewlines)), time.isFinite, time > 0, time < duration else { throw ConversionError.invalidOptions("Split times must be seconds strictly between 0 and the media duration.") }
                return time
            }
            points = [0] + parsed + [duration]
        }
        guard zip(points, points.dropFirst()).allSatisfy({ $1 - $0 >= 0.05 }) else { throw ConversionError.invalidOptions("Split points must be increasing, with every part at least 0.05 seconds long.") }
        return points
    }

    private static let base = ["-hide_banner", "-loglevel", "error", "-nostdin", "-n"]
    private static func localInput(_ input: URL) -> [String] { ["-protocol_whitelist", "file,pipe", "-i", input.path] }
    private static let audioEncoding = ["-vn", "-map", "0:a:0", "-c:a", "pcm_f32le"]
    private static func videoEncoding(info: MediaInspection, quality: Double, scale: Bool = true, map: Bool = true) -> [String] {
        var args = map ? ["-map", "0:\(info.videoIndex)", "-map", "0:a:0?"] : []
        args += ["-c:v", "libx264", "-crf", crf(quality), "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart"]
        // Avoid a second -vf overriding an operation's filter. Scale is composed by the caller when needed.
        if scale && (info.width % 2 != 0 || info.height % 2 != 0) { args += ["-s", "\(info.width / 2 * 2)x\(info.height / 2 * 2)"] }
        return args
    }
    private static func crf(_ quality: Double) -> String { String(Int(18 + (1 - quality) * 16)) }
    private static func number(_ value: Double) -> String { String(format: "%.9f", locale: Locale(identifier: "en_US_POSIX"), value) }
    private static func range(_ s: ToolSettings, duration: Double) throws -> (Double, Double) {
        guard s.start.isFinite, s.end.isFinite, s.start >= 0, s.end > s.start, s.start < duration, s.end <= duration + 0.05 else { throw ConversionError.invalidOptions("Choose a start and end inside the media duration (\(number(duration)) seconds).") }
        return (s.start, min(s.end, duration))
    }
    private static func canvas(_ width: Int, _ height: Int) throws {
        guard (2...8192).contains(width), (2...8192).contains(height), width.isMultiple(of: 2), height.isMultiple(of: 2), width * height <= 16_777_216 else { throw ConversionError.invalidOptions("Use even dimensions from 2 to 8,192 pixels, with at most 16 million pixels.") }
    }
    private static func rectangle(_ s: ToolSettings, info: MediaInspection) throws {
        guard s.x >= 0, s.y >= 0, s.width > 0, s.height > 0, s.width <= info.width, s.height <= info.height, s.x <= info.width - s.width, s.y <= info.height - s.height else { throw ConversionError.invalidOptions("The rectangle must fit inside the video's \(info.width) × \(info.height) pixel canvas.") }
    }
    private static func tempo(_ speed: Double) -> String {
        var remaining = speed, filters: [String] = []
        while remaining > 2 { filters.append("atempo=2"); remaining /= 2 }
        while remaining < 0.5 { filters.append("atempo=0.5"); remaining /= 0.5 }
        filters.append("atempo=\(number(remaining))")
        return filters.joined(separator: ",")
    }
    private static func validHex(_ value: String) -> Bool { value.count == 6 && value.allSatisfy { $0.isHexDigit && $0.isASCII } }
}

/// FFprobe writes bounded JSON into task-local staging, avoiding an unbounded stdout pipe.
struct MediaInspection {
    let rawJSON: Data
    let duration: Double
    let hasVideo: Bool
    let videoIndex: Int
    let hasAudio: Bool
    let width: Int
    let height: Int

    static func read(_ input: URL, ffmpeg: URL, stage: URL) async throws -> MediaInspection {
        let sibling = ffmpeg.deletingLastPathComponent().appendingPathComponent("ffprobe")
        let candidates = [sibling] + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { URL(fileURLWithPath: String($0)).appendingPathComponent("ffprobe") }
        guard let ffprobe = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else { throw ConversionError.invalidInput("This media tool also needs ffprobe installed beside FFmpeg or in PATH.") }
        let report = stage.appendingPathComponent("probe-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: report) }
        try await ProcessRunner.run(executable: ffprobe, arguments: ["-v", "error", "-protocol_whitelist", "file,pipe", "-show_format", "-show_streams", "-of", "json", "-o", report.path, input.path])
        guard (try report.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0 <= 2_097_152 else { throw ConversionError.invalidInput("The media metadata report exceeds 2 MiB.") }
        let data = try Data(contentsOf: report)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any], let streams = json["streams"] as? [[String: Any]], let format = json["format"] as? [String: Any] else { throw ConversionError.invalidInput("FFprobe did not return valid media information.") }
        let video = streams.first { $0["codec_type"] as? String == "video" && (($0["disposition"] as? [String: Any])?["attached_pic"] as? Int ?? 0) == 0 }
        let audio = streams.first { $0["codec_type"] as? String == "audio" }
        let duration = Double((video?["duration"] as? String) ?? (audio?["duration"] as? String) ?? (format["duration"] as? String) ?? "") ?? 0
        guard duration.isFinite, duration > 0, duration <= 86_400, video != nil || audio != nil else { throw ConversionError.invalidInput("Choose playable media of at most 24 hours with a known positive duration.") }
        var width = video?["width"] as? Int ?? 0, height = video?["height"] as? Int ?? 0
        let rotation = (video?["side_data_list"] as? [[String: Any]])?.compactMap { $0["rotation"] as? Int }.first ?? 0
        if abs(rotation % 180) == 90 { swap(&width, &height) }
        if video != nil { guard width >= 2, height >= 2, width <= 16384, height <= 16384, width * height <= 80_000_000 else { throw ConversionError.invalidInput("Video dimensions exceed the supported 80-million-pixel canvas.") } }
        return MediaInspection(rawJSON: data, duration: duration, hasVideo: video != nil, videoIndex: video?["index"] as? Int ?? 0, hasAudio: audio != nil, width: width, height: height)
    }
}

private extension Array {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var result: [T] = []
        for element in self { result.append(try await transform(element)) }
        return result
    }
}
