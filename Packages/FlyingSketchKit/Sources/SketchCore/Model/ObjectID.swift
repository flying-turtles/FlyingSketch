import Foundation

public struct ObjectID: Hashable, Codable, Sendable {
    public let raw: UUID

    public init(raw: UUID) { self.raw = raw }

    public static func new() -> ObjectID { ObjectID(raw: UUID()) }

    public init(from decoder: Decoder) throws {
        raw = try decoder.singleValueContainer().decode(UUID.self)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(raw)
    }
}
