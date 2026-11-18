import SketchCore

/// Commits text edits to the model. The canvas owns the `UITextView`; this owns the document rules.
final class TextController {
    private let model: DocumentModel

    init(model: DocumentModel) { self.model = model }

    /// Empty/whitespace new text: no edit. Existing text: unchanged = no edit, emptied = remove, else replace.
    /// Returns whether an edit was performed.
    @discardableResult
    func commit(_ text: String, existing: TextObject?, position: Vec2, fontSize: Double, color: RGBAColor) -> Bool {
        let blank = text.allSatisfy(\.isWhitespace)
        if let existing {
            if blank {
                model.perform(.remove([existing.id]), actionName: "Delete Text")
                return true
            }
            guard text != existing.text else { return false }
            var edited = existing
            edited.text = text
            model.perform(.replace([.text(edited)]), actionName: "Edit Text")
            return true
        }
        guard !blank else { return false }
        let object = TextObject(text: text, position: position, fontSize: fontSize, color: color)
        model.perform(.insert([.text(object)], at: nil), actionName: "Add Text")
        return true
    }
}
