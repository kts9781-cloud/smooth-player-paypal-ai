import Foundation

public struct SubtitleCue: Equatable, Sendable {
    public let start: Double
    public let end: Double
    public let text: String
}

public enum SubtitleError: Error, Equatable, LocalizedError {
    case tooLarge
    case invalidEncoding
    case invalidFormat
    case invalidTimestamp
    case invalidInterval
    case tooManyCues
    case textTooLong

    public var errorDescription: String? {
        switch self {
        case .tooLarge: return SPText("자막 파일은 8 MB 이하로 선택해 주세요.")
        case .invalidEncoding: return SPText("자막의 문자 인코딩을 읽지 못했습니다. UTF-8·UTF-16·한국어(CP949) 파일을 지원합니다.")
        case .invalidFormat: return SPText("자막 형식을 읽을 수 없습니다. SRT·SMI·ASS·SSA·VTT 파일을 선택해 주세요.")
        case .invalidTimestamp, .invalidInterval: return SPText("자막의 표시 시간이 올바르지 않습니다.")
        case .tooManyCues, .textTooLong: return SPText("자막에 너무 많은 내용이 포함되어 있습니다.")
        }
    }
}

public struct SubtitleTrack: Sendable {
    public static let maximumBytes = 8 * 1_024 * 1_024
    public static let maximumCues = 20_000
    public static let maximumCueCharacters = 4_096

    public let cues: [SubtitleCue]
    private let prefixMaximumEnds: [Double]

    public static func parse(data: Data, filename: String? = nil) throws -> SubtitleTrack {
        guard data.count <= maximumBytes else { throw SubtitleError.tooLarge }
        let source = try ExternalSubtitleFormat.prepare(data: data, filename: filename)
        var parsed: [SubtitleCue] = []
        var block: [String] = []
        for line in source.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if !block.isEmpty {
                    guard parsed.count < maximumCues else { throw SubtitleError.tooManyCues }
                    parsed.append(try parseBlock(block))
                    block.removeAll(keepingCapacity: true)
                }
            } else {
                block.append(line)
            }
        }
        if !block.isEmpty {
            guard parsed.count < maximumCues else { throw SubtitleError.tooManyCues }
            parsed.append(try parseBlock(block))
        }
        guard !parsed.isEmpty else { throw SubtitleError.invalidFormat }
        // Preserve input order for simultaneous cues, even when the SRT is unsorted.
        let sorted = parsed.enumerated().sorted {
            $0.element.start == $1.element.start ? $0.offset < $1.offset : $0.element.start < $1.element.start
        }.map(\.element)
        var maximumEnd = 0.0
        let ends = sorted.map { cue in
            maximumEnd = max(maximumEnd, cue.end)
            return maximumEnd
        }
        return SubtitleTrack(cues: sorted, prefixMaximumEnds: ends)
    }

    /// Cues include their start time and exclude their end time. Overlaps are joined
    /// in start-time order, with original input order breaking equal-start ties.
    public func text(at time: Double) -> String? {
        guard time.isFinite, time >= 0, !cues.isEmpty else { return nil }
        var low = 0
        var high = cues.count
        while low < high {
            let middle = low + (high - low) / 2
            if cues[middle].start <= time { low = middle + 1 } else { high = middle }
        }
        var index = low - 1
        var active: [String] = []
        while index >= 0, prefixMaximumEnds[index] > time {
            if cues[index].end > time { active.append(cues[index].text) }
            index -= 1
        }
        return active.isEmpty ? nil : active.reversed().joined(separator: "\n")
    }

    private static func parseBlock(_ lines: [String]) throws -> SubtitleCue {
        let first = lines[0].trimmingCharacters(in: .whitespaces)
        let timingIndex = isASCIIDigits(first) ? 1 : 0
        guard lines.count > timingIndex + 1 else { throw SubtitleError.invalidFormat }
        let timing = lines[timingIndex].components(separatedBy: "-->")
        guard timing.count == 2 else { throw SubtitleError.invalidFormat }
        let start = try timestamp(timing[0].trimmingCharacters(in: .whitespaces))
        let end = try timestamp(timing[1].trimmingCharacters(in: .whitespaces))
        guard end > start else { throw SubtitleError.invalidInterval }
        let text = ExternalSubtitleFormat.plainText(lines[(timingIndex + 1)...].joined(separator: "\n"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains("\0") else { throw SubtitleError.invalidFormat }
        guard text.utf8.count <= maximumCueCharacters * 4, text.count <= maximumCueCharacters else {
            throw SubtitleError.textTooLong
        }
        return SubtitleCue(start: start, end: end, text: text)
    }

    public func currentCueStart(at time: Double) -> Double? {
        cues.last { $0.start <= time && $0.end > time }?.start
    }

    private static func timestamp(_ text: String) throws -> Double {
        let components = text.components(separatedBy: ":")
        guard components.count == 3,
              (1...6).contains(components[0].utf8.count), isASCIIDigits(components[0]),
              components[1].utf8.count == 2, isASCIIDigits(components[1]),
              let hours = Int(components[0]), let minutes = Int(components[1]), minutes < 60 else {
            throw SubtitleError.invalidTimestamp
        }
        let tail = components[2].replacingOccurrences(of: ",", with: ".").components(separatedBy: ".")
        guard tail.count == 2,
              tail[0].utf8.count == 2, isASCIIDigits(tail[0]),
              (1...3).contains(tail[1].utf8.count), isASCIIDigits(tail[1]),
              let seconds = Int(tail[0]), seconds < 60, let fraction = Int(tail[1]) else {
            throw SubtitleError.invalidTimestamp
        }
        let divisor = [10.0, 100.0, 1_000.0][tail[1].utf8.count - 1]
        return Double(hours * 3_600 + minutes * 60 + seconds) + Double(fraction) / divisor
    }

    private static func isASCIIDigits(_ text: String) -> Bool {
        !text.isEmpty && text.utf8.allSatisfy { (48...57).contains($0) }
    }
}
