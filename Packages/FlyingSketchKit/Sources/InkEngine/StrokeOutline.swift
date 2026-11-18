import Foundation
import SketchCore

/// Outline geometry shared by renderers. All values in millimetres.
public enum StrokeOutline {
    /// Full stroke width (mm) at a point.
    public static func widthAt(_ p: InkPoint, baseWidth: Double, tool: InkTool, gamma: Double = 1.0) -> Double {
        switch tool {
        case .pen, .pencil: baseWidth * (0.2 + 0.8 * pow(min(max(p.pressure, 0), 1), gamma))
        case .marker, .highlighter: baseWidth
        }
    }

    /// Closed outline polygon with round caps; fill with nonzero winding.
    public static func polygon(_ points: [InkPoint], baseWidth: Double, tool: InkTool, gamma: Double = 1.0) -> [Vec2] {
        let nodes = smooth(points.map { Node(pos: $0.position, r: widthAt($0, baseWidth: baseWidth, tool: tool, gamma: gamma) / 2) })
        guard let first = nodes.first else { return [] }
        guard nodes.count > 1 else {
            return (0..<16).map { i in
                let a = Double(i) / 16 * 2 * .pi
                return first.pos + Vec2(x: cos(a), y: sin(a)) * first.r
            }
        }
        let (left, right) = offsets(nodes)
        let last = nodes[nodes.count - 1]
        var out = left
        out += cap(center: last.pos, radius: last.r, from: angle(left.last!, around: last.pos))
        out += right.reversed()
        out += cap(center: first.pos, radius: first.r, from: angle(right[0], around: first.pos))
        return out
    }

    // MARK: - Helpers

    private struct Node { var pos: Vec2; var r: Double }

    /// Catmull-Rom subdivision; drops near-duplicates (< 0.08 mm). Adds points between samples only.
    private static func smooth(_ input: [Node]) -> [Node] {
        var points: [Node] = []
        for n in input {
            if let l = points.last, l.pos.distance(to: n.pos) < 0.08 { continue }
            points.append(n)
        }
        guard points.count > 2 else { return points }
        var out: [Node] = []
        out.reserveCapacity(points.count * 4)
        for i in 0..<(points.count - 1) {
            let p0 = points[max(i - 1, 0)].pos
            let p1 = points[i].pos
            let p2 = points[i + 1].pos
            let p3 = points[min(i + 2, points.count - 1)].pos
            let r1 = points[i].r, r2 = points[i + 1].r
            let steps = min(8, max(1, Int(p1.distance(to: p2) / 0.3)))
            for k in 0..<steps {
                let t = Double(k) / Double(steps)
                out.append(Node(pos: catmullRom(p0, p1, p2, p3, t), r: r1 + (r2 - r1) * t))
            }
        }
        out.append(points[points.count - 1])
        return out
    }

    private static func offsets(_ nodes: [Node]) -> ([Vec2], [Vec2]) {
        var left: [Vec2] = [], right: [Vec2] = []
        for i in nodes.indices {
            let prev = nodes[max(i - 1, 0)].pos
            let next = nodes[min(i + 1, nodes.count - 1)].pos
            let t = (next - prev).normalized
            let n = Vec2(x: -t.y, y: t.x)
            left.append(nodes[i].pos + n * nodes[i].r)
            right.append(nodes[i].pos - n * nodes[i].r)
        }
        return (left, right)
    }

    /// Half circle sweeping -pi from `start`, excluding the start point.
    private static func cap(center: Vec2, radius: Double, from start: Double, steps: Int = 10) -> [Vec2] {
        (1...steps).map { i in
            let a = start - Double(i) / Double(steps) * .pi
            return center + Vec2(x: cos(a), y: sin(a)) * radius
        }
    }

    private static func angle(_ p: Vec2, around c: Vec2) -> Double { atan2(p.y - c.y, p.x - c.x) }

    private static func catmullRom(_ p0: Vec2, _ p1: Vec2, _ p2: Vec2, _ p3: Vec2, _ t: Double) -> Vec2 {
        let t2 = t * t, t3 = t2 * t
        func c(_ a: Double, _ b: Double, _ c: Double, _ d: Double) -> Double {
            0.5 * ((2 * b) + (-a + c) * t + (2 * a - 5 * b + 4 * c - d) * t2 + (-a + 3 * b - 3 * c + d) * t3)
        }
        return Vec2(x: c(p0.x, p1.x, p2.x, p3.x), y: c(p0.y, p1.y, p2.y, p3.y))
    }
}
