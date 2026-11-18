import UIKit
import SketchCore

/// Small off-main rasterization of a part graphic for library lists (keeps SwiftDraw inside CanvasUI).
public enum PartThumbnail {
    /// Renders `graphic` aspect-fit into `maxPixels` x `maxPixels` on a background thread; nil if undecodable.
    public static func render(_ graphic: Data, definition: PartDefinition, maxPixels: Int) async -> CGImage? {
        let size = definition.size
        guard size.x > 0, size.y > 0, maxPixels > 0 else { return nil }
        let k = Double(maxPixels) / max(size.x, size.y)
        let width = max(1, Int((size.x * k).rounded()))
        let height = max(1, Int((size.y * k).rounded()))
        let isSVG = definition.graphicKind == .svg
        return await Task.detached(priority: .utility) {
            CALayerObjectFactory.rasterize(data: graphic, isSVG: isSVG, width: width, height: height)
        }.value.image
    }
}
