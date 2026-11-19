import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct PNGOptions: Hashable, Sendable {
    public enum Background: Hashable, Sendable { case white, transparent }
    public var dpi: Double = 300
    public var background: Background = .white
    public init(dpi: Double = 300, background: Background = .white) {
        self.dpi = dpi
        self.background = background
    }
}

public struct RasterResult: Sendable {
    public let data: Data
    public let width: Int
    public let height: Int
    public let effectiveDPI: Double
}

public enum RasterExporter {
    static let maxEdge = 16_384
    static let maxPixels = 50_000_000

    /// Cheap size: no allocation.
    public static func plan(_ content: ExportContent, options: PNGOptions) throws(ExportError) -> (width: Int, height: Int, effectiveDPI: Double) {
        let wMM = content.bounds.size.x, hMM = content.bounds.size.y
        guard options.dpi.isFinite, options.dpi > 0 else { throw .encodingFailed }
        guard wMM.isFinite, hMM.isFinite else { throw .tooLarge }
        guard wMM > 0, hMM > 0 else { throw .nothingToExport }
        /// Clamps to Int.max / 4 (still over every cap) so conversion and the w*h product never trap.
        func px(_ mm: Double, _ dpi: Double) -> Int {
            let v = (mm * dpi / 25.4).rounded(.up)
            return v >= Double(Int.max / 4) ? Int.max / 4 : max(1, Int(v))
        }
        func size(_ dpi: Double) -> (Int, Int) { (px(wMM, dpi), px(hMM, dpi)) }
        func fits(_ s: (Int, Int)) -> Bool { s.0 <= maxEdge && s.1 <= maxEdge && s.0 <= maxPixels / s.1 }

        var dpi = options.dpi
        var s = size(dpi)
        if !fits(s) {
            let byEdge = Double(maxEdge) * 25.4 / max(wMM, hMM)
            let byArea = (Double(maxPixels) / (wMM * hMM)).squareRoot() * 25.4
            dpi = min(dpi, byEdge, byArea)
            s = size(dpi)
            // ceil can overshoot by a pixel; nudge down until it fits.
            while !fits(s) && dpi >= 1 {
                dpi *= 0.9995
                s = size(dpi)
            }
        }
        guard dpi >= 1 else { throw .tooLarge }
        return (s.0, s.1, dpi)
    }

    public static func png(_ content: ExportContent, options: PNGOptions) throws(ExportError) -> RasterResult {
        let (w, h, dpi) = try plan(content, options: options)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw .encodingFailed }
        if options.background == .white {
            ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        }
        let pxPerMM = dpi / 25.4
        ctx.translateBy(x: 0, y: Double(h))
        ctx.scaleBy(x: pxPerMM, y: -pxPerMM)
        ctx.translateBy(x: -content.bounds.minX, y: -content.bounds.minY)
        SceneDrawer.draw(content, in: ctx, pixelSize: 25.4 / dpi)

        guard let image = ctx.makeImage() else { throw .encodingFailed }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { throw .encodingFailed }
        let props: [CFString: Any] = [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw .encodingFailed }
        return RasterResult(data: out as Data, width: w, height: h, effectiveDPI: dpi)
    }
}
