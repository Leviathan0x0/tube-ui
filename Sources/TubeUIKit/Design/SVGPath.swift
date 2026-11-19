import SwiftUI

enum SVGPathParser {
    struct ParseError: Error, Equatable {
        var message: String
    }

    static func parse(_ commands: String) throws -> Path {
        var parser = Parser(commands)
        return try parser.parse()
    }

    private struct Parser {
        var scalars: [Character]
        var index = 0
        var path = Path()
        var cx: CGFloat = 0
        var cy: CGFloat = 0
        var sx: CGFloat = 0
        var sy: CGFloat = 0
        var command: Character = "Z"

        init(_ source: String) {
            scalars = Array(source)
        }

        mutating func parse() throws -> Path {
            while index < scalars.count {
                skipSeparators()
                guard index < scalars.count else { break }
                let character = scalars[index]
                if character.isLetter {
                    command = character
                    index += 1
                    if command == "Z" || command == "z" {
                        path.closeSubpath()
                        cx = sx
                        cy = sy
                        continue
                    }
                }
                try readArguments()
            }
            return path
        }

        mutating func readArguments() throws {
            switch command {
            case "M":
                let point = try pointPair(relative: false)
                cx = point.x
                cy = point.y
                sx = cx
                sy = cy
                path.move(to: point)
                command = "L"
            case "m":
                let point = try pointPair(relative: true)
                cx = point.x
                cy = point.y
                sx = cx
                sy = cy
                path.move(to: point)
                command = "l"
            case "L":
                let point = try pointPair(relative: false)
                cx = point.x
                cy = point.y
                path.addLine(to: point)
            case "l":
                let point = try pointPair(relative: true)
                cx = point.x
                cy = point.y
                path.addLine(to: point)
            case "H":
                cx = try number()
                path.addLine(to: CGPoint(x: cx, y: cy))
            case "h":
                cx += try number()
                path.addLine(to: CGPoint(x: cx, y: cy))
            case "V":
                cy = try number()
                path.addLine(to: CGPoint(x: cx, y: cy))
            case "v":
                cy += try number()
                path.addLine(to: CGPoint(x: cx, y: cy))
            case "C":
                let control1 = try pointPair(relative: false)
                let control2 = try pointPair(relative: false)
                let end = try pointPair(relative: false)
                path.addCurve(to: end, control1: control1, control2: control2)
                cx = end.x
                cy = end.y
            case "c":
                let control1 = try pointPair(relative: true)
                let control2 = try pointPair(relative: true)
                let end = try pointPair(relative: true)
                path.addCurve(to: end, control1: control1, control2: control2)
                cx = end.x
                cy = end.y
            default:
                throw ParseError(message: "Unsupported SVG command \(command).")
            }
        }

        mutating func pointPair(relative: Bool) throws -> CGPoint {
            let x = try number()
            let y = try number()
            if relative {
                return CGPoint(x: cx + x, y: cy + y)
            }
            return CGPoint(x: x, y: y)
        }

        mutating func skipSeparators() {
            while index < scalars.count {
                let character = scalars[index]
                if character == "," || character.isWhitespace {
                    index += 1
                } else {
                    break
                }
            }
        }

        mutating func number() throws -> CGFloat {
            skipSeparators()
            guard index < scalars.count else {
                throw ParseError(message: "Expected a number.")
            }
            let start = index
            if scalars[index] == "+" || scalars[index] == "-" {
                index += 1
            }
            var sawDigit = false
            var sawDot = false
            while index < scalars.count {
                let character = scalars[index]
                if character.isNumber {
                    sawDigit = true
                    index += 1
                } else if character == ".", !sawDot {
                    sawDot = true
                    index += 1
                } else {
                    break
                }
            }
            if index < scalars.count, scalars[index] == "e" || scalars[index] == "E" {
                let mark = index
                index += 1
                if index < scalars.count, scalars[index] == "+" || scalars[index] == "-" {
                    index += 1
                }
                var exponentDigits = false
                while index < scalars.count, scalars[index].isNumber {
                    exponentDigits = true
                    index += 1
                }
                if !exponentDigits {
                    index = mark
                }
            }
            let token = String(scalars[start..<index])
            guard sawDigit, let value = Double(token) else {
                throw ParseError(message: "Bad number \(token).")
            }
            return CGFloat(value)
        }
    }
}
