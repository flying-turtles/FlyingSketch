import UIKit
import SketchCore
import InkEngine

/// Renderer seam: builds/updates one layer per scene object, geometry in view coordinates.
protocol ObjectLayerFactory {
    func makeLayer(for object: SceneObject, viewport: Viewport, viewSize: Vec2) -> CALayer
    func update(_ layer: CALayer, for object: SceneObject, viewport: Viewport, viewSize: Vec2)
    /// Called before each settle so image layers can resolve `document.assets`.
    func prepare(assets: [String: Data])
}

extension ObjectLayerFactory {
    func prepare(assets: [String: Data]) {}
}

/// Core Animation implementation. Layers are sized to their content; paths are local to the layer frame.
final class CALayerObjectFactory: ObjectLayerFactory {
    var screenScale: CGFloat = 2
    private var assets: [String: Data] = [:]
    private var imageCache: [String: CGImage] = [:]

    func prepare(assets: [String: Data]) {
        self.assets = assets
    }

    func makeLayer(for object: SceneObject, viewport: Viewport, viewSize: Vec2) -> CALayer {
        let layer: CALayer
        switch object {
        case .ink, .shape: layer = CAShapeLayer()
        case .text: layer = CATextLayer()
        case .image: layer = CALayer()
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
    static let maxBackingEdge: CGFloat = 4096

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
}
