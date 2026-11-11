import Foundation
import CoreFoundation

/// The same filename, language and legacy-encoding rules as Android's SubtitleFiles.
public enum ExternalSubtitleFormat {
    public static let extensions = ["srt", "smi", "sami", "ass", "ssa", "vtt"]

    public static func matching(videoName: String, names: [String]) -> [String] {
        let video = videoName.lowercased()
        let base = (video as NSString).deletingPathExtension
        func language(_ name: String) -> String? {
            let stem = (name.lowercased() as NSString).deletingPathExtension
            if stem == base || stem == video { return "" }
            for prefix in [video + ".", base + ".", base + "_", base + "-"] where stem.hasPrefix(prefix) {
                let suffix = String(stem.dropFirst(prefix.count))
                if suffix.range(of: #"^(ko(?:[-_]kr)?|kor|kr|korean|한국어|한글|en(?:[-_]us)?|eng|english|ja|jpn|zh|chi)(?:[._-](?:forced|sdh|cc))?$"#, options: .regularExpression) != nil {
                    return suffix
                }
            }
            return nil
        }
        func priority(_ name: String) -> Int {
            let lang = language(name) ?? ""
            if lang.hasPrefix("ko") || lang == "kr" || lang == "한국어" || lang == "한글" { return 0 }
            return lang.isEmpty ? 1 : 2
        }
        return names.filter { extensions.contains(($0 as NSString).pathExtension.lowercased()) && language($0) != nil }
            .sorted {
                let a = priority($0), b = priority($1)
                if a != b { return a < b }
                let ae = extensions.firstIndex(of: ($0 as NSString).pathExtension.lowercased()) ?? 99
                let be = extensions.firstIndex(of: ($1 as NSString).pathExtension.lowercased()) ?? 99
                return ae == be ? $0 < $1 : ae < be
            }
    }

    public static func decode(_ data: Data) throws -> String {
        guard data.count <= SubtitleTrack.maximumBytes else { throw SubtitleError.tooLarge }
        let text: String?
        if data.starts(with: [0xff, 0xfe]) {
            guard data.count.isMultiple(of: 2) else { throw SubtitleError.invalidEncoding }
            text = String(data: data.dropFirst(2), encoding: .utf16LittleEndian)
        } else if data.starts(with: [0xfe, 0xff]) {
            guard data.count.isMultiple(of: 2) else { throw SubtitleError.invalidEncoding }
            text = String(data: data.dropFirst(2), encoding: .utf16BigEndian)
        } else if let utf8 = String(data: data, encoding: .utf8) { text = utf8 }
        else {
            let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosKorean.rawValue)))
            text = String(data: data, encoding: encoding)
        }
        guard var text else { throw SubtitleError.invalidEncoding }
        guard !text.contains("\0") else { throw SubtitleError.invalidFormat }
        if text.first == "\u{FEFF}" { text.removeFirst() }
        return text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    static func prepare(data: Data, filename: String?) throws -> String {
        let source = try decode(data)
        let ext = ((filename ?? "") as NSString).pathExtension.lowercased()
        let prefix = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if ["smi", "sami"].contains(ext) || prefix.range(of: "<sami", options: .caseInsensitive) != nil {
            return try sami(source)
        }
        if ["ass", "ssa"].contains(ext) || source.contains("[Events]") { return try ass(source) }
        if ext == "vtt" || prefix.hasPrefix("WEBVTT") { return try vtt(source) }
        return source
    }

    private static func matches(_ pattern: String, _ text: String) -> [NSTextCheckingResult] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
    }
    private static func group(_ match: NSTextCheckingResult, _ index: Int, _ source: String) -> String {
        guard index < match.numberOfRanges, let range = Range(match.range(at: index), in: source) else { return "" }
        return String(source[range])
    }
    private static func replace(_ source: String, _ pattern: String, _ value: String) -> String {
        source.replacingOccurrences(of: pattern, with: value, options: .regularExpression)
    }

    /// Only text is interpreted. No HTML rendering, scripts, network requests or attached fonts.
    static func plainText(_ source: String) -> String {
        var text = replace(source, #"(?is)<(?:style|script)\b[^>]*>.*?</(?:style|script)>"#, "")
        text = replace(text, #"(?i)<br\s*/?>"#, "\n")
        text = replace(text, #"<[^>]+>"#, "")
        for (entity, replacement) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&apos;", "'"), ("&amp;", "&")] {
            text = text.replacingOccurrences(of: entity, with: replacement, options: .caseInsensitive)
        }
        for match in matches(#"&#(x[0-9a-fA-F]+|[0-9]+);"#, text).reversed() {
            let token = group(match, 1, text)
            let value = token.hasPrefix("x") ? UInt32(token.dropFirst(), radix: 16) : UInt32(token)
            if let value, let scalar = Unicode.Scalar(value), value > 0, let range = Range(match.range, in: text) {
                text.replaceSubrange(range, with: String(scalar))
            }
        }
        return text
    }

    private static func time(_ milliseconds: Int) -> String {
        String(format: "%02d:%02d:%02d,%03d", milliseconds / 3_600_000,
               milliseconds / 60_000 % 60, milliseconds / 1_000 % 60, milliseconds % 1_000)
    }

    private static func sami(_ input: String) throws -> String {
        let text = replace(input, #"(?s)<!--.*?-->"#, "")
        let syncs = matches(#"(?i)<sync\b[^>]*\bstart\s*=\s*["']?(\d+)[^>]*>"#, text)
        guard !syncs.isEmpty, syncs.count <= SubtitleTrack.maximumCues * 2 else { throw SubtitleError.invalidFormat }
        let paragraphPattern = #"(?i)<p\b([^>]*)>"#
        func className(_ attrs: String) -> String? {
            matches(#"(?i)\bclass\s*=\s*["']?([^\s"'>]+)"#, attrs).first.map { group($0, 1, attrs).lowercased() }
        }
        let classes = matches(paragraphPattern, text).compactMap { className(group($0, 1, text)) }
        let css = matches(#"(?is)\.([\w-]+)\s*\{[^}]*\blang\s*:\s*ko(?:-kr)?\b"#, input).first.map { group($0, 1, input).lowercased() }
        let selected = css.flatMap { classes.contains($0) ? $0 : nil } ?? classes.first { $0.hasPrefix("kr") || $0.hasPrefix("ko") } ?? classes.first
        var events: [(Int, String)] = []
        for (index, sync) in syncs.enumerated() {
            guard let start = Int(group(sync, 1, text)), (0...604_800_000).contains(start) else { continue }
            let end = index + 1 < syncs.count ? syncs[index + 1].range.location : (text as NSString).length
            let body = (text as NSString).substring(with: NSRange(location: NSMaxRange(sync.range), length: end - NSMaxRange(sync.range)))
            let paragraphs = matches(paragraphPattern, body)
            var parts: [String] = []
            if paragraphs.isEmpty { parts = [body] }
            for (j, paragraph) in paragraphs.enumerated() {
                let language = className(group(paragraph, 1, body))
                if let selected, let language, selected != language { continue }
                let end = j + 1 < paragraphs.count ? paragraphs[j + 1].range.location : (body as NSString).length
                parts.append((body as NSString).substring(with: NSRange(location: NSMaxRange(paragraph.range), length: end - NSMaxRange(paragraph.range))))
            }
            if parts.isEmpty { continue }
            let line = plainText(parts.joined(separator: "\n")).components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: "\n")
            events.append((start, line))
        }
        var seen: Set<Int> = []
        events = events.filter { seen.insert($0.0).inserted }.sorted { $0.0 < $1.0 }
        let blocks = events.enumerated().compactMap { index, event -> String? in
            guard !event.1.isEmpty else { return nil }
            let end = index + 1 < events.count ? events[index + 1].0 : event.0 + 5_000
            guard end > event.0 else { return nil }
            return "\(time(event.0)) --> \(time(end))\n\(event.1)"
        }
        guard !blocks.isEmpty else { throw SubtitleError.invalidFormat }
        return blocks.joined(separator: "\n\n")
    }

    private static func vtt(_ source: String) throws -> String {
        let blocks = source.components(separatedBy: "\n\n")
        var converted: [String] = []
        for block in blocks {
            let lines = block.components(separatedBy: "\n")
            if let first = lines.first, first.hasPrefix("NOTE") || first == "STYLE" || first == "REGION" { continue }
            guard let index = lines.firstIndex(where: { $0.contains("-->") }), lines.count > index + 1 else { continue }
            let timing = lines[index].components(separatedBy: "-->")
            guard timing.count == 2 else { throw SubtitleError.invalidTimestamp }
            func normalize(_ part: String) -> String {
                let stamp = part.trimmingCharacters(in: .whitespaces).split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
                return stamp.filter { $0 == ":" }.count == 1 ? "00:" + stamp : stamp
            }
            converted.append(normalize(timing[0]) + " --> " + normalize(timing[1]) + "\n" + lines[(index + 1)...].joined(separator: "\n"))
        }
        guard !converted.isEmpty else { throw SubtitleError.invalidFormat }
        return converted.joined(separator: "\n\n")
    }

    // ASS/SSA event text and timing. Advanced drawing/animation styles require a bitmap renderer.
    private static func ass(_ source: String) throws -> String {
        var fields = ["layer", "start", "end", "style", "name", "marginl", "marginr", "marginv", "effect", "text"]
        var inside = false
        var blocks: [String] = []
        for raw in source.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { inside = line.lowercased() == "[events]"; continue }
            guard inside else { continue }
            if line.lowercased().hasPrefix("format:") {
                fields = line.dropFirst(7).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                guard (3...64).contains(fields.count) else { throw SubtitleError.invalidFormat }
            } else if line.lowercased().hasPrefix("dialogue:") {
                guard fields.last == "text", let si = fields.firstIndex(of: "start"), let ei = fields.firstIndex(of: "end") else { throw SubtitleError.invalidFormat }
                let values = line.dropFirst(9).split(separator: ",", maxSplits: fields.count - 1, omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
                guard values.count == fields.count else { throw SubtitleError.invalidFormat }
                let text = replace(values.last!, #"\{[^}]*\}"#, "").replacingOccurrences(of: "\\N", with: "\n")
                    .replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\h", with: " ")
                guard !text.isEmpty else { continue }
                blocks.append(values[si] + " --> " + values[ei] + "\n" + text)
                guard blocks.count <= SubtitleTrack.maximumCues else { throw SubtitleError.tooManyCues }
            }
        }
        guard !blocks.isEmpty else { throw SubtitleError.invalidFormat }
        return blocks.joined(separator: "\n\n")
    }
}
