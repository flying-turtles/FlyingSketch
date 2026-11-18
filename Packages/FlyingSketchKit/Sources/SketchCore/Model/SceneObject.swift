public enum SceneObject: Hashable, Codable, Sendable {
    case ink(InkStroke)
    case shape(ShapeObject)
    case text(TextObject)
    case image(ImageObject)
    case part(PartInstance)
    case wire(Wire)

    public var id: ObjectID {
        switch self {
        case .ink(let o): o.id
        case .shape(let o): o.id
        case .text(let o): o.id
        case .image(let o): o.id
        case .part(let o): o.id
        case .wire(let o): o.id
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
        }
    }
}
