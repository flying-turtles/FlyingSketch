import Foundation
import SketchCore

/// 2D affine transform in SVG matrix order: x' = a*x + c*y + e, y' = b*x + d*y + f.
struct SVGAffine: Equatable, Sendable {
    var a = 1.0, b = 0.0, c = 0.0, d = 1.0, e = 0.0, f = 0.0

    static let identity = SVGAffine()

    /// `self * other`: `other` is applied first, then `self` (parent * child).
    static func * (l: SVGAffine, r: SVGAffine) -> SVGAffine {
        SVGAffine(
            a: l.a * r.a + l.c * r.b, b: l.b * r.a + l.d * r.b,
            c: l.a * r.c + l.c * r.d, d: l.b * r.c + l.d * r.d,
            e: l.a * r.e + l.c * r.f + l.e, f: l.b * r.e + l.d * r.f + l.f)
    }

    func apply(_ p: Vec2) -> Vec2 {
        Vec2(x: a * p.x + c * p.y + e, y: b * p.x + d * p.y + f)
    }

    static func translate(_ x: Double, _ y: Double) -> SVGAffine { SVGAffine(e: x, f: y) }
    static func scale(_ x: Double, _ y: Double) -> SVGAffine { SVGAffine(a: x, d: y) }
    static func rotate(degrees: Double) -> SVGAffine {
        let r = degrees * .pi / 180
        return SVGAffine(a: cos(r), b: sin(r), c: -sin(r), d: cos(r))
    }

    /// Parses a `transform` attribute (list of transforms, comma/whitespace separated).
    /// Malformed input yields `nil`.
    static func parse(_ s: String) -> SVGAffine? {
        var sc = SVGScanner(s)
        var result = SVGAffine.identity
        while true {
            sc.skipSeparators()
            if sc.atEnd { return result }
            let name = sc.readIdentifier()
            guard !name.isEmpty else { return nil }
            sc.skipWhitespace()
            guard sc.consume("(") else { return nil }
            var args: [Double] = []
            while true {
                sc.skipSeparators()
                if sc.consume(")") { break }
                guard let n = sc.readNumber() else { return nil }
                args.append(n)
            }
            guard let t = make(name, args) else { return nil }
            result = result * t
        }
    }

    private static func make(_ name: String, _ v: [Double]) -> SVGAffine? {
        switch (name, v.count) {
        case ("matrix", 6): return SVGAffine(a: v[0], b: v[1], c: v[2], d: v[3], e: v[4], f: v[5])
        case ("translate", 1): return .translate(v[0], 0)
        case ("translate", 2): return .translate(v[0], v[1])
        case ("scale", 1): return .scale(v[0], v[0])
        case ("scale", 2): return .scale(v[0], v[1])
        case ("rotate", 1): return .rotate(degrees: v[0])
        case ("rotate", 3):
            return .translate(v[1], v[2]) * .rotate(degrees: v[0]) * .translate(-v[1], -v[2])
        case ("skewX", 1): return SVGAffine(c: tan(v[0] * .pi / 180))
        case ("skewY", 1): return SVGAffine(b: tan(v[0] * .pi / 180))
        default: return nil
        }
    }
}

/// Minimal character scanner shared by transform, path and number parsing.
struct SVGScanner {
    private let chars: [Character]
    private(set) var pos = 0

    init(_ s: String) { chars = Array(s) }

    var atEnd: Bool { pos >= chars.count }
    var peek: Character? { atEnd ? nil : chars[pos] }

    mutating func skipWhitespace() {
        while let c = peek, c.isWhitespace { pos += 1 }
    }

    /// Skips whitespace and at most any number of commas (lenient).
    mutating func skipSeparators() {
        while let c = peek, c.isWhitespace || c == "," { pos += 1 }
    }

    mutating func consume(_ c: Character) -> Bool {
        if peek == c { pos += 1; return true }
        return false
    }

    mutating func readIdentifier() -> String {
        var s = ""
        while let c = peek, c.isLetter { s.append(c); pos += 1 }
        return s
    }

    /// Single `0`/`1` arc flag (may be packed without separators).
    mutating func readFlag() -> Bool? {
        skipSeparators()
        guard let c = peek, c == "0" || c == "1" else { return nil }
        pos += 1
        return c == "1"
    }

    /// SVG number: `[+-]? (digits [. digits?] | . digits) ([eE][+-]?digits)?`.
    mutating func readNumber() -> Double? {
        let start = pos
        var i = pos
        if i < chars.count, chars[i] == "+" || chars[i] == "-" { i += 1 }
        var digits = 0
        while i < chars.count, chars[i].isASCII, chars[i].isNumber { i += 1; digits += 1 }
        if i < chars.count, chars[i] == "." {
            i += 1
            while i < chars.count, chars[i].isASCII, chars[i].isNumber { i += 1; digits += 1 }
        }
        guard digits > 0 else { return nil }
        if i < chars.count, chars[i] == "e" || chars[i] == "E" {
            var j = i + 1
            if j < chars.count, chars[j] == "+" || chars[j] == "-" { j += 1 }
            var expDigits = 0
            while j < chars.count, chars[j].isASCII, chars[j].isNumber { j += 1; expDigits += 1 }
            if expDigits > 0 { i = j }
        }
        guard let v = Double(String(chars[start..<i])), v.isFinite else { return nil }
        pos = i
        return v
    }

    /// Reads a number, skipping leading separators.
    mutating func number() -> Double? {
        skipSeparators()
        return readNumber()
    }

    var rest: String { String(chars[pos...]) }
}
