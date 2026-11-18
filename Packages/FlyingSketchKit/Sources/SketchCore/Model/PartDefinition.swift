public enum ConnectorKind: String, Codable, Sendable { case male, female, pad }

public enum PinRole: String, Codable, Sendable { case power, ground, digital, analog, i2cSDA, i2cSCL, spi, uart, other }

public enum GraphicKind: String, Codable, Sendable { case svg, png }

/// Flexible leg of a connector (part-local mm).
public struct LegSpec: Hashable, Codable, Sendable {
    public var origin: Vec2
    public var defaultEnd: Vec2
    public var color: RGBAColor
    public var width: Double

    public init(origin: Vec2, defaultEnd: Vec2, color: RGBAColor, width: Double = 0.6) {
        self.origin = origin
        self.defaultEnd = defaultEnd
        self.color = color
        self.width = width
    }
}

public struct ConnectorDef: Hashable, Codable, Sendable {
    public var id: String
    public var name: String
    public var description: String
    public var kind: ConnectorKind
    /// Part-local mm, top-left origin.
    public var position: Vec2
    public var role: PinRole?
    public var leg: LegSpec?

    public init(id: String, name: String, description: String = "", kind: ConnectorKind, position: Vec2,
                role: PinRole? = nil, leg: LegSpec? = nil) {
        self.id = id
        self.name = name
        self.description = description
        self.kind = kind
        self.position = position
        self.role = role
        self.leg = leg
    }
}

/// Part definition embedded in the document (keyed by `key` in `SketchDocument.parts`).
public struct PartDefinition: Hashable, Codable, Sendable {
    public var libraryID: String
    public var versionHash: String
    public var title: String
    public var family: String
    public var labelPrefix: String
    public var tags: [String]
    public var properties: [String: String]
    /// mm.
    public var size: Vec2
    /// File name in `SketchDocument.assets`.
    public var graphicAsset: String
    public var graphicKind: GraphicKind
    public var connectors: [ConnectorDef]
    /// Groups of connector ids that are internally connected.
    public var buses: [[String]]

    public var key: String { "\(libraryID)@\(versionHash)" }

    public init(libraryID: String, versionHash: String, title: String, family: String = "", labelPrefix: String = "",
                tags: [String] = [], properties: [String: String] = [:], size: Vec2, graphicAsset: String,
                graphicKind: GraphicKind, connectors: [ConnectorDef] = [], buses: [[String]] = []) {
        self.libraryID = libraryID
        self.versionHash = versionHash
        self.title = title
        self.family = family
        self.labelPrefix = labelPrefix
        self.tags = tags
        self.properties = properties
        self.size = size
        self.graphicAsset = graphicAsset
        self.graphicKind = graphicKind
        self.connectors = connectors
        self.buses = buses
    }
}
