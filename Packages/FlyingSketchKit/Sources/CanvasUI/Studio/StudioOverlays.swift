import PhotoPartKit
import SketchCore
import UIKit

/// One single-touch interaction in `.crop`, `.calibrate` or `.pins` mode.
/// Holds the pre-touch state so a cancel (second finger, mode change) can restore it.
struct OverlayDrag {
    enum Target: Equatable {
        /// Corner sign in the crop's own frame, e.g. (1, 1) = bottom-right.
        case cropCorner(Vec2)
        case cropMove
        /// Index into `calibrationPoints`.
        case calibration(Int)
        case pin(String)
        case empty
    }

    var target: Target
    let start: CGPoint
    let startDraft: PhotoPartDraft
    let startPendingA: Vec2?
    var moved = false
}

/// Crop, calibration and pin layers in view space, rebuilt from scratch on every layout.
final class StudioOverlayLayers {
    static let handleRadius: CGFloat = 8
    static let calibrationRadius: CGFloat = 8
    static let labelFont = UIFont.systemFont(ofSize: 12, weight: .medium)

    let layer = CALayer()
    private let cropOutline = CAShapeLayer()
    private let cropHandles = CAShapeLayer()
    private let calibration = CAShapeLayer()
    private var pinMarkers: [CAShapeLayer] = []
    private var pinLabels: [CATextLayer] = []

    struct PinStyle {
        var center: CGPoint
        var radius: CGFloat
        var color: UIColor
        var outOfBounds: Bool
        var selected: Bool
        var name: String
    }

    init() {
        for l in [cropOutline, cropHandles, calibration] {
            l.lineJoin = .round
            layer.addSublayer(l)
        }
        cropOutline.fillColor = nil
        cropOutline.strokeColor = UIColor.white.cgColor
        cropOutline.lineWidth = 1.5
        cropOutline.shadowColor = UIColor.black.cgColor
        cropOutline.shadowOpacity = 0.8
        cropOutline.shadowRadius = 1
        cropOutline.shadowOffset = .zero
        cropHandles.fillColor = UIColor.white.cgColor
        cropHandles.strokeColor = UIColor.systemBlue.cgColor
        cropHandles.lineWidth = 2
        calibration.fillColor = UIColor.systemYellow.withAlphaComponent(0.5).cgColor
        calibration.strokeColor = UIColor.systemYellow.cgColor
        calibration.lineWidth = 2
    }

    func hideAll() {
        for l in [cropOutline, cropHandles, calibration] { l.isHidden = true }
        showPins([], scale: 1)
    }

    /// `corners` in view pt, in order around the rectangle.
    func showCrop(_ corners: [CGPoint]) {
        guard let first = corners.first else { return }
        let outline = UIBezierPath()
        outline.move(to: first)
        for c in corners.dropFirst() { outline.addLine(to: c) }
        outline.close()
        cropOutline.path = outline.cgPath
        let handles = UIBezierPath()
        for c in corners { handles.append(Self.circle(c, Self.handleRadius)) }
        cropHandles.path = handles.cgPath
        cropOutline.isHidden = false
        cropHandles.isHidden = false
    }

    /// One or two calibration points in view pt; two are joined by a line.
    func showCalibration(_ points: [CGPoint]) {
        let path = UIBezierPath()
        if points.count == 2 {
            path.move(to: points[0])
            path.addLine(to: points[1])
        }
        for p in points { path.append(Self.circle(p, Self.calibrationRadius)) }
        calibration.path = path.cgPath
        calibration.isHidden = points.isEmpty
    }

    func showPins(_ pins: [PinStyle], scale: CGFloat) {
        while pinMarkers.count < pins.count {
            let m = CAShapeLayer(), t = CATextLayer()
            t.font = Self.labelFont
            t.fontSize = Self.labelFont.pointSize
            t.foregroundColor = UIColor.white.cgColor
            t.backgroundColor = UIColor.black.withAlphaComponent(0.55).cgColor
            t.cornerRadius = 3
            t.alignmentMode = .center
            layer.addSublayer(m)
            layer.addSublayer(t)
            pinMarkers.append(m)
            pinLabels.append(t)
        }
        for (i, (m, t)) in zip(pinMarkers, pinLabels).enumerated() {
            guard i < pins.count else { m.isHidden = true; t.isHidden = true; continue }
            let pin = pins[i]
            m.isHidden = false
            t.isHidden = false
            m.path = Self.circle(pin.center, pin.radius).cgPath
            m.fillColor = (pin.outOfBounds ? UIColor.systemRed : pin.color).withAlphaComponent(0.85).cgColor
            m.strokeColor = (pin.selected ? UIColor.systemYellow : pin.outOfBounds ? UIColor.systemRed : .white).cgColor
            m.lineWidth = pin.selected ? 3 : 1.5
            m.lineDashPattern = pin.outOfBounds && !pin.selected ? [3, 2] : nil
            let size = (pin.name as NSString).size(withAttributes: [.font: Self.labelFont])
            t.string = pin.name
            t.contentsScale = scale
            t.frame = CGRect(x: pin.center.x + pin.radius + 4, y: pin.center.y - (size.height + 2) / 2,
                             width: ceil(size.width) + 8, height: ceil(size.height) + 2)
        }
    }

    static func color(for role: PinRole?) -> UIColor {
        switch role {
        case .power: .systemRed
        case .ground: UIColor(white: 0.15, alpha: 1)
        case .digital: .systemBlue
        case .analog: .systemGreen
        case .i2cSDA, .i2cSCL: .systemPurple
        case .spi: .systemOrange
        case .uart: .systemTeal
        case .other, nil: .systemGray
        }
    }

    private static func circle(_ c: CGPoint, _ r: CGFloat) -> UIBezierPath {
        UIBezierPath(ovalIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
    }
}

// MARK: - Overlay geometry, hit-testing and interaction

extension StudioCanvasView {
    static let handleHitRadius: CGFloat = 22 // 44 pt hit area
    static let pinMinHitRadius: CGFloat = 22
    static let pinFallbackRadius: CGFloat = 10
    static let dragThreshold: CGFloat = 4
    static let minCropSide: Double = 16
    static let defaultCalibrationMM = 2.54

    private static let cornerSigns = [Vec2(x: -1, y: -1), Vec2(x: 1, y: -1), Vec2(x: 1, y: 1), Vec2(x: -1, y: 1)]

    // MARK: Geometry

    private func toView(_ source: Vec2) -> CGPoint { CGPoint(x: source.x, y: source.y).applying(sourceToView) }

    private func toSource(_ view: CGPoint) -> Vec2 {
        let s = view.applying(viewToSource)
        return Vec2(x: s.x, y: s.y)
    }

    /// View pt → output px (only meaningful in output-showing modes).
    private func toOutput(_ view: CGPoint) -> Vec2 {
        let o = view.applying(contentToView.inverted())
        return Vec2(x: o.x, y: o.y)
    }

    private func cropCorner(_ sign: Vec2, of crop: CropSpec) -> Vec2 {
        crop.center + Vec2(x: sign.x * crop.size.x / 2, y: sign.y * crop.size.y / 2).rotated(by: crop.angle)
    }

    /// Source px: the committed two points, or the pending first one.
    var calibrationPoints: [Vec2] {
        if case let .twoPoints(a, b, _)? = session.draft.scale { return [a, b] }
        return pendingCalibrationA.map { [$0] } ?? []
    }

    /// 1 mm in view pt when the draft has a scale, never below 10 pt.
    var pinMarkerRadius: CGFloat {
        guard let mmPerPixel = try? session.draft.mmPerPixel() else { return Self.pinFallbackRadius }
        let t = contentToView
        return max(hypot(t.a, t.b) / mmPerPixel, Self.pinFallbackRadius)
    }

    private func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

    // MARK: Hit-testing

    private func cropCornerHit(_ p: CGPoint) -> Vec2? {
        let crop = session.draft.crop
        return Self.cornerSigns
            .map { ($0, dist(toView(cropCorner($0, of: crop)), p)) }
            .filter { $0.1 <= Self.handleHitRadius }
            .min { $0.1 < $1.1 }?.0
    }

    private func cropContains(_ p: CGPoint) -> Bool {
        let crop = session.draft.crop
        let local = (toSource(p) - crop.center).rotated(by: -crop.angle)
        return abs(local.x) <= crop.size.x / 2 && abs(local.y) <= crop.size.y / 2
    }

    private func calibrationHit(_ p: CGPoint) -> Int? {
        calibrationPoints.enumerated()
            .map { ($0.offset, dist(toView($0.element), p)) }
            .filter { $0.1 <= Self.handleHitRadius }
            .min { $0.1 < $1.1 }?.0
    }

    /// Nearest pin within max(marker radius, 22 pt).
    func pinHit(_ p: CGPoint) -> String? {
        let r = max(pinMarkerRadius, Self.pinMinHitRadius)
        return session.draft.pins
            .map { ($0.id, dist(toView($0.position), p)) }
            .filter { $0.1 <= r }
            .min { $0.1 < $1.1 }?.0
    }

    // MARK: Interaction

    /// Returns false when the touch does nothing in this mode (e.g. outside the crop rectangle).
    func overlayBegin(at p: CGPoint) -> Bool {
        let target: OverlayDrag.Target
        switch mode {
        case .crop:
            if let corner = cropCornerHit(p) {
                target = .cropCorner(corner)
            } else if cropContains(p) {
                target = .cropMove
            } else {
                return false
            }
        case .calibrate:
            target = calibrationHit(p).map { .calibration($0) } ?? .empty
        case .pins:
            target = pinHit(p).map { .pin($0) } ?? .empty
        case .view, .brush, .trace, .chooseInstance:
            return false
        }
        overlayDrag = OverlayDrag(target: target, start: p, startDraft: session.draft,
                                  startPendingA: pendingCalibrationA)
        return true
    }

    func overlayMove(to p: CGPoint) {
        guard var drag = overlayDrag else { return }
        guard drag.moved || dist(p, drag.start) >= Self.dragThreshold else { return }
        drag.moved = true
        overlayDrag = drag
        let start = drag.startDraft.crop
        switch drag.target {
        case let .cropCorner(sign):
            let delta = (toSource(p) - toSource(drag.start)).rotated(by: -start.angle)
            let corner = Vec2(x: sign.x * start.size.x / 2, y: sign.y * start.size.y / 2) + delta
            let maxSide = 2 * hypot(Double(session.source.pixelSize.width), Double(session.source.pixelSize.height))
            session.draft.crop.size = Vec2(x: min(max(2 * abs(corner.x), Self.minCropSide), maxSide),
                                           y: min(max(2 * abs(corner.y), Self.minCropSide), maxSide))
        case .cropMove:
            session.draft.crop.center = start.center + toSource(p) - toSource(drag.start)
        case let .calibration(i):
            setCalibrationPoint(i, toSource(p))
        case let .pin(id):
            session.draft.movePin(id, toOutput: toOutput(p))
        case .empty:
            break
        }
        layoutOverlays()
    }

    /// Finishes the interaction; a touch that never passed the drag threshold acts as a tap.
    func overlayEnd() {
        guard let drag = overlayDrag else { return }
        overlayDrag = nil
        guard !drag.moved else { return }
        switch (mode, drag.target) {
        case (.calibrate, .empty):
            calibrationTap(toSource(drag.start))
        case (.pins, let .pin(id)):
            onPinSelected?(id)
        case (.pins, .empty):
            session.draft.addPin(atOutput: toOutput(drag.start))
        default:
            break
        }
    }

    /// Restores the draft and pending calibration point from before the touch.
    func overlayCancel() {
        guard let drag = overlayDrag else { return }
        overlayDrag = nil
        if drag.moved { session.draft = drag.startDraft }
        pendingCalibrationA = drag.startPendingA
        layoutOverlays()
    }

    private func calibrationTap(_ s: Vec2) {
        let pts = calibrationPoints
        switch pts.count {
        case 0:
            pendingCalibrationA = s
        case 1:
            commitCalibration(pts[0], s)
        default:
            let i = pts[0].distance(to: s) <= pts[1].distance(to: s) ? 0 : 1
            setCalibrationPoint(i, s)
        }
    }

    private func setCalibrationPoint(_ i: Int, _ s: Vec2) {
        var pts = calibrationPoints
        guard pts.indices.contains(i) else { return }
        pts[i] = s
        if pts.count == 2 { commitCalibration(pts[0], pts[1]) } else { pendingCalibrationA = s }
    }

    /// Writes `.twoPoints`, keeping an existing two-point distance (a `.width` scale is replaced).
    private func commitCalibration(_ a: Vec2, _ b: Vec2) {
        var mm = Self.defaultCalibrationMM
        if case let .twoPoints(_, _, existing)? = session.draft.scale { mm = existing }
        session.draft.scale = .twoPoints(a, b, mm: mm)
        pendingCalibrationA = nil
    }

    // MARK: Drawing

    /// Re-lays out every overlay layer in view space from the current session and transform.
    func layoutOverlays() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        overlays.hideAll()
        let draft = session.draft
        switch mode {
        case .crop:
            overlays.showCrop(Self.cornerSigns.map { toView(cropCorner($0, of: draft.crop)) })
        case .calibrate:
            overlays.showCalibration(calibrationPoints.map(toView))
        case .pins:
            let r = pinMarkerRadius, out = draft.outputSize()
            let styles = draft.pins.map { pin in
                let o = draft.toOutput(pin.position)
                return StudioOverlayLayers.PinStyle(
                    center: toView(pin.position), radius: r, color: StudioOverlayLayers.color(for: pin.role),
                    outOfBounds: o.x < 0 || o.y < 0 || o.x > out.x || o.y > out.y,
                    selected: pin.id == selectedPinID, name: pin.name)
            }
            let scale = traitCollection.displayScale
            overlays.showPins(styles, scale: scale > 0 ? scale : 2)
        case .view, .brush, .trace, .chooseInstance:
            break
        }
    }
}
