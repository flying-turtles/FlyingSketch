public enum WireAttachment: Hashable, Codable, Sendable {
    case connector(part: ObjectID, connector: String)
}

public struct WireEnd: Hashable, Codable, Sendable {
    /// Always the current world mm position.
    public var position: Vec2
    public var attachment: WireAttachment?

    public init(position: Vec2, attachment: WireAttachment? = nil) {
        self.position = position
        self.attachment = attachment
    }
}

public struct Wire: Hashable, Codable, Sendable {
    public var id: ObjectID
    public var start: WireEnd
    public var end: WireEnd
    public var bends: [Vec2]
    public var color: RGBAColor
    public var width: Double

    public init(id: ObjectID = .new(), start: WireEnd, end: WireEnd, bends: [Vec2] = [],
                color: RGBAColor = .black, width: Double = 0.65) {
        self.id = id
        self.start = start
        self.end = end
        self.bends = bends
        self.color = color
        self.width = width
    }

    /// start -> bends -> end.
    public var polyline: [Vec2] { [start.position] + bends + [end.position] }
}

// MARK: Bend editing

public extension Wire {
    /// Copy with bend `index` at `p`; out of range returns `self`.
    func movingBend(_ index: Int, to p: Vec2) -> Wire {
        guard bends.indices.contains(index) else { return self }
        var w = self
        w.bends[index] = p
        return w
    }

    /// Copy with a new bend at `p` in segment `segment` (`polyline[segment]` -> `polyline[segment + 1]`); the new
    /// bend becomes `bends[segment]`. Out of range returns `self`.
    func insertingBend(inSegment segment: Int, at p: Vec2) -> Wire {
        guard segment >= 0, segment <= bends.count else { return self }
        var w = self
        w.bends.insert(p, at: segment)
        return w
    }

    /// Copy without bend `index`; out of range returns `self`.
    func removingBend(_ index: Int) -> Wire {
        guard bends.indices.contains(index) else { return self }
        var w = self
        w.bends.remove(at: index)
        return w
    }

    /// Midpoint of each polyline segment, start to end (`polyline.count - 1` entries).
    var segmentMidpoints: [Vec2] {
        let p = polyline
        return zip(p, p.dropFirst()).map { ($0 + $1) / 2 }
    }
}
