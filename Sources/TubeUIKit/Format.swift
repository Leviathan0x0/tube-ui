import Foundation

enum TubeFormat {
    static func count(_ raw: String?) -> String? {
        guard let raw, let value = Double(raw), value >= 0 else { return nil }
        let scaled: (Double, String)
        switch value {
        case 1_000_000_000...:
            scaled = (value / 1_000_000_000, "B")
        case 1_000_000...:
            scaled = (value / 1_000_000, "M")
        case 1_000...:
            scaled = (value / 1_000, "K")
        default:
            return String(Int(value))
        }
        let digits = scaled.0 >= 10 ? String(format: "%.0f", scaled.0) : String(format: "%.1f", scaled.0)
        let trimmed = digits.hasSuffix(".0") ? String(digits.dropLast(2)) : digits
        return trimmed + scaled.1
    }

    static func date(_ iso: String?) -> String? {
        guard let iso, let date = parsed(iso) else { return nil }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    /// YouTube `contentDetails.duration`, for example `PT45S` or `PT1H2M3S`.
    static func durationSeconds(_ iso: String) -> Int? {
        guard iso.hasPrefix("PT") else { return nil }
        var seconds = 0
        var number = ""
        for character in iso.dropFirst(2) {
            if character.isNumber {
                number.append(character)
            } else {
                guard let value = Int(number) else { return nil }
                switch character {
                case "H": seconds += value * 3600
                case "M": seconds += value * 60
                case "S": seconds += value
                default: return nil
                }
                number = ""
            }
        }
        return number.isEmpty ? seconds : nil
    }

    static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let remain = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remain)
        }
        return String(format: "%d:%02d", minutes, remain)
    }

    /// Hashtags in description order, the way the watch page lifts them onto the views line.
    static func hashtags(in text: String, limit: Int = 6) -> [String] {
        var tags: [String] = []
        var seen = Set<String>()
        var index = text.startIndex
        while index < text.endIndex, tags.count < limit {
            if text[index] == "#" {
                let next = text.index(after: index)
                if next < text.endIndex, text[next].isLetter || text[next].isNumber || text[next] == "_" {
                    var end = next
                    while end < text.endIndex {
                        let character = text[end]
                        if character.isLetter || character.isNumber || character == "_" {
                            end = text.index(after: end)
                        } else {
                            break
                        }
                    }
                    let tag = String(text[index..<end])
                    if seen.insert(tag.lowercased()).inserted {
                        tags.append(tag)
                    }
                    index = end
                    continue
                }
            }
            index = text.index(after: index)
        }
        return tags
    }

    /// Collapsed description. A leading line that is only hashtags stays on the views line.
    static func descriptionPreview(_ text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var start = 0
        while start < lines.count {
            let trimmed = lines[start].trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || isHashtagLine(trimmed) {
                start += 1
                continue
            }
            break
        }
        let body = lines.dropFirst(start).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? fallback : body
    }

    private static func isHashtagLine(_ line: String) -> Bool {
        let parts = line.split(whereSeparator: \.isWhitespace)
        return !parts.isEmpty && parts.allSatisfy { part in
            part.hasPrefix("#") && part.count > 1
        }
    }

    /// Shorts are three minutes or shorter.
    static func isShort(duration iso: String) -> Bool {
        guard let seconds = durationSeconds(iso) else { return false }
        return seconds > 0 && seconds <= 180
    }

    private static func parsed(_ iso: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: iso) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: iso)
    }
}
