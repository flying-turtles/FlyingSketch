import CoreGraphics
import Foundation
import PartsKit
import SketchCore

public enum PhotoPartBuilder {
    public static let maxOutputEdge = 2048

    // MARK: Render

    /// Draws source and mask through the crop transform, multiplies colour by the mask, long edge <= 2048.
    public static func render(source: SourceImage, mask: MaskBitmap, draft: PhotoPartDraft) throws(PhotoPartError) -> Data {
        let src = source.image
        guard mask.width == src.width, mask.height == src.height,
              mask.bytes.count == mask.width * mask.height else { throw .maskSizeMismatch }
        let out = draft.outputSize()
        guard out.x.isFinite, out.y.isFinite, out.x > 0, out.y > 0 else { throw .emptyMask }
        let k = min(1, Double(maxOutputEdge) / max(out.x, out.y))
        let width = max(1, Int((out.x * k).rounded())), height = max(1, Int((out.y * k).rounded()))
        // Pixel scale actually applied (rounding can differ slightly per axis).
        let kx = Double(width) / out.x, ky = Double(height) / out.y

        // Image user space (y-up) -> output device space (y-up), via the draft's y-down mapping.
        func map(_ p: Vec2) -> Vec2 {
            let o = draft.toOutput(Vec2(x: p.x, y: Double(src.height) - p.y))
            return Vec2(x: o.x * kx, y: Double(height) - o.y * ky)
        }
        let m0 = map(.zero), mx = map(Vec2(x: 1, y: 0)), my = map(Vec2(x: 0, y: 1))
        let transform = CGAffineTransform(a: mx.x - m0.x, b: mx.y - m0.y, c: my.x - m0.x, d: my.y - m0.y,
                                          tx: m0.x, ty: m0.y)
        let rect = CGRect(x: 0, y: 0, width: src.width, height: src.height)

        guard let rgbSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let color = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: rgbSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let gray = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                   space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let colorBase = color.data, let grayBase = gray.data,
              let maskImage = CGImage(
                width: mask.width, height: mask.height, bitsPerComponent: 8, bitsPerPixel: 8,
                bytesPerRow: mask.width, space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: CGDataProvider(data: Data(mask.bytes) as CFData)!, decode: nil,
                shouldInterpolate: true, intent: .defaultIntent)
        else { throw .emptyMask }

        for ctx in [color, gray] {
            ctx.interpolationQuality = .high
            ctx.concatenate(transform)
        }
        color.draw(src, in: rect)
        gray.setFillColor(gray: 0, alpha: 1)
        gray.draw(maskImage, in: rect)

        let cRow = color.bytesPerRow, gRow = gray.bytesPerRow
        let cp = colorBase.assumingMemoryBound(to: UInt8.self), gp = grayBase.assumingMemoryBound(to: UInt8.self)
        var anyVisible = false
        for y in 0..<height {
            for x in 0..<width {
                let m = Int(gp[y * gRow + x]), i = y * cRow + x * 4
                for c in 0..<4 { cp[i + c] = UInt8((Int(cp[i + c]) * m + 127) / 255) }
                if cp[i + 3] != 0 { anyVisible = true }
            }
        }
        guard anyVisible else { throw .emptyMask }
        guard let image = color.makeImage() else { throw .emptyMask }
        let png = SourceImage(image: image).pngData()
        guard !png.isEmpty else { throw .emptyMask }
        return png
    }

    // MARK: Validate

    public static func validate(_ draft: PhotoPartDraft) throws(PhotoPartError) {
        guard !draft.metadata.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw .emptyTitle }
        let mm = try draft.mmPerPixel()
        let out = draft.outputSize()
        let eps = 1e-6
        for pin in draft.pins {
            let p = draft.toOutput(pin.position)
            guard p.x.isFinite, p.y.isFinite, p.x >= -eps, p.y >= -eps, p.x <= out.x + eps, p.y <= out.y + eps else {
                throw .pinOutside(pin.name)
            }
        }
        var seen = Set<String>()
        for pin in draft.pins {
            let name = pin.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { throw .emptyPinName(pin.id) }
            guard seen.insert(name.lowercased()).inserted else { throw .duplicatePinName(name) }
        }
        let ids = Set(draft.pins.map(\.id))
        var inBus = Set<String>()
        for bus in draft.buses {
            for id in bus {
                guard ids.contains(id) else { throw .unknownBusMember(id) }
                guard inBus.insert(id).inserted else { throw .pinInTwoBuses(id) }
            }
        }
        let limit = PartDefinition.maxExtent
        guard out.x * mm <= limit, out.y * mm <= limit else { throw .partTooLarge }
    }

    // MARK: Build

    public static func build(source: SourceImage, mask: MaskBitmap, draft: PhotoPartDraft) throws(PhotoPartError) -> LibraryPart {
        try validate(draft)
        let png = try render(source: source, mask: mask, draft: draft)
        let mm = try draft.mmPerPixel()
        let out = draft.outputSize()
        let meta = draft.metadata
        var def = PartDefinition(
            libraryID: draft.libraryID, versionHash: "",
            title: meta.title.trimmingCharacters(in: .whitespacesAndNewlines),
            family: meta.family, labelPrefix: meta.labelPrefix, tags: meta.tags, properties: meta.properties,
            size: out * mm, graphicAsset: "", graphicKind: .png,
            connectors: draft.pins.map {
                ConnectorDef(id: $0.id, name: $0.name.trimmingCharacters(in: .whitespacesAndNewlines),
                             description: $0.description.trimmingCharacters(in: .whitespacesAndNewlines), kind: $0.kind,
                             position: draft.toOutput($0.position) * mm, role: $0.role)
            },
            buses: draft.buses)
        // Hash-encoding failure or a definition the shared gate rejects both mean unusable geometry
        // (non-finite / out-of-range values), so they surface as `.partTooLarge`.
        do {
            let hash = try PartHash.versionHash(definitionWithoutHash: def, graphic: png)
            def.versionHash = hash
            def.graphicAsset = "part-\(hash).png"
            try def.validate()
        } catch {
            throw .partTooLarge
        }
        return LibraryPart(definition: def, graphic: png, source: .personal)
    }
}
