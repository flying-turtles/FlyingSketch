public enum PartDefinitionError: Error, Equatable {
    /// Size outside 0 < s <= `PartDefinition.maxExtent`, or a non-finite / |v| > `maxExtent` coordinate or leg width.
    case geometryOutOfRange
    case unsafeGraphicAsset
}

extension PartDefinition {
    /// Largest accepted part size and connector/leg coordinate (mm). Far below `DocumentPackage`'s limit, so an
    /// accepted definition never makes a saved document unopenable.
    public static let maxExtent = 10_000.0

    /// Gate for definitions from untrusted input (imported .fzpz, synced library, pasteboard, placement/update).
    public func validate() throws(PartDefinitionError) {
        try validateGeometry()
        guard isSafeAssetName(graphicAsset) else { throw .unsafeGraphicAsset }
    }

    /// Geometry part of `validate()` (usable before `graphicAsset` is assigned).
    public func validateGeometry() throws(PartDefinitionError) {
        let max = Self.maxExtent
        func extent(_ v: Double) -> Bool { v.isFinite && v > 0 && v <= max }
        func coord(_ v: Double) -> Bool { v.isFinite && abs(v) <= max }
        func point(_ p: Vec2) -> Bool { coord(p.x) && coord(p.y) }
        guard extent(size.x), extent(size.y) else { throw .geometryOutOfRange }
        for c in connectors {
            guard point(c.position) else { throw .geometryOutOfRange }
            if let leg = c.leg {
                guard point(leg.origin), point(leg.defaultEnd), leg.width.isFinite, leg.width >= 0, leg.width <= max else {
                    throw .geometryOutOfRange
                }
            }
        }
    }
}
