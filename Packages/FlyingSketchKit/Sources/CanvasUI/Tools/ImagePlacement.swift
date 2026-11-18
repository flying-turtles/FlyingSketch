import UIKit
import SketchCore

enum ImagePlacement {
    /// Placed width in mm; height follows the aspect ratio.
    static let width = 100.0

    /// Re-encodes `data` to PNG, stores it as an asset and inserts one `.insert` "Add Image" centred on `center`.
    /// Invalid or empty image data performs no edit and returns false.
    @discardableResult
    static func insert(_ data: Data, into model: DocumentModel, at center: Vec2) -> Bool {
        guard let source = UIImage(data: data), source.size.width > 0, source.size.height > 0,
              let (image, png) = normalized(source) else { return false }
        let size = Vec2(x: width, y: width * Double(image.size.height / image.size.width))
        let name = UUID().uuidString + ".png"
        let object = ImageObject(assetName: name, frame: Rect(origin: center - size / 2, size: size))
        model.addAssets([name: png])
        model.perform(.insert([.image(object)], at: nil), actionName: "Add Image")
        return true
    }

    /// Max long edge (px) of a stored image.
    static let maxPixelEdge: CGFloat = 4096

    /// Redraws through a renderer (applies EXIF orientation), long edge capped at `maxPixelEdge` px, 1 pt = 1 px.
    static func normalized(_ source: UIImage) -> (UIImage, Data)? {
        let pixelW = source.size.width * source.scale, pixelH = source.size.height * source.scale
        let k = min(1, maxPixelEdge / max(pixelW, pixelH))
        let target = CGSize(width: max((pixelW * k).rounded(), 1), height: max((pixelH * k).rounded(), 1))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let redrawn = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            source.draw(in: CGRect(origin: .zero, size: target))
        }
        guard let png = redrawn.pngData() else { return nil }
        return (redrawn, png)
    }
}
