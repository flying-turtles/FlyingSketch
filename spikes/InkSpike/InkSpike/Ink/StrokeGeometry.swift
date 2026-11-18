import CoreGraphics
import simd

/// Geometry shared by the Core Animation and Metal renderers.
enum StrokeGeometry {
    /// Catmull-Rom subdivision for smooth curves between samples; drops near-duplicates.
    static func smooth(_ input: [StrokePoint]) -> [StrokePoint] {
        let points = dedupe(input)
        guard points.count > 2 else { return points }
        var out: [StrokePoint] = []
        out.reserveCapacity(points.count * 4)
        for i in 0..<(points.count - 1) {
            let p0 = points[max(i - 1, 0)].position
            let p1 = points[i].position
            let p2 = points[i + 1].position
            let p3 = points[min(i + 2, points.count - 1)].position
            let r1 = points[i].radius
            let r2 = points[i + 1].radius
            let steps = min(8, max(1, Int(distance(p1, p2) / 2)))
            for k in 0..<steps {
                let t = CGFloat(k) / CGFloat(steps)
                out.append(StrokePoint(position: catmullRom(p0, p1, p2, p3, t), radius: r1 + (r2 - r1) * t))
            }
        }
        if let last = points.last { out.append(last) }
        return out
    }

    /// Closed outline polygon with round caps; filled with nonzero winding.
    static func outlinePath(_ points: [StrokePoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        guard points.count > 1 else {
            path.addEllipse(in: CGRect(x: first.position.x - first.radius, y: first.position.y - first.radius,
                                       width: first.radius * 2, height: first.radius * 2))
            return path
        }
        let (left, right) = offsets(points)
        path.move(to: left[0])
        for p in left.dropFirst() { path.addLine(to: p) }
        let last = points[points.count - 1]
        for p in cap(center: last.position, radius: last.radius, from: angle(of: left.last!, around: last.position)) {
            path.addLine(to: p)
        }
        for p in right.reversed() { path.addLine(to: p) }
        for p in cap(center: first.position, radius: first.radius, from: angle(of: right[0], around: first.position)) {
            path.addLine(to: p)
        }
        path.closeSubpath()
        return path
    }

    /// Triangle list (in view points) for the Metal renderer: quad strip plus round caps.
    static func triangles(_ points: [StrokePoint]) -> [SIMD2<Float>] {
        var tris: [SIMD2<Float>] = []
        guard let first = points.first else { return tris }
        func v(_ p: CGPoint) -> SIMD2<Float> { SIMD2(Float(p.x), Float(p.y)) }
        func fan(_ c: CGPoint, _ ring: [CGPoint]) {
            for i in 0..<(ring.count - 1) {
                tris += [v(c), v(ring[i]), v(ring[i + 1])]
            }
        }
        guard points.count > 1 else {
            let ring = (0...16).map { i -> CGPoint in
                let a = CGFloat(i) / 16 * 2 * .pi
                return CGPoint(x: first.position.x + cos(a) * first.radius, y: first.position.y + sin(a) * first.radius)
            }
            fan(first.position, ring)
            return tris
        }
        let (left, right) = offsets(points)
        tris.reserveCapacity(points.count * 6 + 64)
        for i in 0..<(points.count - 1) {
            tris += [v(left[i]), v(right[i]), v(left[i + 1])]
            tris += [v(right[i]), v(right[i + 1]), v(left[i + 1])]
        }
        let last = points[points.count - 1]
        fan(last.position, [left.last!] + cap(center: last.position, radius: last.radius,
                                              from: angle(of: left.last!, around: last.position)))
        fan(first.position, [right[0]] + cap(center: first.position, radius: first.radius,
                                             from: angle(of: right[0], around: first.position)))
        return tris
    }

    // MARK: - Helpers

    private static func dedupe(_ points: [StrokePoint]) -> [StrokePoint] {
        var out: [StrokePoint] = []
        out.reserveCapacity(points.count)
        for p in points {
            if let last = out.last, distance(last.position, p.position) < 0.5 { continue }
            out.append(p)
        }
        return out
    }

    private static func offsets(_ points: [StrokePoint]) -> ([CGPoint], [CGPoint]) {
        var left: [CGPoint] = [], right: [CGPoint] = []
        left.reserveCapacity(points.count)
        right.reserveCapacity(points.count)
        for i in points.indices {
            let prev = points[max(i - 1, 0)].position
            let next = points[min(i + 1, points.count - 1)].position
            var tx = next.x - prev.x, ty = next.y - prev.y
            let len = max(hypot(tx, ty), 1e-6)
            tx /= len; ty /= len
            let nx = -ty, ny = tx
            let p = points[i].position, r = points[i].radius
            left.append(CGPoint(x: p.x + nx * r, y: p.y + ny * r))
            right.append(CGPoint(x: p.x - nx * r, y: p.y - ny * r))
        }
        return (left, right)
    }

    /// Half circle sweeping −π from `from`, excluding the start point.
    private static func cap(center: CGPoint, radius: CGFloat, from start: CGFloat, steps: Int = 10) -> [CGPoint] {
        (1...steps).map { i in
            let a = start - CGFloat(i) / CGFloat(steps) * .pi
            return CGPoint(x: center.x + cos(a) * radius, y: center.y + sin(a) * radius)
        }
    }

    private static func angle(of p: CGPoint, around c: CGPoint) -> CGFloat { atan2(p.y - c.y, p.x - c.x) }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

    private static func catmullRom(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint, _ t: CGFloat) -> CGPoint {
        let t2 = t * t, t3 = t2 * t
        func c(_ a: CGFloat, _ b: CGFloat, _ c: CGFloat, _ d: CGFloat) -> CGFloat {
            0.5 * ((2 * b) + (-a + c) * t + (2 * a - 5 * b + 4 * c - d) * t2 + (-a + 3 * b - 3 * c + d) * t3)
        }
        return CGPoint(x: c(p0.x, p1.x, p2.x, p3.x), y: c(p0.y, p1.y, p2.y, p3.y))
    }
}
