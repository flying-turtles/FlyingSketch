import Foundation
import SketchCore

/// Result of walking a path `d` attribute.
struct SVGPathShape {
    /// Points whose bounding box bounds the path (endpoints, control points, arc boxes).
    var points: [Vec2] = []
    /// Set when the path is exactly one `M` followed by one straight segment.
    var singleLine: (Vec2, Vec2)?
}

enum SVGPathParser {
    /// Parses all commands (absolute + relative, implicit repeats). Any malformed token,
    /// unknown command or trailing garbage yields nil (never partial geometry).
    static func parse(_ d: String) -> SVGPathShape? {
        var sc = SVGScanner(d)
        var shape = SVGPathShape()
        var cur = Vec2.zero, start = Vec2.zero
        var lastCtrl: Vec2?       // previous cubic 2nd control (for S)
        var lastQuad: Vec2?       // previous quad control (for T)
        var cmd: Character?
        var moves = 0, lines = 0, other = 0
        var lineStart = Vec2.zero, lineEnd = Vec2.zero

        func add(_ p: Vec2) { shape.points.append(p) }

        loop: while true {
            sc.skipSeparators()
            guard let c = sc.peek else { break }
            if c.isLetter {
                _ = sc.consume(c)
                cmd = c
                if c == "z" || c == "Z" {
                    cur = start; other += 1; lastCtrl = nil; lastQuad = nil
                    continue
                }
            } else if cmd == nil || cmd == "z" || cmd == "Z" {
                return nil   // number with no command, or trailing number after Z
            } else if cmd == "M" { cmd = "L" } else if cmd == "m" { cmd = "l" }
            guard let k = cmd else { return nil }
            let rel = k.isLowercase
            let o = rel ? cur : .zero

            func pt() -> Vec2? {
                guard let x = sc.number(), let y = sc.number() else { return nil }
                return Vec2(x: x + o.x, y: y + o.y)
            }

            switch k {
            case "M", "m":
                guard let p = pt() else { return nil }
                cur = p; start = p; add(p); moves += 1; lineStart = p
                lastCtrl = nil; lastQuad = nil
            case "L", "l":
                guard let p = pt() else { return nil }
                if lines == 0 { lineEnd = p }
                cur = p; add(p); lines += 1; lastCtrl = nil; lastQuad = nil
            case "H", "h":
                guard let x = sc.number() else { return nil }
                cur = Vec2(x: x + o.x, y: cur.y); add(cur); lines += 1
                if lines == 1 { lineEnd = cur }
                lastCtrl = nil; lastQuad = nil
            case "V", "v":
                guard let y = sc.number() else { return nil }
                cur = Vec2(x: cur.x, y: y + o.y); add(cur); lines += 1
                if lines == 1 { lineEnd = cur }
                lastCtrl = nil; lastQuad = nil
            case "C", "c":
                guard let p1 = pt(), let p2 = pt(), let p = pt() else { return nil }
                add(p1); add(p2); add(p); cur = p; lastCtrl = p2; lastQuad = nil; other += 1
            case "S", "s":
                guard let p2 = pt(), let p = pt() else { return nil }
                let p1 = lastCtrl.map { cur + (cur - $0) } ?? cur
                add(p1); add(p2); add(p); cur = p; lastCtrl = p2; lastQuad = nil; other += 1
            case "Q", "q":
                guard let p1 = pt(), let p = pt() else { return nil }
                add(p1); add(p); cur = p; lastQuad = p1; lastCtrl = nil; other += 1
            case "T", "t":
                guard let p = pt() else { return nil }
                let p1 = lastQuad.map { cur + (cur - $0) } ?? cur
                add(p1); add(p); cur = p; lastQuad = p1; lastCtrl = nil; other += 1
            case "A", "a":
                guard let rx = sc.number(), let ry = sc.number(), let rot = sc.number(),
                      let large = sc.readFlag(), let sweep = sc.readFlag(),
                      let p = pt() else { return nil }
                addArcBox(from: cur, to: p, rx: rx, ry: ry, rotationDeg: rot,
                          large: large, sweep: sweep, add: add)
                cur = p; lastCtrl = nil; lastQuad = nil; other += 1
            default:
                return nil   // unknown command
            }
        }

        guard !shape.points.isEmpty else { return nil }
        if moves == 1, lines == 1, other == 0 { shape.singleLine = (lineStart, lineEnd) }
        return shape
    }

    /// Adds endpoints plus the corners of the (rotated) center +- radii box of the arc's ellipse.
    private static func addArcBox(
        from p0: Vec2, to p1: Vec2, rx rxIn: Double, ry ryIn: Double, rotationDeg: Double,
        large: Bool, sweep: Bool, add: (Vec2) -> Void
    ) {
        add(p0); add(p1)
        var rx = abs(rxIn), ry = abs(ryIn)
        if p0 == p1 || rx == 0 || ry == 0 { return }   // degenerate: straight line
        let phi = rotationDeg * .pi / 180
        let cp = cos(phi), sp = sin(phi)
        let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
        let x1 = cp * dx + sp * dy, y1 = -sp * dx + cp * dy
        let lam = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        if lam > 1 { let s = lam.squareRoot(); rx *= s; ry *= s }
        let num = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
        let den = rx * rx * y1 * y1 + ry * ry * x1 * x1
        var coef = den == 0 ? 0 : (max(0, num) / den).squareRoot()
        if large == sweep { coef = -coef }
        let cxp = coef * rx * y1 / ry, cyp = -coef * ry * x1 / rx
        let cx = cp * cxp - sp * cyp + (p0.x + p1.x) / 2
        let cy = sp * cxp + cp * cyp + (p0.y + p1.y) / 2
        let hx = (rx * rx * cp * cp + ry * ry * sp * sp).squareRoot()
        let hy = (rx * rx * sp * sp + ry * ry * cp * cp).squareRoot()
        for sx in [-1.0, 1.0] { for sy in [-1.0, 1.0] {
            add(Vec2(x: cx + sx * hx, y: cy + sy * hy))
        } }
    }
}
