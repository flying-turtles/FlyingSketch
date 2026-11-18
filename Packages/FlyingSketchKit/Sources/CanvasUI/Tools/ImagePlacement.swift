import UIKit
import SketchCore

enum ImagePlacement {
    /// Placed width in mm; height follows the aspect ratio.
    static let width = 100.0

    /// Re-encodes `data` to PNG, stores it as an asset and inserts one `.insert` "Add Image" centred on `center`.
    /// Invalid or empty image data performs no edit and returns false.
    @discardableResult
    static func insert(_ data: Data, into model: DocumentModel, at center: Vec2) -> Bool {
        guard let image = UIImage(data: data), image.size.width > 0, image.size.height > 0,
              let png = image.pngData() else { return false }
        let size = Vec2(x: width, y: width * Double(image.size.height / image.size.width))
        let name = UUID().uuidString + ".png"
        let object = ImageObject(assetName: name, frame: Rect(origin: center - size / 2, size: size))
        model.addAssets([name: png])
        model.perform(.insert([.image(object)], at: nil), actionName: "Add Image")
        return true
    }
}
