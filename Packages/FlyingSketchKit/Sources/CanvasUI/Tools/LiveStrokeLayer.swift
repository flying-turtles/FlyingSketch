import UIKit
import SketchCore
import InkEngine

/// Low-latency in-progress stroke. View-coordinate path, implicit animations off.
final class LiveStrokeLayer {
    let layer = CAShapeLayer()

    init() {
        layer.fillRule = .nonZero
        layer.actions = ["path": NSNull(), "fillColor": NSNull(), "opacity": NSNull(),
                         "bounds": NSNull(), "position": NSNull(), "compositingFilter": NSNull()]
    }

    func setFrame(_ bounds: CGRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.frame = bounds
        CATransaction.commit()
    }

    /// Same polygon function, pixelSize and style as `CALayerObjectFactory`, so lift-off shows no jump.
    func update(points: [InkPoint], tool: InkTool, color: RGBAColor, width: Double, viewport: Viewport, viewSize: Vec2) {
        let pixelSize = 1 / (Viewport.pointsPerMillimetre * viewport.zoom)
        let poly = StrokeOutline.polygon(points, baseWidth: width, tool: tool, pixelSize: pixelSize)
        let path = CGMutablePath()
        if let first = poly.first {
            let f = viewport.worldToView(first, viewSize: viewSize)
            path.move(to: CGPoint(x: f.x, y: f.y))
            for p in poly.dropFirst() {
                let v = viewport.worldToView(p, viewSize: viewSize)
                path.addLine(to: CGPoint(x: v.x, y: v.y))
            }
            path.closeSubpath()
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.fillColor = CGColor(red: color.r, green: color.g, blue: color.b, alpha: color.a)
        if tool == .highlighter {
            layer.opacity = 0.35
            layer.compositingFilter = "multiplyBlendMode"
        } else {
            layer.opacity = 1
            layer.compositingFilter = nil
        }
        layer.path = path
        CATransaction.commit()
    }

    func clear() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.path = nil
        CATransaction.commit()
    }
}
