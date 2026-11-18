import UIKit

/// Dashed rectangle around the selection, in view space.
final class SelectionOverlay {
    let layer = CAShapeLayer()

    init() {
        layer.fillColor = nil
        layer.strokeColor = UIColor.systemBlue.cgColor
        layer.lineWidth = 1.5
        layer.lineDashPattern = [6, 4]
        layer.actions = ["path": NSNull(), "bounds": NSNull(), "position": NSNull(), "hidden": NSNull()]
        layer.isHidden = true
    }

    private(set) var viewRect: CGRect?

    func setFrame(_ bounds: CGRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.frame = bounds
        CATransaction.commit()
    }

    func update(viewRect rect: CGRect?) {
        viewRect = rect
        guard let rect else {
            layer.isHidden = true
            layer.path = nil
            return
        }
        layer.path = CGPath(rect: rect.insetBy(dx: -4, dy: -4), transform: nil)
        layer.isHidden = false
    }
}
