import UIKit
import SketchCore

// CanvasView's own `bounds` shadows the SketchCore function inside the class.
private func worldBounds(_ o: SceneObject) -> Rect { bounds(of: o) }

/// Live editor for a text object being placed or edited.
struct TextSession {
    let view: UITextView
    /// Top-left in world mm.
    let position: Vec2
    let existing: TextObject?
    let color: RGBAColor
    let fontSize: Double
}

/// Shape, text and image tools.
extension CanvasView {
    // MARK: Shapes

    /// Hardware-keyboard Shift on the touch's event.
    private func isConstraining(_ event: UIEvent?) -> Bool {
        event?.modifierFlags.contains(.shift) == true
    }

    func beginShape(at world: Vec2, event: UIEvent?) {
        guard case .shape(let kind) = toolState.kind else { return }
        shapes.strokeColor = toolState.color
        shapes.lineWidth = toolState.inkWidth
        shapes.snapsToGrid = snapsToGrid
        shapes.minimumLength = 1 / (Viewport.pointsPerMillimetre * currentViewport.zoom) // 1 pt
        shapes.begin(at: world, kind: kind)
        moveShape(to: world, event: event)
    }

    func moveShape(to world: Vec2, event: UIEvent?) {
        shapes.move(to: world, constrain: isConstraining(event))
        guard let shape = shapes.current else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let preview = shapePreview {
            factory.update(preview, for: .shape(shape), viewport: currentViewport, viewSize: viewSize)
        } else {
            let preview = factory.makeLayer(for: .shape(shape), viewport: currentViewport, viewSize: viewSize)
            layer.addSublayer(preview)
            shapePreview = preview
        }
        CATransaction.commit()
    }

    func endShape() {
        // One transaction: committed layer appears and preview disappears together.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shapes.end()
        removeShapePreview()
        CATransaction.commit()
    }

    func cancelShape() {
        shapes.cancel()
        removeShapePreview()
    }

    private func removeShapePreview() {
        shapePreview?.removeFromSuperlayer()
        shapePreview = nil
    }

    // MARK: Text

    private func textObject(at viewPoint: CGPoint) -> TextObject? {
        let w = worldPoint(viewPoint)
        let tol = Self.hitSlop / (Viewport.pointsPerMillimetre * currentViewport.zoom)
        let box = Rect(origin: w - Vec2(x: tol, y: tol), size: Vec2(x: 2 * tol, y: 2 * tol))
        for case .text(let t) in renderer.objects(in: box).reversed() where worldBounds(.text(t)).contains(w) {
            return t
        }
        return nil
    }

    /// Opens an editor at `viewPoint`: on an existing text (edit in place) or a fresh spot.
    func beginTextEditing(at viewPoint: CGPoint) {
        endTextEditing()
        let existing = textObject(at: viewPoint)
        let position = existing?.position ?? (snapsToGrid ? snap(worldPoint(viewPoint), grid: ShapeController.gridSize)
                                                          : worldPoint(viewPoint))
        let color = existing?.color ?? toolState.color
        let fontSize = existing?.fontSize ?? textFontSize

        let tv = UITextView()
        tv.backgroundColor = .clear
        tv.textContainerInset = .zero
        tv.textContainer.lineFragmentPadding = 0
        tv.isScrollEnabled = false
        // No wrapping: the committed CATextLayer is unwrapped too, so editor and result agree.
        tv.textContainer.widthTracksTextView = false
        tv.textContainer.lineBreakMode = .byClipping
        tv.textContainer.size = CGSize(width: 1_000_000, height: CGFloat.greatestFiniteMagnitude)
        tv.clipsToBounds = false
        tv.autocorrectionType = .no
        tv.delegate = self
        tv.text = existing?.text ?? ""
        tv.textColor = UIColor(red: color.r, green: color.g, blue: color.b, alpha: color.a)
        textSession = TextSession(view: tv, position: position, existing: existing, color: color, fontSize: fontSize)
        layoutTextEditor()
        addSubview(tv)
        if let existing { renderer.hiddenIDs.insert(existing.id) }
        tv.becomeFirstResponder()
    }

    /// Positions and scales the editor for the current viewport.
    func layoutTextEditor() {
        guard let s = textSession else { return }
        let scale = Viewport.pointsPerMillimetre * currentViewport.zoom
        let origin = currentViewport.worldToView(s.position, viewSize: viewSize)
        let font = UIFont(name: "Helvetica", size: s.fontSize * scale) ?? .systemFont(ofSize: s.fontSize * scale)
        s.view.font = font
        let lines = (s.view.text ?? "").components(separatedBy: "\n")
        let longest = lines.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        let width = max(ceil(longest) + font.pointSize * 2, font.pointSize * 4)
        let height = font.lineHeight * CGFloat(max(lines.count, 1))
        s.view.frame = CGRect(x: origin.x, y: origin.y, width: width, height: height)
    }

    /// Commits (insert / replace / delete) and tears the editor down. No-op when not editing.
    func endTextEditing() {
        guard let s = textSession else { return }
        textSession = nil
        s.view.delegate = nil
        let text = s.view.text ?? ""
        s.view.removeFromSuperview() // resigns first responder
        if let id = s.existing?.id { renderer.hiddenIDs.remove(id) }
        textController.commit(text, existing: s.existing, position: s.position, fontSize: s.fontSize, color: s.color)
    }

    // MARK: Images

    /// Inserts image data at the viewport centre and selects it. False (no edit) when the data is not an image.
    @discardableResult
    public func insertImage(_ data: Data) -> Bool {
        let c = viewport.center
        let centre = snapsToGrid ? snap(c, grid: ShapeController.gridSize) : c
        guard ImagePlacement.insert(data, into: model, at: centre), let last = model.document.objects.last else { return false }
        selection.ids = [last.id]
        return true
    }
}

extension CanvasView: UITextViewDelegate {
    public func textViewDidChange(_ textView: UITextView) { layoutTextEditor() }

    public func textViewDidEndEditing(_ textView: UITextView) {
        if textSession?.view === textView { endTextEditing() }
    }
}
