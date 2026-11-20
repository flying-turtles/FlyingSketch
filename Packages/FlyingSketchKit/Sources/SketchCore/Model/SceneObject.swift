public enum SceneObject: Hashable, Codable, Sendable {
    case ink(InkStroke)
    case shape(ShapeObject)
    case text(TextObject)
    case image(ImageObject)
    case part(PartInstance)
    case wire(Wire)
    case joint(Joint)

    public var id: ObjectID {
        switch self {
        case .ink(let o): o.id
        case .shape(let o): o.id
        case .text(let o): o.id
        case .image(let o): o.id
        case .part(let o): o.id
        case .wire(let o): o.id
        case .joint(let o): o.id
        }
    }

    public func withID(_ newID: ObjectID) -> SceneObject {
        switch self {
        case .ink(var o): o.id = newID; return .ink(o)
        case .shape(var o): o.id = newID; return .shape(o)
        case .text(var o): o.id = newID; return .text(o)
        case .image(var o): o.id = newID; return .image(o)
        case .part(var o): o.id = newID; return .part(o)
        case .wire(var o): o.id = newID; return .wire(o)
        case .joint(var o): o.id = newID; return .joint(o)
        }
    }

    public func translated(by d: Vec2) -> SceneObject {
        switch self {
        case .ink(var o):
            for i in o.points.indices { o.points[i].position = o.points[i].position + d }
            return .ink(o)
        case .shape(var o):
            o.start = o.start + d
            o.end = o.end + d
            return .shape(o)
        case .text(var o):
            o.position = o.position + d
            return .text(o)
        case .image(var o):
            o.frame.origin = o.frame.origin + d
            return .image(o)
        case .part(var o):
            o.center = o.center + d
            o.legEnds = o.legEnds.mapValues { $0 + d }
            return .part(o)
        case .wire(var o):
            o.start.position = o.start.position + d
            o.end.position = o.end.position + d
            o.bends = o.bends.map { $0 + d }
            return .wire(o)
        case .joint(var o):
            o.position = o.position + d
            for i in o.anchors.indices { o.anchors[i].point = o.anchors[i].point + d }
            return .joint(o)
        }
    }

    /// Rotates about `pivot` by `angle` (clockwise radians). Boxes (rectangle/ellipse, image) move their centre and keep
    /// their size; text moves `position`; all stored rotations are normalised. Lines/arrows rotate their end points only.
    public func rotated(by angle: Double, around pivot: Vec2) -> SceneObject {
        func spin(_ v: Vec2) -> Vec2 { pivot + (v - pivot).rotated(by: angle) }
        switch self {
        case .ink(var o):
            for i in o.points.indices { o.points[i].position = spin(o.points[i].position) }
            return .ink(o)
        case .shape(var o):
            if o.kind == .rectangle || o.kind == .ellipse {
                let shift = spin(ShapeGeometry.center(of: o)) - ShapeGeometry.center(of: o)
                o.start = o.start + shift
                o.end = o.end + shift
                o.rotation = normalizedAngle(o.rotation + angle)
            } else {
                o.start = spin(o.start)
                o.end = spin(o.end)
            }
            return .shape(o)
        case .text(var o):
            o.position = spin(o.position)
            o.rotation = normalizedAngle(o.rotation + angle)
            return .text(o)
        case .image(var o):
            let half = o.frame.size / 2
            o.frame.origin = spin(o.frame.origin + half) - half
            o.rotation = normalizedAngle(o.rotation + angle)
            return .image(o)
        case .part(var o):
            o.center = spin(o.center)
            o.rotation = normalizedAngle(o.rotation + angle)
            o.legEnds = o.legEnds.mapValues(spin)
            return .part(o)
        case .wire(var o):
            o.start.position = spin(o.start.position)
            o.end.position = spin(o.end.position)
            o.bends = o.bends.map(spin)
            return .wire(o)
        case .joint(var o):
            o.position = spin(o.position)
            for i in o.anchors.indices { o.anchors[i].point = spin(o.anchors[i].point) }
            return .joint(o)
        }
    }

    // Flat JSON: {"type": "...", ...payload fields}.
    private enum TypeKey: String, CodingKey { case type }

    public init(from decoder: Decoder) throws {
        let type = try decoder.container(keyedBy: TypeKey.self).decode(String.self, forKey: .type)
        switch type {
        case "ink": self = .ink(try InkStroke(from: decoder))
        case "shape": self = .shape(try ShapeObject(from: decoder))
        case "text": self = .text(try TextObject(from: decoder))
        case "image": self = .image(try ImageObject(from: decoder))
        case "part": self = .part(try PartInstance(from: decoder))
        case "wire": self = .wire(try Wire(from: decoder))
        case "joint": self = .joint(try Joint(from: decoder))
        default: throw DocumentError.corrupt("unknown object type '\(type)'")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: TypeKey.self)
        switch self {
        case .ink(let o): try c.encode("ink", forKey: .type); try o.encode(to: encoder)
        case .shape(let o): try c.encode("shape", forKey: .type); try o.encode(to: encoder)
        case .text(let o): try c.encode("text", forKey: .type); try o.encode(to: encoder)
        case .image(let o): try c.encode("image", forKey: .type); try o.encode(to: encoder)
        case .part(let o): try c.encode("part", forKey: .type); try o.encode(to: encoder)
        case .wire(let o): try c.encode("wire", forKey: .type); try o.encode(to: encoder)
        case .joint(let o): try c.encode("joint", forKey: .type); try o.encode(to: encoder)
        }
    }
}
