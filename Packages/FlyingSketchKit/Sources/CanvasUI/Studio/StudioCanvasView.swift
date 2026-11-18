import PhotoPartKit
import SketchCore
import UIKit

public enum StudioCanvasMode: Equatable {
    case view, brush, trace, chooseInstance, crop, calibrate, pins

    /// Modes that display the cropped/rotated output preview instead of the raw source photo.
    var showsOutput: Bool {
        switch self {
        case .crop, .calibrate, .pins: true
        case .view, .brush, .trace, .chooseInstance: false
        }
    }
}

/// Photo studio canvas: source photo + mask overlay (or output preview), two-finger pan/pinch,
/// single-touch mask brush / lasso trace / instance pick. Stroke logic lives in `StudioInputController`.
public final class StudioCanvasView: UIView, UIGestureRecognizerDelegate {
    public static let zoomRange: ClosedRange<CGFloat> = 0.25...16
    static let dimOpacity: Float = 0.6
    static let tintOpacity: Float = 0.35

    public let session: StudioSession
    public var mode: StudioCanvasMode = .view {
        didSet {
            guard mode != oldValue else { return }
            cancelTool()
            refresh()
        }
    }
    /// Reported when a finished trace is rejected (e.g. `.traceTooShort`).
    public var onError: ((PhotoPartError) -> Void)?

    let input = StudioInputController()
    /// Zoom relative to fit, and offset (view pt) of the content centre from the bounds centre.
    private(set) var zoom: CGFloat = 1
    private(set) var offset: CGPoint = .zero

    private let contentLayer = CALayer()  // content space (source or output px) → view
    private let sourceLayer = CALayer()   // source px → content space
    private let imageLayer = CALayer()
    private let cutoutMaskLayer = CALayer()
    private let dimLayer = CALayer()
    private var tintLayers: [CALayer] = []
    private let liveLayer = CAShapeLayer()

    private var renderedMask: MaskBitmap?
    private var renderedInstances: [MaskBitmap] = []
    private var cutoutImageStale = true
    var activeTouch: UITouch?
    private var activeIsPencil: Bool?
    private let pan = UIPanGestureRecognizer()
    private let pinch = UIPinchGestureRecognizer()

    public init(session: StudioSession) {
        self.session = session
        super.init(frame: .zero)
        backgroundColor = .secondarySystemBackground
        isMultipleTouchEnabled = true
        clipsToBounds = true
        for l in [contentLayer, sourceLayer, imageLayer, dimLayer, cutoutMaskLayer] {
            l.anchorPoint = .zero
            l.position = .zero
        }
        contentLayer.masksToBounds = true
        imageLayer.contents = session.source.image
        imageLayer.magnificationFilter = .nearest // crisp pixels when zoomed in for mask edits
        dimLayer.backgroundColor = UIColor.black.cgColor
        dimLayer.opacity = Self.dimOpacity
        dimLayer.mask = CALayer()
        sourceLayer.addSublayer(imageLayer)
        sourceLayer.addSublayer(dimLayer)
        contentLayer.addSublayer(sourceLayer)
        layer.addSublayer(contentLayer)
        liveLayer.fillColor = nil
        liveLayer.lineCap = .round
        liveLayer.lineJoin = .round
        layer.addSublayer(liveLayer)

        pan.minimumNumberOfTouches = 2
        pan.maximumNumberOfTouches = 2
        for g in [pan, pinch] as [UIGestureRecognizer] {
            g.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
            g.delegate = self
            g.addTarget(self, action: #selector(handleGesture(_:)))
            addGestureRecognizer(g)
        }
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Geometry

    private var sourceSize: CGSize {
        CGSize(width: session.source.pixelSize.width, height: session.source.pixelSize.height)
    }

    private var contentSize: CGSize {
        guard mode.showsOutput else { return sourceSize }
        let o = session.draft.outputSize()
        return CGSize(width: o.x, height: o.y)
    }

    /// Identity in mask modes; the draft's crop/rotation (`toOutput`) in output-preview modes.
    private var sourceToContent: CGAffineTransform {
        guard mode.showsOutput else { return .identity }
        let draft = session.draft
        let o = draft.toOutput(Vec2(x: 0, y: 0))
        let ex = draft.toOutput(Vec2(x: 1, y: 0)), ey = draft.toOutput(Vec2(x: 0, y: 1))
        return CGAffineTransform(a: ex.x - o.x, b: ex.y - o.y, c: ey.x - o.x, d: ey.y - o.y, tx: o.x, ty: o.y)
    }

    private var fitScale: CGFloat {
        let c = contentSize
        guard bounds.width > 0, bounds.height > 0, c.width > 0, c.height > 0 else { return 1 }
        return min(bounds.width / c.width, bounds.height / c.height)
    }

    /// Aspect-fit × zoom, centred at bounds centre + offset.
    private var contentToView: CGAffineTransform {
        let s = fitScale * zoom, c = contentSize
        let centre = CGPoint(x: bounds.midX + offset.x, y: bounds.midY + offset.y)
        return CGAffineTransform(a: s, b: 0, c: 0, d: s,
                                 tx: centre.x - c.width / 2 * s, ty: centre.y - c.height / 2 * s)
    }

    var sourceToView: CGAffineTransform { sourceToContent.concatenating(contentToView) }

    /// View points → source pixels for the current mode, fit, zoom and pan.
    public var viewToSource: CGAffineTransform { sourceToView.inverted() }

    public func fitToBounds() {
        zoom = 1
        offset = .zero
        updateTransforms()
    }

    func pan(by d: CGPoint) {
        offset.x += d.x
        offset.y += d.y
        updateTransforms()
    }

    /// Zooms by `factor` keeping the content under `p` fixed; zoom is clamped to `zoomRange` × fit.
    func zoom(by factor: CGFloat, around p: CGPoint) {
        guard factor.isFinite, factor > 0 else { return }
        let next = min(max(zoom * factor, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
        let k = next / zoom
        let centre = CGPoint(x: bounds.midX + offset.x, y: bounds.midY + offset.y)
        offset = CGPoint(x: p.x + (centre.x - p.x) * k - bounds.midX, y: p.y + (centre.y - p.y) * k - bounds.midY)
        zoom = next
        updateTransforms()
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        updateTransforms()
    }

    private func updateTransforms() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let c = contentSize, s = sourceSize
        contentLayer.bounds = CGRect(origin: .zero, size: c)
        contentLayer.setAffineTransform(contentToView)
        sourceLayer.bounds = CGRect(origin: .zero, size: s)
        sourceLayer.setAffineTransform(sourceToContent)
        for l in [imageLayer, dimLayer, cutoutMaskLayer] + tintLayers {
            l.frame = CGRect(origin: .zero, size: s)
        }
        dimLayer.mask?.frame = dimLayer.bounds
        CATransaction.commit()
    }

    // MARK: Display

    /// Re-reads the session (mask, instances, cutout state, draft). Overlay images are rebuilt only on change.
    public func refresh() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if renderedMask != session.mask {
            renderedMask = session.mask
            dimLayer.mask?.contents = MaskOverlayImage.make(session.mask, inside: false, color: MaskOverlayImage.black)
            cutoutImageStale = true
        }
        let candidates: [MaskBitmap]
        if case .choosing = session.cutoutState { candidates = session.instances } else { candidates = [] }
        if candidates != renderedInstances { rebuildTints(candidates) }

        let output = mode.showsOutput
        if output, cutoutImageStale {
            cutoutMaskLayer.contents = MaskOverlayImage.make(session.mask, inside: true, color: MaskOverlayImage.black)
            cutoutImageStale = false
        }
        // Seam for Task 9: crop/calibrate/pins overlays go above `contentLayer`.
        imageLayer.mask = output ? cutoutMaskLayer : nil
        dimLayer.isHidden = output
        for l in tintLayers { l.isHidden = output }
        CATransaction.commit()
        updateTransforms()
    }

    private func rebuildTints(_ masks: [MaskBitmap]) {
        tintLayers.forEach { $0.removeFromSuperlayer() }
        tintLayers = masks.enumerated().map { i, m in
            let l = CALayer()
            l.anchorPoint = .zero
            l.contents = MaskOverlayImage.make(m, inside: true,
                                               color: MaskOverlayImage.instanceHues[i % MaskOverlayImage.instanceHues.count])
            l.opacity = Self.tintOpacity
            l.magnificationFilter = .nearest
            sourceLayer.addSublayer(l)
            return l
        }
        renderedInstances = masks
    }

    private func updateLiveLayer() {
        let pts = input.viewPoints
        guard let first = pts.first else { liveLayer.path = nil; return }
        let path = UIBezierPath()
        path.move(to: first)
        for p in pts.dropFirst() { path.addLine(to: p) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        switch mode {
        case .brush:
            if pts.count == 1 { path.addLine(to: first) } // round cap draws the first stamp
            let t = sourceToView
            liveLayer.lineWidth = 2 * session.brushRadius * hypot(t.a, t.b)
            liveLayer.strokeColor = (session.brushAdds ? UIColor.systemGreen : UIColor.systemRed)
                .withAlphaComponent(0.45).cgColor
        default:
            if pts.count > 2 { path.close() }
            liveLayer.lineWidth = 2
            liveLayer.strokeColor = UIColor.systemBlue.cgColor
        }
        liveLayer.path = path.cgPath
        CATransaction.commit()
    }

    // MARK: Tool input (testable without UITouch)

    private var modeHasTool: Bool {
        switch mode {
        case .brush, .trace, .chooseInstance: true
        case .view, .crop, .calibrate, .pins: false // Task 9 adds crop/calibrate/pin handling
        }
    }

    /// Returns true when this touch started the tool action.
    @discardableResult
    func touchDown(at p: CGPoint, isPencil: Bool, directTouchCount: Int) -> Bool {
        if input.isActive {
            if CanvasView.pencilPreemptsFinger(activeIsPencil: activeIsPencil, newTouchIsPencil: isPencil) {
                cancelTool() // Pencil takes over from a finger (e.g. resting palm)
            } else {
                if CanvasView.shouldCancelForMultiTouch(activeIsPencil: activeIsPencil, newTouchIsPencil: isPencil,
                                                        directTouchCount: directTouchCount) {
                    cancelTool() // second finger: pan/pinch take over
                }
                return false
            }
        }
        guard modeHasTool, isPencil || directTouchCount <= 1 else { return false }
        activeIsPencil = isPencil
        input.viewToSource = viewToSource
        input.begin(p)
        updateLiveLayer()
        return true
    }

    func touchMoved(to p: CGPoint) {
        guard input.isActive else { return }
        input.move(p)
        updateLiveLayer()
    }

    func touchEnded() {
        guard input.isActive else { return }
        let points = input.end()
        clearActive()
        switch mode {
        case .brush:
            session.applyBrush(points)
        case .trace:
            do { try session.applyTrace(points) } catch { onError?(error) }
        case .chooseInstance:
            if let p = points.first { session.chooseInstance(at: p) }
        case .view, .crop, .calibrate, .pins:
            break
        }
        refresh()
    }

    func cancelTool() {
        input.cancel()
        clearActive()
    }

    func gestureBegan() { cancelTool() }

    private func clearActive() {
        activeTouch = nil
        activeIsPencil = nil
        updateLiveLayer()
    }
}
