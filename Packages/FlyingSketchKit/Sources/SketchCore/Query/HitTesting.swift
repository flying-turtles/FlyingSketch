import Foundation

/// Approximate text frame (renderer may refine later): split on newlines; width = fontSize * 0.6 * longest
/// line's character count, height = lines * fontSize * 1.2. `position` is the top-left, rotated around `position`.
func textFrame(_ t: TextObject) -> Rect {
    let lines = t.text.split(separator: "\n", omittingEmptySubsequences: false)
    let longest = lines.map(\.count).max() ?? 0
    return Rect(origin: t.position, size: Vec2(x: t.fontSize * 0.6 * Double(longest),
                                               y: t.fontSize * 1.2 * Double(max(lines.count, 1))))
}

private func corners(_ r: Rect) -> [Vec2] {
    [Vec2(x: r.minX, y: r.minY), Vec2(x: r.maxX, y: r.minY), Vec2(x: r.maxX, y: r.maxY), Vec2(x: r.minX, y: r.maxY)]
}

/// Rotated frame corners; `pivot` is the rotation centre.
private func rotatedCorners(_ r: Rect, by angle: Double, around pivot: Vec2) -> [Vec2] {
    corners(r).map { pivot + ($0 - pivot).rotated(by: angle) }
}

private func rotatedFrame(of object: SceneObject) -> (frame: Rect, rotation: Double, pivot: Vec2)? {
    switch object {
    case .text(let t):
        return (textFrame(t), t.rotation, t.position)
    case .image(let i):
        return (i.frame, i.rotation, Vec2(x: i.frame.minX + i.frame.size.x / 2, y: i.frame.minY + i.frame.size.y / 2))
    default:
        return nil
    }
}

/// Doc-less fallback for a part: a square of this side (mm) centred on `PartInstance.center`.
private let fallbackPartSize = 10.0

private func fallbackPartRect(_ p: PartInstance) -> Rect {
    Rect(origin: p.center - Vec2(x: fallbackPartSize / 2, y: fallbackPartSize / 2),
         size: Vec2(x: fallbackPartSize, y: fallbackPartSize))
}

/// Axis-aligned world bounds. Ink and shapes include half the line width. Image rotates around its centre.
/// A part without a document is a 10 mm square at its centre (fallback); a wire spans its polyline plus half width.
/// Use `bounds(of:in:)` for definition-accurate part bounds.
public func bounds(of object: SceneObject) -> Rect {
    switch object {
    case .ink(let s):
        guard let r = Rect.bounding(s.points.map(\.position)) else { return Rect(origin: .zero, size: .zero) }
        return r.insetBy(-s.baseWidth / 2)
    case .shape(let s):
        return Rect.bounding([s.start, s.end])!.insetBy(-s.lineWidth / 2)
    case .text, .image:
        let (frame, rotation, pivot) = rotatedFrame(of: object)!
        return Rect.bounding(rotatedCorners(frame, by: rotation, around: pivot))!
    case .part(let p):
        return fallbackPartRect(p)
    case .wire(let w):
        return Rect.bounding(w.polyline)!.insetBy(-w.width / 2)
    }
}

/// Like `bounds(of:)`, but a part uses its definition: rotated body corners' box plus leg segments (with half leg width).
public func bounds(of object: SceneObject, in doc: SketchDocument) -> Rect {
    guard case .part(let p) = object, let def = doc.parts[p.definitionKey] else { return bounds(of: object) }
    var r = Rect.bounding(p.bodyCorners(in: def))!
    for c in def.connectors {
        guard let seg = p.legSegment(for: c, in: def), let leg = c.leg else { continue }
        r = r.union(Rect.bounding([seg.origin, seg.end])!.insetBy(-leg.width / 2))
    }
    return r
}

private func distance(from p: Vec2, toSegment a: Vec2, _ b: Vec2) -> Double {
    let ab = b - a
    let len2 = ab.x * ab.x + ab.y * ab.y
    guard len2 > 0 else { return p.distance(to: a) }
    let t = min(max(((p.x - a.x) * ab.x + (p.y - a.y) * ab.y) / len2, 0), 1)
    return p.distance(to: a + ab * t)
}

private func distance(from p: Vec2, toPolyline pts: [Vec2], closed: Bool = false) -> Double {
    guard var prev = pts.first else { return .infinity }
    var best = p.distance(to: prev)
    for q in pts.dropFirst() {
        best = min(best, distance(from: p, toSegment: prev, q))
        prev = q
    }
    if closed, let first = pts.first { best = min(best, distance(from: p, toSegment: prev, first)) }
    return best
}

private func ellipseOutline(_ r: Rect, segments: Int = 96) -> [Vec2] {
    let c = Vec2(x: r.minX + r.size.x / 2, y: r.minY + r.size.y / 2)
    let (a, b) = (r.size.x / 2, r.size.y / 2)
    return (0..<segments).map {
        let t = Double($0) / Double(segments) * 2 * .pi
        return Vec2(x: c.x + a * cos(t), y: c.y + b * sin(t))
    }
}

/// Ink: distance to polyline <= tolerance + baseWidth/2 (single point = disc).
/// Shapes: distance to outline, or inside when filled. Text/image: inside rotated frame (+ tolerance).
public func hitTest(_ object: SceneObject, point: Vec2, tolerance: Double) -> Bool {
    switch object {
    case .ink(let s):
        let d = distance(from: point, toPolyline: s.points.map(\.position))
        return d <= tolerance + s.baseWidth / 2

    case .shape(let s):
        let reach = tolerance + s.lineWidth / 2
        let box = Rect.bounding([s.start, s.end])!
        switch s.kind {
        case .line, .arrow:
            return distance(from: point, toSegment: s.start, s.end) <= reach
        case .rectangle:
            if s.fillColor != nil, box.contains(point) { return true }
            return distance(from: point, toPolyline: corners(box), closed: true) <= reach
        case .ellipse:
            if s.fillColor != nil, box.size.x > 0, box.size.y > 0 {
                let dx = (point.x - (box.minX + box.size.x / 2)) / (box.size.x / 2)
                let dy = (point.y - (box.minY + box.size.y / 2)) / (box.size.y / 2)
                if dx * dx + dy * dy <= 1 { return true }
            }
            return distance(from: point, toPolyline: ellipseOutline(box), closed: true) <= reach
        }

    case .text, .image:
        let (frame, rotation, pivot) = rotatedFrame(of: object)!
        let local = pivot + (point - pivot).rotated(by: -rotation)
        return frame.insetBy(-tolerance).contains(local)

    case .part(let p):
        return fallbackPartRect(p).insetBy(-tolerance).contains(point)

    case .wire(let w):
        return distance(from: point, toPolyline: w.polyline) <= tolerance + w.width / 2
    }
}

/// Like `hitTest(_:point:tolerance:)`, but a part uses its definition: rotated body rect or any leg segment.
public func hitTest(_ object: SceneObject, point: Vec2, tolerance: Double, in doc: SketchDocument) -> Bool {
    guard case .part(let p) = object, let def = doc.parts[p.definitionKey] else {
        return hitTest(object, point: point, tolerance: tolerance)
    }
    let body = Rect(origin: .zero, size: def.size)
    if body.insetBy(-tolerance).contains(p.localPoint(point, in: def)) { return true }
    for c in def.connectors {
        guard let seg = p.legSegment(for: c, in: def), let leg = c.leg else { continue }
        if distance(from: point, toSegment: seg.origin, seg.end) <= tolerance + leg.width / 2 { return true }
    }
    return false
}

private func polygonContains(_ polygon: [Vec2], _ p: Vec2) -> Bool {
    guard polygon.count >= 3 else { return false }
    var inside = false
    var j = polygon.count - 1
    for i in polygon.indices {
        let a = polygon[i], b = polygon[j]
        if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
        j = i
    }
    return inside
}

/// Ink: selected when >= 50 % of its points are inside. Others: bounds centre inside.
public func lassoContains(_ polygon: [Vec2], object: SceneObject) -> Bool {
    if case .ink(let s) = object {
        guard !s.points.isEmpty else { return false }
        let inside = s.points.filter { polygonContains(polygon, $0.position) }.count
        return Double(inside) >= Double(s.points.count) / 2
    }
    return polygonContains(polygon, centre(of: bounds(of: object)))
}

private func centre(of b: Rect) -> Vec2 { Vec2(x: b.minX + b.size.x / 2, y: b.minY + b.size.y / 2) }

/// Like `lassoContains(_:object:)`, but parts use definition-aware bounds.
public func lassoContains(_ polygon: [Vec2], object: SceneObject, in doc: SketchDocument) -> Bool {
    guard case .part = object else { return lassoContains(polygon, object: object) }
    return polygonContains(polygon, centre(of: bounds(of: object, in: doc)))
}
