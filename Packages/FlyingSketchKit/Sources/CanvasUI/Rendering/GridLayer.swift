import QuartzCore
import SketchCore

/// Minor (10 mm) and major (50 mm) grid lines in view coordinates; hidden below zoom 0.25.
final class GridLayer {
    static let minorSpacing = 10.0
    static let majorSpacing = 50.0
    static let minimumZoom = 0.25

    let layer = CALayer()
    private let minor = CAShapeLayer()
    private let major = CAShapeLayer()

    init() {
        for (line, gray, width) in [(minor, 0.90, 0.5), (major, 0.78, 0.75)] {
            line.fillColor = nil
            line.strokeColor = CGColor(gray: gray, alpha: 1)
            line.lineWidth = width
            layer.addSublayer(line)
        }
    }

    /// Draws only lines within `worldRect`.
    func update(viewport: Viewport, viewSize: Vec2, worldRect: Rect, visible: Bool) {
        layer.isHidden = !visible || viewport.zoom < Self.minimumZoom
        guard !layer.isHidden else { return }
        layer.frame = CGRect(x: 0, y: 0, width: viewSize.x, height: viewSize.y)
        let minorPath = CGMutablePath(), majorPath = CGMutablePath()
        func lines(from lo: Double, to hi: Double, vertical: Bool) {
            var i = Int((lo / Self.minorSpacing).rounded(.up))
            let end = Int((hi / Self.minorSpacing).rounded(.down))
            while i <= end {
                let w = Double(i) * Self.minorSpacing
                let isMajor = i % Int(Self.majorSpacing / Self.minorSpacing) == 0
                let a = vertical ? Vec2(x: w, y: worldRect.minY) : Vec2(x: worldRect.minX, y: w)
                let b = vertical ? Vec2(x: w, y: worldRect.maxY) : Vec2(x: worldRect.maxX, y: w)
                let va = viewport.worldToView(a, viewSize: viewSize), vb = viewport.worldToView(b, viewSize: viewSize)
                let path = isMajor ? majorPath : minorPath
                path.move(to: CGPoint(x: va.x, y: va.y))
                path.addLine(to: CGPoint(x: vb.x, y: vb.y))
                i += 1
            }
        }
        lines(from: worldRect.minX, to: worldRect.maxX, vertical: true)
        lines(from: worldRect.minY, to: worldRect.maxY, vertical: false)
        minor.frame = layer.bounds
        major.frame = layer.bounds
        minor.path = minorPath
        major.path = majorPath
    }
}
