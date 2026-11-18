import UIKit
import SketchCore
import InkEngine
import PartsKit
import SwiftDraw
import ImageIO

/// Renderer seam: builds/updates one layer per scene object, geometry in view coordinates.
protocol ObjectLayerFactory {
    func makeLayer(for object: SceneObject, viewport: Viewport, viewSize: Vec2) -> CALayer
    func update(_ layer: CALayer, for object: SceneObject, viewport: Viewport, viewSize: Vec2)
    /// Called before each settle so image and part layers can resolve `document.assets` and `document.parts`.
    func prepare(document: SketchDocument)
}

extension ObjectLayerFactory {
    func prepare(document: SketchDocument) {}
}

/// Part layer: zero-size container in view coordinates. `body` holds the (rotated) graphic; legs and the
/// placeholder are siblings above it, already in view coordinates (never rotated twice).
nonisolated final class PartLayer: CALayer {
    let body = CALayer()
    var legLayers: [CAShapeLayer] = []
    var placeholderShape: CAShapeLayer?
    var placeholderText: CATextLayer?
    /// Raster this layer currently wants; async results for other keys are ignored.
    var desiredKey: PartRasterCache.Key?
    /// Asset whose image `body.contents` currently shows (cleared when the definition changes).
    var displayedAsset: String?
    /// Last inputs, so a failed async raster can switch this layer to the placeholder.
    var lastInput: (instance: PartInstance, viewport: Viewport, viewSize: Vec2)?
    /// Pixel size of the wanted raster (debug/test).
    var rasterPixelSize: CGSize = .zero
    var isPlaceholder: Bool { placeholderShape != nil }

    override init() {
        super.init()
        body.contentsGravity = .resize
        body.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        addSublayer(body)
    }

    override init(layer: Any) { super.init(layer: layer) }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
}

/// Core Animation implementation. Layers are sized to their content; paths are local to the layer frame.
final class CALayerObjectFactory: ObjectLayerFactory {
    var screenScale: CGFloat = 2
    private var assets: [String: Data] = [:]
    private var parts: [String: PartDefinition] = [:]
    private var imageCache: [String: CGImage] = [:]

    let rasterCache: PartRasterCache
    /// Number of rasterizations started (debug/test).
    private(set) var rasterJobCount = 0
    private var pending: [PartRasterCache.Key: [WeakPartLayer]] = [:]
    private var rasterTasks: [PartRasterCache.Key: Task<Void, Never>] = [:]
    /// Keys whose rasterization failed; not retried (no re-parse on every settle).
    private var failedRasters: Set<PartRasterCache.Key> = []

    private struct WeakPartLayer { weak var layer: PartLayer? }

    init(rasterCache: PartRasterCache = PartRasterCache()) {
        self.rasterCache = rasterCache
    }

    func prepare(document: SketchDocument) {
        assets = document.assets
        parts = document.parts
    }

    /// Waits for every started rasterization and its main-actor delivery (tests).
    func waitForRasters() async {
        while !rasterTasks.isEmpty {
            let tasks = Array(rasterTasks.values)
            for t in tasks { await t.value }
        }
    }

    func makeLayer(for object: SceneObject, viewport: Viewport, viewSize: Vec2) -> CALayer {
        let layer: CALayer
        switch object {
        case .ink, .shape: layer = CAShapeLayer()
        case .text: layer = CATextLayer()
        case .image: layer = CALayer()
        case .part: layer = PartLayer()
        case .wire: layer = CAShapeLayer()
        }
        layer.contentsScale = screenScale
        update(layer, for: object, viewport: viewport, viewSize: viewSize)
        return layer
    }

    func update(_ layer: CALayer, for object: SceneObject, viewport: Viewport, viewSize: Vec2) {
        switch object {
        case .ink(let s): updateInk(layer, s, viewport, viewSize)
        case .shape(let s): updateShape(layer, s, viewport, viewSize)
        case .text(let t): updateText(layer, t, viewport, viewSize)
        case .image(let i): updateImage(layer, i, viewport, viewSize)
        case .part(let p): updatePart(layer, p, viewport, viewSize)
        case .wire(let w): updateWire(layer, w, viewport, viewSize)
        }
    }

    private func pt(_ p: Vec2, _ vp: Viewport, _ size: Vec2) -> CGPoint {
        let v = vp.worldToView(p, viewSize: size)
        return CGPoint(x: v.x, y: v.y)
    }

    private func mm(_ vp: Viewport) -> Double { Viewport.pointsPerMillimetre * vp.zoom }

    private func cg(_ c: RGBAColor) -> CGColor { CGColor(red: c.r, green: c.g, blue: c.b, alpha: c.a) }

    /// Frames the layer around `path` (view coords) and stores the path relative to the frame origin.
    private func setPath(_ layer: CAShapeLayer, _ path: CGPath, pad: CGFloat) {
        let box = path.boundingBoxOfPath.insetBy(dx: -pad, dy: -pad)
        var shift = CGAffineTransform(translationX: -box.minX, y: -box.minY)
        layer.frame = box
        layer.path = path.copy(using: &shift)
    }

    private func updateInk(_ layer: CALayer, _ s: InkStroke, _ vp: Viewport, _ size: Vec2) {
        guard let layer = layer as? CAShapeLayer else { return }
        let pixelSize = 1 / mm(vp)
        let poly = StrokeOutline.polygon(s.points, baseWidth: s.baseWidth, tool: s.tool, pixelSize: pixelSize)
        let path = CGMutablePath()
        if let first = poly.first {
            path.move(to: pt(first, vp, size))
            for p in poly.dropFirst() { path.addLine(to: pt(p, vp, size)) }
            path.closeSubpath()
        }
        setPath(layer, path, pad: 0)
        layer.fillColor = cg(s.color)
        layer.strokeColor = nil
        layer.fillRule = .nonZero
        if s.tool == .highlighter {
            layer.opacity = 0.35
            layer.compositingFilter = "multiplyBlendMode"
        } else {
            layer.opacity = 1
            layer.compositingFilter = nil
        }
    }

    private func updateShape(_ layer: CALayer, _ s: ShapeObject, _ vp: Viewport, _ size: Vec2) {
        guard let layer = layer as? CAShapeLayer else { return }
        let a = pt(s.start, vp, size), b = pt(s.end, vp, size)
        let rect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
        let path = CGMutablePath()
        switch s.kind {
        case .line, .arrow:
            path.move(to: a)
            path.addLine(to: b)
            if s.kind == .arrow {
                let dir = (s.end - s.start).normalized
                let head = max(s.lineWidth * 5, 4)
                for sign in [1.0, -1.0] {
                    let back = dir.rotated(by: .pi + sign * 0.45) * head
                    path.move(to: b)
                    path.addLine(to: pt(s.end + back, vp, size))
                }
            }
        case .rectangle: path.addRect(rect)
        case .ellipse: path.addEllipse(in: rect)
        }
        let lineWidth = s.lineWidth * mm(vp)
        setPath(layer, path, pad: lineWidth)
        layer.lineWidth = lineWidth
        layer.lineCap = .round
        layer.lineJoin = .round
        layer.strokeColor = cg(s.strokeColor)
        let fillable = s.kind == .rectangle || s.kind == .ellipse
        layer.fillColor = fillable ? s.fillColor.map(cg) : nil
        layer.opacity = 1
        layer.compositingFilter = nil
    }

    /// Max backing-store edge (px) for one text layer; extreme zoom blurs instead of exhausting memory.
    nonisolated static let maxBackingEdge: CGFloat = 4096

    static func cappedContentsScale(width: CGFloat, height: CGFloat, screenScale: CGFloat) -> CGFloat {
        guard width > 0, height > 0 else { return screenScale }
        return min(screenScale, maxBackingEdge / width, maxBackingEdge / height)
    }

    private func updateText(_ layer: CALayer, _ t: TextObject, _ vp: Viewport, _ size: Vec2) {
        guard let layer = layer as? CATextLayer else { return }
        let fontSize = t.fontSize * mm(vp)
        let font = UIFont(name: "Helvetica", size: fontSize) ?? .systemFont(ofSize: fontSize)
        let measured = (t.text as NSString).size(withAttributes: [.font: font])
        let width = ceil(measured.width) + 2, height = ceil(measured.height) + 2
        layer.contentsScale = Self.cappedContentsScale(width: width, height: height, screenScale: screenScale)
        layer.string = t.text
        layer.font = "Helvetica" as CFString
        layer.fontSize = fontSize
        layer.foregroundColor = cg(t.color)
        layer.alignmentMode = .left
        layer.isWrapped = false
        layer.anchorPoint = .zero
        layer.bounds = CGRect(x: 0, y: 0, width: width, height: height)
        layer.position = pt(t.position, vp, size)
        layer.transform = CATransform3DMakeRotation(t.rotation, 0, 0, 1)
    }

    private func updateImage(_ layer: CALayer, _ i: ImageObject, _ vp: Viewport, _ size: Vec2) {
        let s = mm(vp)
        layer.contents = image(named: i.assetName)
        layer.contentsGravity = .resize
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer.bounds = CGRect(x: 0, y: 0, width: i.frame.size.x * s, height: i.frame.size.y * s)
        let center = Vec2(x: i.frame.minX + i.frame.size.x / 2, y: i.frame.minY + i.frame.size.y / 2)
        layer.position = pt(center, vp, size)
        layer.transform = CATransform3DMakeRotation(i.rotation, 0, 0, 1)
    }

    private func image(named name: String) -> CGImage? {
        if let cached = imageCache[name] { return cached }
        guard let data = assets[name], let cg = UIImage(data: data)?.cgImage else { return nil }
        imageCache[name] = cg
        return cg
    }

    // MARK: Parts and wires

    private func updateWire(_ layer: CALayer, _ w: Wire, _ vp: Viewport, _ size: Vec2) {
        guard let layer = layer as? CAShapeLayer else { return }
        let path = CGMutablePath()
        let points = w.polyline.map { pt($0, vp, size) }
        path.move(to: points[0])
        for p in points.dropFirst() { path.addLine(to: p) }
        let radius = Self.freeEndRadius * mm(vp)
        for end in [w.start, w.end] where end.attachment == nil {
            let c = pt(end.position, vp, size)
            path.addEllipse(in: CGRect(x: c.x - radius, y: c.y - radius, width: radius * 2, height: radius * 2))
        }
        let lineWidth = w.width * mm(vp)
        setPath(layer, path, pad: lineWidth)
        layer.lineWidth = lineWidth
        layer.lineCap = .round
        layer.lineJoin = .round
        layer.strokeColor = cg(w.color)
        layer.fillColor = nil
        layer.opacity = 1
        layer.compositingFilter = nil
    }

    /// Radius (mm) of the open circle marking a free wire end.
    static let freeEndRadius = 0.6
    /// Side (mm) of the placeholder square for unknown part definitions.
    static let placeholderSide = 10.0

    private func updatePart(_ layer: CALayer, _ p: PartInstance, _ vp: Viewport, _ size: Vec2) {
        guard let layer = layer as? PartLayer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        layer.lastInput = (p, vp, size)
        guard let def = parts[p.definitionKey] else {
            clearLegs(layer)
            showPlaceholder(layer, p, vp, size)
            return
        }
        let s = mm(vp)
        layer.body.bounds = CGRect(x: 0, y: 0, width: def.size.x * s, height: def.size.y * s)
        layer.body.position = pt(p.center, vp, size)
        let turns = ((p.quarterTurns % 4) + 4) % 4
        layer.body.transform = CATransform3DMakeRotation(CGFloat(turns) * .pi / 2, 0, 0, 1)
        updateLegs(layer, p, def, vp, size)
        if requestRaster(for: layer, def: def, vp: vp) {
            removePlaceholder(layer)
            layer.body.isHidden = false
        } else {
            showPlaceholder(layer, p, vp, size)
        }
    }

    private func clearLegs(_ layer: PartLayer) {
        for l in layer.legLayers { l.removeFromSuperlayer() }
        layer.legLayers.removeAll()
    }

    private func updateLegs(_ layer: PartLayer, _ p: PartInstance, _ def: PartDefinition, _ vp: Viewport, _ size: Vec2) {
        let legs = def.connectors.compactMap { c in p.legSegment(for: c, in: def).map { (c, $0) } }
        while layer.legLayers.count > legs.count { layer.legLayers.removeLast().removeFromSuperlayer() }
        while layer.legLayers.count < legs.count {
            let l = CAShapeLayer()
            layer.legLayers.append(l)
            layer.addSublayer(l)
        }
        for (l, (c, seg)) in zip(layer.legLayers, legs) {
            guard let spec = c.leg else { continue }
            l.contentsScale = screenScale
            let path = CGMutablePath()
            path.move(to: pt(seg.origin, vp, size))
            path.addLine(to: pt(seg.end, vp, size))
            let lineWidth = spec.width * mm(vp)
            setPath(l, path, pad: lineWidth)
            l.lineWidth = lineWidth
            l.lineCap = .round
            l.strokeColor = cg(spec.color)
            l.fillColor = nil
        }
    }

    private func removePlaceholder(_ layer: PartLayer) {
        layer.placeholderShape?.removeFromSuperlayer()
        layer.placeholderText?.removeFromSuperlayer()
        layer.placeholderShape = nil
        layer.placeholderText = nil
    }

    private func showPlaceholder(_ layer: PartLayer, _ p: PartInstance, _ vp: Viewport, _ size: Vec2) {
        layer.body.isHidden = true
        layer.body.contents = nil
        layer.desiredKey = nil
        layer.displayedAsset = nil
        let shape: CAShapeLayer, text: CATextLayer
        if let s = layer.placeholderShape, let t = layer.placeholderText {
            shape = s
            text = t
        } else {
            shape = CAShapeLayer()
            text = CATextLayer()
            shape.contentsScale = screenScale
            layer.addSublayer(shape)
            layer.addSublayer(text)
            layer.placeholderShape = shape
            layer.placeholderText = text
        }
        let s = mm(vp)
        let side = Self.placeholderSide * s
        let c = pt(p.center, vp, size)
        let lineWidth = max(0.5, 0.4 * s)
        shape.frame = CGRect(x: c.x - side / 2 - lineWidth, y: c.y - side / 2 - lineWidth,
                             width: side + lineWidth * 2, height: side + lineWidth * 2)
        shape.path = CGPath(rect: CGRect(x: lineWidth, y: lineWidth, width: side, height: side), transform: nil)
        shape.lineWidth = lineWidth
        shape.lineDashPattern = [NSNumber(value: lineWidth * 4), NSNumber(value: lineWidth * 3)]
        shape.strokeColor = CGColor(gray: 0.4, alpha: 1)
        shape.fillColor = nil

        let fontSize = 2.5 * s
        let font = UIFont.systemFont(ofSize: fontSize)
        let label = p.label.isEmpty ? "?" : p.label
        let measured = (label as NSString).size(withAttributes: [.font: font])
        let width = ceil(measured.width) + 2, height = ceil(measured.height) + 2
        text.contentsScale = Self.cappedContentsScale(width: width, height: height, screenScale: screenScale)
        text.string = label
        text.font = font
        text.fontSize = fontSize
        text.foregroundColor = CGColor(gray: 0.4, alpha: 1)
        text.alignmentMode = .center
        text.isWrapped = false
        text.bounds = CGRect(x: 0, y: 0, width: width, height: height)
        text.position = c
    }

    // MARK: Raster

    /// Raster scale bucket for the viewport, capped so neither edge exceeds `maxBackingEdge` pixels.
    func rasterBucket(for def: PartDefinition, vp: Viewport) -> Int {
        let needed = mm(vp) * screenScale
        var bucket = PartRasterCache.bucket(forPixelsPerMM: needed)
        let longest = max(def.size.x, def.size.y)
        if longest > 0 {
            let cap = Int(floor(log2(Double(Self.maxBackingEdge) / longest)))
            bucket = min(bucket, cap)
        }
        return bucket
    }

    /// Returns false when the graphic cannot be shown (missing asset or failed decode): caller shows the placeholder.
    private func requestRaster(for layer: PartLayer, def: PartDefinition, vp: Viewport) -> Bool {
        let isSVG = def.graphicKind == .svg
        let bucket = rasterBucket(for: def, vp: vp)
        let key = PartRasterCache.Key(asset: def.graphicAsset, bucket: bucket)
        let scale = pow(2.0, Double(bucket))
        let width = max(1, Int(ceil(def.size.x * scale)))
        let height = max(1, Int(ceil(def.size.y * scale)))
        layer.desiredKey = key
        layer.rasterPixelSize = CGSize(width: width, height: height)
        if layer.displayedAsset != def.graphicAsset {
            layer.body.contents = nil
            layer.displayedAsset = def.graphicAsset
        }
        if let image = rasterCache.image(for: key) {
            layer.body.contents = image
            return true
        }
        if failedRasters.contains(key) { return false }
        // Blurry stand-in until the right bucket is ready.
        if layer.body.contents == nil, let stand = rasterCache.anyImage(forAsset: def.graphicAsset) {
            layer.body.contents = stand
        }
        if pending[key] != nil {
            pending[key]?.append(WeakPartLayer(layer: layer))
            return true
        }
        guard let data = assets[def.graphicAsset] else { return false }
        pending[key] = [WeakPartLayer(layer: layer)]
        rasterJobCount += 1
        rasterTasks[key] = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Self.rasterize(data: data, isSVG: isSVG, width: width, height: height)
            }.value
            self?.finishRaster(key, result.image)
        }
        return true
    }

    private func finishRaster(_ key: PartRasterCache.Key, _ image: CGImage?) {
        rasterTasks[key] = nil
        let waiting = pending.removeValue(forKey: key) ?? []
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard let image else {
            failedRasters.insert(key)
            for w in waiting {
                if let l = w.layer, l.desiredKey == key, let i = l.lastInput {
                    updatePart(l, i.instance, i.viewport, i.viewSize)
                }
            }
            return
        }
        rasterCache.insert(image, for: key)
        for w in waiting {
            if let l = w.layer, l.desiredKey == key { l.body.contents = image }
        }
    }

    struct RasterResult: @unchecked Sendable { var image: CGImage? }

    /// SVG renders with a pinned standard-range 8-bit format (4 B/px; SwiftDraw's own `rasterize` would use the
    /// screen's preferred, possibly extended-range, format). PNGs are downsampled so neither edge exceeds the target.
    nonisolated static func rasterize(data: Data, isSVG: Bool, width: Int, height: Int) -> RasterResult {
        if isSVG {
            // Untrusted bytes (document, pasteboard): same guard as import; failure -> nil -> placeholder.
            guard PartInputGuard.isAcceptableSVG(data), let svg = SVG(data: data) else { return RasterResult(image: nil) }
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = false
            format.preferredRange = .standard
            let rect = CGRect(x: 0, y: 0, width: width, height: height)
            let image = UIGraphicsImageRenderer(size: rect.size, format: format).image { $0.draw(svg, in: rect) }
            return RasterResult(image: image.cgImage)
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let full = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return RasterResult(image: nil) }
        let limit = min(max(width, height), Int(maxBackingEdge))
        guard max(full.width, full.height) > limit else { return RasterResult(image: full) }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: limit,
        ]
        return RasterResult(image: CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) ?? full)
    }
}
