import Foundation
import SketchCore

public struct CropSpec: Hashable, Codable, Sendable {
    /// Source px.
    public var center: Vec2
    /// Px, in the rotated crop frame.
    public var size: Vec2
    /// Radians, rotation of the crop rectangle in the source (-pi/4...pi/4).
    public var angle: Double
    /// 0...3, output rotated clockwise.
    public var quarterTurns: Int

    public init(center: Vec2, size: Vec2, angle: Double = 0, quarterTurns: Int = 0) {
        self.center = center
        self.size = size
        self.angle = angle
        self.quarterTurns = quarterTurns
    }

    public static func full(_ s: PixelSize) -> CropSpec {
        CropSpec(center: Vec2(x: Double(s.width) / 2, y: Double(s.height) / 2),
                 size: Vec2(x: Double(s.width), y: Double(s.height)))
    }
}

public enum ScaleSpec: Hashable, Codable, Sendable {
    /// Two source-px points a known distance apart.
    case twoPoints(Vec2, Vec2, mm: Double)
    /// Output (post-rotation) crop width in mm.
    case width(mm: Double)
}

public struct DraftPin: Hashable, Codable, Sendable {
    public var id: String
    public var name: String
    public var description: String
    public var kind: ConnectorKind
    public var role: PinRole?
    /// Source px.
    public var position: Vec2

    public init(id: String, name: String, description: String = "", kind: ConnectorKind = .male,
                role: PinRole? = nil, position: Vec2) {
        self.id = id
        self.name = name
        self.description = description
        self.kind = kind
        self.role = role
        self.position = position
    }
}

public struct PartMetadata: Hashable, Codable, Sendable {
    public var title: String
    public var family: String
    public var labelPrefix: String
    public var tags: [String]
    public var properties: [String: String]

    public init(title: String = "", family: String = "Photo parts", labelPrefix: String = "U",
                tags: [String] = [], properties: [String: String] = [:]) {
        self.title = title
        self.family = family
        self.labelPrefix = labelPrefix
        self.tags = tags
        self.properties = properties
    }
}

public struct PhotoPartDraft: Hashable, Codable, Sendable {
    public var libraryID: String
    public var sourceSize: PixelSize
    public var crop: CropSpec
    public var scale: ScaleSpec?
    public var pins: [DraftPin]
    public var buses: [[String]]
    public var gridSnap: Bool
    public var nextPinNumber: Int
    public var metadata: PartMetadata

    public init(sourceSize: PixelSize) {
        libraryID = "photo-\(UUID().uuidString.lowercased())"
        self.sourceSize = sourceSize
        crop = .full(sourceSize)
        scale = nil
        pins = []
        buses = []
        gridSnap = true
        nextPinNumber = 1
        metadata = PartMetadata()
    }
}
