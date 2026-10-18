import XCTest
import Foundation
import ImageIO
import CoreGraphics
@testable import ShiftDropCore

final class MediaToolsTests: XCTestCase {
    private var root: URL!
    private var output: URL!
    private var ffmpeg: URL!

    override func setUpWithError() throws {
        guard let installed = FormatCatalog.ffmpegURL else { throw XCTSkip("FFmpeg is not installed.") }; ffmpeg = installed
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ShiftDropMedia-\(UUID().uuidString)")
        output = root.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { if let root { try FileManager.default.removeItem(at: root) } }

    func testVideoTrimCropSpeedAndPitch() async throws {
        let input = try await video("source", audio: true)
        let original = try Data(contentsOf: input)
        var s = ToolSettings(); s.start = 0.4; s.end = 1.4
        let trimmed = try await run(.trimVideo, [input], s).outputURLs[0]
        let trimmedInfo = try await inspect(trimmed)
        XCTAssertEqual(trimmedInfo.duration, 1, accuracy: 0.12)
        s.x = 8; s.y = 8; s.width = 40; s.height = 24
        let cropped = try await run(.cropVideo, [input], s).outputURLs[0]
        let crop = try await inspect(cropped)
        XCTAssertEqual(crop.width, 40); XCTAssertEqual(crop.height, 24)
        s.speed = 2
        let fast = try await run(.videoSpeed, [input], s).outputURLs[0]
        let fastInfo = try await inspect(fast)
        XCTAssertEqual(fastInfo.duration, 1, accuracy: 0.12); XCTAssertTrue(fastInfo.hasAudio)
        let audio = try await samples(fast)
        XCTAssertEqual(frequency(audio, channel: 0, start: 0.15, end: 0.75), 440, accuracy: 12)
        XCTAssertEqual(try Data(contentsOf: input), original)
        try clean()
    }

    func testJoiningDifferentCanvasesWithAndWithoutAudio() async throws {
        let first = try await video("wide", audio: true, duration: 0.6)
        let second = try await video("tall", audio: false, width: 64, height: 96, duration: 0.6)
        let joined = try await run(.joinVideo, [first, second]).outputURLs[0]
        let info = try await inspect(joined)
        XCTAssertEqual(info.width, 96); XCTAssertEqual(info.height, 64)
        XCTAssertEqual(info.duration, 1.2, accuracy: 0.12); XCTAssertTrue(info.hasAudio)
        let audio = try await samples(joined)
        XCTAssertGreaterThan(rms(audio, channel: 0, start: 0.1, end: 0.4), 0.01)
        XCTAssertLessThan(rms(audio, channel: 0, start: 0.85, end: 1.05), 0.001)
        let silent = try await run(.joinVideo, [second, second]).outputURLs[0]
        let silentInfo = try await inspect(silent)
        XCTAssertFalse(silentInfo.hasAudio)
        try clean()
    }

    func testFramesSplitsAndTimedSolidAndBlurRedaction() async throws {
        let input = try await video("red", audio: false, duration: 1, solid: true)
        var s = ToolSettings(); s.start = 0; s.end = 1; s.parts = 3
        let frames = try await run(.videoFrames, [input], s)
        XCTAssertEqual(frames.outputURLs.count, 3)
        for frame in frames.outputURLs { XCTAssertEqual(try image(frame).width, 96) }
        s.parts = 2
        let split = try await run(.splitVideo, [input], s)
        XCTAssertEqual(split.outputURLs.count, 2)
        for part in split.outputURLs { let info = try await inspect(part); XCTAssertEqual(info.duration, 0.5, accuracy: 0.11) }
        s.x = 16; s.y = 16; s.width = 32; s.height = 24
        s.limitTimeRange = true; s.start = 0.25; s.end = 0.75; s.colorHex = "0000FF"
        let redacted = try await run(.redactVideo, [input], s).outputURLs[0]
        let before = try await frame(redacted, at: 0.1)
        let during = try await frame(redacted, at: 0.5)
        XCTAssertGreaterThan(try pixel(before, x: 24, y: 24)[0], 200)
        XCTAssertLessThan(try pixel(during, x: 24, y: 24)[0], 15)
        XCTAssertGreaterThan(try pixel(during, x: 24, y: 24)[2], 200)
        XCTAssertGreaterThan(try pixel(during, x: 4, y: 4)[0], 200)
        let patterned = try await video("pattern", audio: false, duration: 1)
        s.blur = true
        let blurred = try await run(.redactVideo, [patterned], s).outputURLs[0]
        let blurredInfo = try await inspect(blurred)
        XCTAssertEqual(blurredInfo.duration, 1, accuracy: 0.1)
        try clean()
    }

    func testAudioTrimIndependentGainsBleepNormalizationAndVisualizers() async throws {
        let input = try await audio()
        var s = ToolSettings(); s.start = 0.25; s.end = 1.25
        let trimmed = try await run(.trimAudio, [input], s).outputURLs[0]
        let trimmedInfo = try await inspect(trimmed)
        XCTAssertEqual(trimmedInfo.duration, 1, accuracy: 0.03)
        s.channels = 2; s.leftGain = 0; s.rightGain = 2
        let gained = try await run(.audioChannels, [input], s).outputURLs[0]
        let gainedAudio = try await samples(gained)
        XCTAssertLessThan(rms(gainedAudio, channel: 0, start: 0.2, end: 0.8), 0.00001)
        XCTAssertEqual(rms(gainedAudio, channel: 1, start: 0.2, end: 0.8), 0.25 / sqrt(2), accuracy: 0.003)
        s.start = 0.5; s.end = 1
        let bleep = try await run(.bleepAudio, [input], s).outputURLs[0]
        let bleepAudio = try await samples(bleep)
        XCTAssertEqual(frequency(bleepAudio, channel: 0, start: 0.1, end: 0.4), 440, accuracy: 8)
        XCTAssertEqual(frequency(bleepAudio, channel: 0, start: 0.6, end: 0.9), 1000, accuracy: 8)
        let normalizedResult = try await run(.normalizeAudio, [input], s)
        let normalized = normalizedResult.outputURLs[0]
        XCTAssertEqual(normalizedResult.outputURLs.count, 2)
        let report = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: normalizedResult.outputURLs[1])) as? [String: Any])
        let outputLevels = try XCTUnwrap(report["output"] as? [String: Double])
        XCTAssertEqual(try XCTUnwrap(outputLevels["integratedLUFS"]), -16, accuracy: 1)
        XCTAssertLessThanOrEqual(try XCTUnwrap(outputLevels["truePeakDBTP"]), -1.2)
        let shortInput = root.appendingPathComponent("short.wav")
        try await ProcessRunner.run(executable: ffmpeg, arguments: ["-hide_banner", "-loglevel", "error", "-nostdin", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=0.2", "-c:a", "pcm_f32le", shortInput.path])
        let shortResult = try await run(.normalizeAudio, [shortInput], s)
        let shortReport = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: shortResult.outputURLs[1])) as? [String: Any])
        XCTAssertEqual((shortReport["output"] as? [String: Any])?["available"] as? Bool, false)
        let normalizedAudio = try await samples(normalized)
        XCTAssertTrue(normalizedAudio.allSatisfy { $0.isFinite && abs($0) <= 0.85 })
        s.width = 320; s.height = 180; s.backgroundHex = "00FF00"; s.colorHex = "FFFFFF"
        for waveform in [true, false] {
            s.waveform = waveform
            let visualizer = try await run(.audioVisualizer, [input], s).outputURLs[0]
            let info = try await inspect(visualizer)
            XCTAssertEqual(info.width, 320); XCTAssertEqual(info.height, 180)
            XCTAssertTrue(info.hasVideo && info.hasAudio)
            XCTAssertEqual(info.duration, 2, accuracy: 0.15)
            let picture = try await frame(visualizer, at: 0.2)
            let corner = try pixel(picture, x: 4, y: 4)
            XCTAssertLessThan(corner[0], 15); XCTAssertGreaterThan(corner[1], 230); XCTAssertLessThan(corner[2], 15)
            let bright = try brightPixels(picture)
            if waveform { XCTAssertGreaterThan(bright, 100) } else { XCTAssertEqual(bright, 0) }
        }
        try clean()
    }

    func testEdgeSilencePreservesInternalPausesAndCustomSplitPoints() async throws {
        let input = root.appendingPathComponent("pauses.wav")
        try await ProcessRunner.run(executable: ffmpeg, arguments: ["-hide_banner", "-loglevel", "error", "-nostdin", "-f", "lavfi", "-i", "aevalsrc='if(lt(t,0.2)+gte(t,1.8)+between(t,0.8,1.1),0,0.25*sin(2*PI*440*t))':s=48000:d=2", "-c:a", "pcm_f32le", input.path])
        var s = ToolSettings(); s.start = 0; s.end = 2; s.removeSilence = true
        for tool in [FileTool.trimAudio, .normalizeAudio] {
            let result = try await run(tool, [input], s)
            let info = try await inspect(result.outputURLs[0])
            XCTAssertEqual(info.duration, 1.6, accuracy: 0.04)
            let decoded = try await samples(result.outputURLs[0])
            XCTAssertLessThan(rms(decoded, channel: 0, start: 0.65, end: 0.85), 0.00001)
            XCTAssertGreaterThan(rms(decoded, channel: 0, start: 0.1, end: 0.3), 0.01)
        }
        let clip = try await video("split", audio: false, duration: 1)
        s.splitPoints = "0.2, 0.7"
        let result = try await run(.splitVideo, [clip], s)
        XCTAssertEqual(result.outputURLs.count, 3)
        for (file, duration) in zip(result.outputURLs, [0.2, 0.5, 0.3]) {
            let info = try await inspect(file)
            XCTAssertEqual(info.duration, duration, accuracy: 0.06)
        }
        s.splitPoints = "0.7,0.2"
        do { _ = try await run(.splitVideo, [clip], s); XCTFail("Expected increasing points validation") } catch { XCTAssertTrue(error.localizedDescription.contains("increasing")) }
        s.waveform = false; s.width = 96; s.height = 64; s.backgroundImage = try await frame(clip, at: 0.2)
        let visualizer = try await run(.audioVisualizer, [input], s).outputURLs[0]
        let still = try await frame(visualizer, at: 0.2)
        let expected = try pixel(s.backgroundImage!, x: 4, y: 4)
        let actual = try pixel(still, x: 4, y: 4)
        for channel in 0..<3 { XCTAssertEqual(Int(actual[channel]), Int(expected[channel]), accuracy: 20) }
        try clean()
    }

    func testMetadataCompressionCollisionSafetyAndValidation() async throws {
        let input = try await audio()
        let original = try Data(contentsOf: input)
        var s = ToolSettings(); s.removeMetadata = false
        let report = try await run(.metadata, [input], s).outputURLs[0]
        XCTAssertTrue(try String(contentsOf: report).contains("Secret title"))
        s.removeMetadata = true
        let cleaned = try await run(.metadata, [input], s).outputURLs[0]
        let cleanedInfo = try await inspect(cleaned)
        XCTAssertFalse(String(decoding: cleanedInfo.rawJSON, as: UTF8.self).contains("Secret title"))
        s.targetBytes = 32_000
        let compressed = try await run(.compress, [input], s).outputURLs[0]
        XCTAssertLessThanOrEqual(try ConversionEngine.byteCount(compressed), 32_000)
        let compressedInfo = try await inspect(compressed)
        XCTAssertTrue(compressedInfo.hasAudio)
        let sentinel = output.appendingPathComponent("source-trimAudio.wav")
        try Data("existing output".utf8).write(to: sentinel)
        s.start = 0; s.end = 1
        _ = try await run(.trimAudio, [input], s)
        XCTAssertEqual(try String(contentsOf: sentinel), "existing output")
        s.end = 20
        do { _ = try await run(.trimAudio, [input], s); XCTFail("Expected invalid time range") }
        catch { XCTAssertTrue(error.localizedDescription.contains("duration")) }
        s.loudness = 100
        do { _ = try await run(.normalizeAudio, [input], s); XCTFail("Expected invalid normalization") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Loudness")) }
        let cancelled = Task { withUnsafeCurrentTask { $0?.cancel() }; return try await self.run(.metadata, [input], s) }
        do { _ = try await cancelled.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(try Data(contentsOf: input), original)
        try clean()
    }

    private func run(_ tool: FileTool, _ inputs: [URL], _ settings: ToolSettings = ToolSettings()) async throws -> ConversionResult {
        try await MediaTools.run(ToolRequest(tool: tool, inputs: inputs, outputDirectory: output, settings: settings))
    }
    private func inspect(_ input: URL) async throws -> MediaInspection { try await MediaInspection.read(input, ffmpeg: ffmpeg, stage: root) }
    private func video(_ name: String, audio: Bool, width: Int = 96, height: Int = 64, duration: Double = 2, solid: Bool = false) async throws -> URL {
        let destination = root.appendingPathComponent(name + ".mp4")
        let source = solid ? "color=c=red:s=\(width)x\(height):r=20:d=\(duration)" : "testsrc2=size=\(width)x\(height):rate=20:duration=\(duration)"
        var args = ["-hide_banner", "-loglevel", "error", "-nostdin", "-f", "lavfi", "-i", source]
        if audio { args += ["-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=\(duration)"] }
        args += ["-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", destination.path]
        try await ProcessRunner.run(executable: ffmpeg, arguments: args)
        return destination
    }
    private func audio() async throws -> URL {
        let destination = root.appendingPathComponent("source.wav")
        try await ProcessRunner.run(executable: ffmpeg, arguments: ["-hide_banner", "-loglevel", "error", "-nostdin", "-f", "lavfi", "-i", "aevalsrc=0.25*sin(2*PI*440*t)|0.125*sin(2*PI*880*t):s=48000:d=2", "-c:a", "pcm_f32le", "-metadata", "title=Secret title", destination.path])
        return destination
    }
    private func samples(_ input: URL) async throws -> [Float] {
        let raw = root.appendingPathComponent(UUID().uuidString + ".f32")
        try await ProcessRunner.run(executable: ffmpeg, arguments: ["-hide_banner", "-loglevel", "error", "-nostdin", "-i", input.path, "-vn", "-ar", "48000", "-ac", "2", "-c:a", "pcm_f32le", "-f", "f32le", raw.path])
        let data = try Data(contentsOf: raw)
        return data.withUnsafeBytes { bytes in (0..<(bytes.count / 4)).map { bytes.loadUnaligned(fromByteOffset: $0 * 4, as: Float.self) } }
    }
    private func rms(_ values: [Float], channel: Int, start: Double, end: Double) -> Double {
        let lower = Int(start * 48000), upper = min(Int(end * 48000), values.count / 2)
        guard upper > lower else { return 0 }
        return sqrt((lower..<upper).reduce(0) { $0 + pow(Double(values[$1 * 2 + channel]), 2) } / Double(upper - lower))
    }
    private func frequency(_ values: [Float], channel: Int, start: Double, end: Double) -> Double {
        let lower = max(1, Int(start * 48000)), upper = min(Int(end * 48000), values.count / 2)
        guard upper > lower else { return 0 }
        let crossings = (lower..<upper).filter { values[($0 - 1) * 2 + channel] <= 0 && values[$0 * 2 + channel] > 0 }.count
        return Double(crossings) * 48000 / Double(upper - lower)
    }
    private func frame(_ input: URL, at time: Double) async throws -> URL {
        var s = ToolSettings(); s.parts = 1; s.start = time; s.end = time + 0.05
        return try await run(.videoFrames, [input], s).outputURLs[0]
    }
    private func image(_ input: URL) throws -> CGImage {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(input as CFURL, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }
    private func pixel(_ input: URL, x: Int, y: Int) throws -> [UInt8] {
        let image = try image(input)
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let pointer = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        return (0..<3).map { pointer[(y * image.width + x) * 4 + $0] }
    }
    private func brightPixels(_ input: URL) throws -> Int {
        let image = try image(input)
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let pointer = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        return (0..<(image.width * image.height)).filter { pointer[$0 * 4] > 180 && pointer[$0 * 4 + 1] > 180 && pointer[$0 * 4 + 2] > 180 }.count
    }
    private func clean() throws {
        if FileManager.default.fileExists(atPath: output.path) { XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: output.path).contains { $0.hasPrefix(".shiftdrop-") }) }
    }
}
