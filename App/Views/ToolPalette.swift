import SwiftUI
import PhotosUI
import SketchCore
import InkEngine
import CanvasUI

private let paletteSwatches: [RGBAColor] = [
    RGBAColor(r: 0, g: 0, b: 0), RGBAColor(r: 0.3, g: 0.3, b: 0.3), RGBAColor(r: 0.9, g: 0.15, b: 0.15),
    RGBAColor(r: 0.1, g: 0.35, b: 0.9), RGBAColor(r: 0.1, g: 0.65, b: 0.25), RGBAColor(r: 1, g: 0.55, b: 0.05),
]

/// `accessory` is shown after the tools (selection-dependent buttons such as the part inspector).
struct ToolPalette<Accessory: View>: View {
    @Binding var toolState: ToolState
    @Binding var showsGrid: Bool
    @Binding var snapsToGrid: Bool
    let canUndo: Bool
    let canRedo: Bool
    let undo: () -> Void
    let redo: () -> Void
    let insertImage: (Data) -> Void
    let insertStress: () -> Void
    let openParts: () -> Void
    let accessory: Accessory

    @State private var photo: PhotosPickerItem?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                toolButton("pencil.tip", .ink(.pen), label: "Pen")
                toolButton("pencil", .ink(.pencil), label: "Pencil")
                toolButton("paintbrush.pointed", .ink(.marker), label: "Marker")
                toolButton("highlighter", .ink(.highlighter), label: "Highlighter")
                toolButton("eraser", .eraser, label: "Eraser")
                toolButton("lasso", .lasso, label: "Lasso")
                shapesMenu
                toolButton("textformat", .text, label: "Text")
                toolButton("point.topleft.down.to.point.bottomright.curvepath", .wire, label: "Wire")
                PhotosPicker(selection: $photo, matching: .images) { Image(systemName: "photo") }
                    .accessibilityLabel("Image")
                Button(action: openParts) { Image(systemName: "cpu").padding(6) }
                    .accessibilityLabel("Parts")
                accessory
                divider
                ForEach(paletteSwatches, id: \.self) { swatch in
                    Button { toolState.color = swatch } label: {
                        Circle().fill(Color(swatch)).frame(width: 24, height: 24)
                            .overlay(Circle().stroke(toolState.color == swatch ? Color.accentColor : .secondary.opacity(0.4),
                                                     lineWidth: toolState.color == swatch ? 3 : 1))
                    }
                    .accessibilityLabel("Colour")
                }
                ColorPicker("Custom colour", selection: customColor, supportsOpacity: false).labelsHidden()
                Slider(value: $toolState.inkWidth, in: 0.1...5).frame(width: 120)
                    .accessibilityLabel("Width")
                divider
                Toggle(isOn: $showsGrid) { Image(systemName: "grid") }.toggleStyle(.button).accessibilityLabel("Grid")
                Toggle(isOn: $snapsToGrid) { Image(systemName: "squareshape.split.2x2.dotted") }
                    .toggleStyle(.button).accessibilityLabel("Snap to grid")
                Toggle(isOn: $toolState.pencilOnly) { Image(systemName: "applepencil") }
                    .toggleStyle(.button).accessibilityLabel("Pencil only")
                divider
                Button(action: undo) { Image(systemName: "arrow.uturn.backward") }
                    .disabled(!canUndo).accessibilityLabel("Undo")
                Button(action: redo) { Image(systemName: "arrow.uturn.forward") }
                    .disabled(!canRedo).accessibilityLabel("Redo")
                #if DEBUG
                Menu { Button("Insert stress fixture", action: insertStress) } label: { Image(systemName: "ladybug") }
                #endif
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
        }
        .frame(maxWidth: 900)
        .fixedSize(horizontal: false, vertical: true)
        .background(.regularMaterial, in: Capsule())
        .shadow(radius: 4, y: 2)
        .padding(.horizontal, 16)
        .onChange(of: photo) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    insertImage(data)
                } else {
                    #if DEBUG
                    print("ToolPalette: loadTransferable(Data) returned nil for picked photo")
                    #endif
                }
                photo = nil
            }
        }
    }

    private var divider: some View { Divider().frame(height: 24) }

    private func toolButton(_ symbol: String, _ kind: ToolKind, label: String) -> some View {
        Button { toolState.kind = kind } label: {
            Image(systemName: symbol)
                .padding(6)
                .background(toolState.kind == kind ? Color.accentColor.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 8))
        }
        .accessibilityLabel(label)
    }

    private var shapesMenu: some View {
        Menu {
            ForEach([(ShapeKind.line, "Line", "line.diagonal"), (.arrow, "Arrow", "arrow.up.right"),
                     (.rectangle, "Rectangle", "rectangle"), (.ellipse, "Ellipse", "circle")], id: \.0) { kind, name, symbol in
                Button { toolState.kind = .shape(kind) } label: { Label(name, systemImage: symbol) }
            }
        } label: {
            Image(systemName: "square.on.circle")
                .padding(6)
                .background(isShape ? Color.accentColor.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 8))
        }
        .accessibilityLabel("Shapes")
    }

    private var isShape: Bool {
        if case .shape = toolState.kind { true } else { false }
    }

    private var customColor: Binding<Color> {
        Binding(
            get: { Color(toolState.color) },
            set: { c in
                let ui = UIColor(c)
                var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                ui.getRed(&r, green: &g, blue: &b, alpha: &a)
                toolState.color = RGBAColor(r: r, g: g, b: b, a: 1)
            }
        )
    }
}

private extension Color {
    init(_ c: RGBAColor) { self.init(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: c.a) }
}
