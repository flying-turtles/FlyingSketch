import SwiftUI

@main
struct FlyingSketchApp: App {
    var body: some Scene {
        DocumentGroup(newDocument: { SketchFileDocument() }) { file in
            SketchEditorView(document: file.document)
        }
    }
}
