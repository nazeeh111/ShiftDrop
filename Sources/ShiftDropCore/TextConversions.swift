import Foundation
import AppKit

enum TextConversions {
    static func convert(_ input: URL, destination: URL, format: ConversionFormat) throws {
        let size = try input.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 32 * 1024 * 1024 else { throw ConversionError.invalidInput("Text imports are limited to 32 MB.") }
        let data = try Data(contentsOf: input)
        try Task.checkCancellation()
        let ext = input.pathExtension.lowercased()
        if ext == "srt" || ext == "vtt" {
            let cues = try SubtitleDocument.parse(try decode(data), webVTT: ext == "vtt")
            let output: String
            if format == .txt { output = cues.map { HTMLText.plain($0.text) }.joined(separator: "\n\n") }
            else { output = SubtitleDocument.serialize(cues, webVTT: format == .vtt) }
            try Data(output.utf8).write(to: destination)
            return
        }
        let plain: String
        if ext == "rtf" {
            do { plain = try NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil).string }
            catch { throw ConversionError.invalidInput("The RTF document is damaged.") }
        } else if ext == "html" || ext == "htm" { plain = HTMLText.plain(try decode(data)) }
        else { plain = try decode(data) }
        try Task.checkCancellation()
        switch format {
        case .txt: try Data(plain.utf8).write(to: destination)
        case .html:
            let escaped = plain.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            let html = "<!doctype html>\n<html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\"><title>Converted document</title></head><body><pre style=\"white-space:pre-wrap;font:1rem/1.6 system-ui,sans-serif\">\(escaped)</pre></body></html>\n"
            try Data(html.utf8).write(to: destination)
        case .rtf:
            let attributed = NSAttributedString(string: plain)
            let rtf = try attributed.data(from: NSRange(location: 0, length: attributed.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
            try rtf.write(to: destination)
        default: throw ConversionError.unsupported("This text output format is unavailable.")
        }
    }

    static func decode(_ data: Data) throws -> String {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]), let value = String(data: data, encoding: .utf16) { return value }
        if let value = String(data: data, encoding: .utf8) { return value.trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}")) }
        throw ConversionError.invalidInput("Save this text file as UTF-8 or UTF-16 before converting.")
    }
}

struct SubtitleCue {
    let start: Int64
    let end: Int64
    let text: String
    let settings: String
}

enum SubtitleDocument {
    static func parse(_ source: String, webVTT: Bool) throws -> [SubtitleCue] {
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let blocks = normalized.components(separatedBy: try! NSRegularExpression(pattern: "\\n[ \\t]*\\n+"))
        var cues: [SubtitleCue] = []
        var startBlock = 0
        if webVTT {
            guard let header = blocks.first?.components(separatedBy: "\n").first,
                  header == "WEBVTT" || header.hasPrefix("WEBVTT ") || header.hasPrefix("WEBVTT\t") else {
                throw ConversionError.invalidInput("A VTT subtitle must begin with WEBVTT.")
            }
            startBlock = 1
        }
        for block in blocks.dropFirst(startBlock) {
            try Task.checkCancellation()
            let lines = block.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
            guard let first = lines.first, !first.isEmpty else { continue }
            if webVTT && (first == "NOTE" || first.hasPrefix("NOTE ") || first == "STYLE" || first == "REGION") { continue }
            let timingIndex = first.contains("-->") ? 0 : 1
            guard lines.count > timingIndex + 1 else { throw malformed(cues.count + 1) }
            let halves = lines[timingIndex].components(separatedBy: "-->")
            guard halves.count == 2 else { throw malformed(cues.count + 1) }
            let endParts = halves[1].trimmingCharacters(in: .whitespaces).split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" })
            guard let endToken = endParts.first,
                  let start = timestamp(halves[0].trimmingCharacters(in: .whitespaces), webVTT: webVTT),
                  let end = timestamp(String(endToken), webVTT: webVTT), end > start else { throw malformed(cues.count + 1) }
            let payload = lines.dropFirst(timingIndex + 1).joined(separator: "\n")
            guard !payload.isEmpty else { throw malformed(cues.count + 1) }
            cues.append(SubtitleCue(start: start, end: end, text: payload, settings: endParts.count > 1 ? String(endParts[1]) : ""))
        }
        guard !cues.isEmpty else { throw ConversionError.invalidInput("No subtitle cues were found.") }
        return cues
    }

    private static func malformed(_ cue: Int) -> ConversionError {
        .invalidInput("Subtitle cue \(cue) is malformed. Use valid start/end timestamps and nonempty text.")
    }

    private static func timestamp(_ value: String, webVTT: Bool) -> Int64? {
        let pattern = webVTT ? "^(?:(\\d{2,6}):)?([0-5]\\d):([0-5]\\d)\\.(\\d{3})$" : "^(\\d{2,6}):([0-5]\\d):([0-5]\\d),(\\d{3})$"
        let regex = try! NSRegularExpression(pattern: pattern)
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard let match = regex.firstMatch(in: value, range: range) else { return nil }
        func number(_ group: Int) -> Int64 {
            guard let range = Range(match.range(at: group), in: value) else { return 0 }
            return Int64(value[range]) ?? 0
        }
        return ((number(1) * 60 + number(2)) * 60 + number(3)) * 1000 + number(4)
    }

    static func serialize(_ cues: [SubtitleCue], webVTT: Bool) -> String {
        func time(_ value: Int64) -> String {
            String(format: "%02lld:%02lld:%02lld%@%03lld", value / 3_600_000, value / 60_000 % 60, value / 1000 % 60, webVTT ? "." : ",", value % 1000)
        }
        let blocks = cues.enumerated().map { index, cue in
            let number = webVTT ? "" : "\(index + 1)\n"
            let settings = webVTT && !cue.settings.isEmpty ? " " + cue.settings : ""
            return "\(number)\(time(cue.start)) --> \(time(cue.end))\(settings)\n\(cue.text)"
        }
        return (webVTT ? "WEBVTT\n\n" : "") + blocks.joined(separator: "\n\n") + "\n"
    }
}

private extension String {
    func components(separatedBy regex: NSRegularExpression) -> [String] {
        let source = self as NSString
        var result: [String] = []
        var offset = 0
        for match in regex.matches(in: self, range: NSRange(location: 0, length: source.length)) {
            result.append(source.substring(with: NSRange(location: offset, length: match.range.location - offset)))
            offset = NSMaxRange(match.range)
        }
        result.append(source.substring(from: offset))
        return result
    }
}

enum HTMLText {
    // Deliberately offline: no web view, network requests, script execution, or external resources.
    static func plain(_ source: String) -> String {
        var text = source.replacingOccurrences(of: "(?is)<!--.*?-->|<(script|style|head)\\b[^>]*>.*?</\\1\\s*>", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?i)<(?:br\\s*/?|/p|/div|/h[1-6]|/li|/tr|/pre)\\s*>", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
        let entities = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "copy": "©", "reg": "®", "ndash": "–", "mdash": "—", "hellip": "…"]
        let regex = try! NSRegularExpression(pattern: "&(#x[0-9A-Fa-f]+|#[0-9]+|[A-Za-z]+);")
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let tokenRange = Range(match.range(at: 1), in: text), let fullRange = Range(match.range, in: text) else { continue }
            let token = String(text[tokenRange])
            var replacement = entities[token]
            if token.hasPrefix("#x"), let code = UInt32(token.dropFirst(2), radix: 16), let scalar = UnicodeScalar(code) { replacement = String(scalar) }
            else if token.hasPrefix("#"), let code = UInt32(token.dropFirst()), let scalar = UnicodeScalar(code) { replacement = String(scalar) }
            if let replacement { text.replaceSubrange(fullRange, with: replacement) }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
