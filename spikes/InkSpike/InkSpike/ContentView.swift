import SwiftUI

enum PaneChoice: String, CaseIterable, Identifiable {
    case all = "All"
    case pencilKit = "PencilKit"
    case coreAnimation = "Core Animation"
    case metal = "Metal"
    var id: String { rawValue }
}

struct ContentView: View {
    @State private var settings = InkSettings()
    @State private var layout: PaneChoice = .all

    var body: some View {
        VStack(spacing: 0) {
            ControlBar(settings: settings, layout: $layout)
            Divider()
            panes
        }
        .background(Color(white: 0.85))
    }

    @ViewBuilder
    private var panes: some View {
        switch layout {
        case .all:
            HStack(spacing: 2) {
                pane(.pencilKit)
                pane(.coreAnimation)
                pane(.metal)
            }
        default:
            pane(layout)
        }
    }

    private func pane(_ choice: PaneChoice) -> some View {
        ZStack(alignment: .topLeading) {
            switch choice {
            case .pencilKit, .all:
                PencilKitRepresentable(width: settings.baseWidth, pencilOnly: settings.pencilOnly,
                                       clearToken: settings.clearToken)
            case .coreAnimation:
                InkCanvasRepresentable(renderer: .coreAnimation, settings: settings,
                                       clearToken: settings.clearToken)
            case .metal:
                InkCanvasRepresentable(renderer: .metal, settings: settings,
                                       clearToken: settings.clearToken)
            }
            PaneLabel(title: choice == .all ? "PencilKit" : choice.rawValue,
                      latency: settings.latencyMs[choice.rawValue])
        }
    }
}

private struct PaneLabel: View {
    let title: String
    let latency: Double?

    var body: some View {
        HStack(spacing: 6) {
            Text(title).bold()
            if let latency {
                Text(String(format: "input→submit %.1f ms", latency)).monospacedDigit()
            }
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.thinMaterial, in: Capsule())
        .padding(8)
        .allowsHitTesting(false)
    }
}

private struct ControlBar: View {
    @Bindable var settings: InkSettings
    @Binding var layout: PaneChoice

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 16) {
                Picker("Layout", selection: $layout) {
                    ForEach(PaneChoice.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 480)
                Spacer()
                Toggle("Pencil only", isOn: $settings.pencilOnly).fixedSize()
                Button("Clear", role: .destructive) { settings.clearToken += 1 }
                    .buttonStyle(.borderedProminent)
            }
            HStack(spacing: 16) {
                labeled("Width \(String(format: "%.1f", settings.baseWidth))") {
                    Slider(value: $settings.baseWidth, in: 1...20)
                }
                Toggle("Pressure", isOn: $settings.usePressure).fixedSize()
                labeled("Curve γ \(String(format: "%.2f", settings.pressureGamma))") {
                    Slider(value: $settings.pressureGamma, in: 0.3...3)
                }
                .disabled(!settings.usePressure)
                Toggle("Prediction", isOn: $settings.usePrediction).fixedSize()
            }
            HStack(spacing: 16) {
                Toggle("Smoothing", isOn: $settings.smoothingEnabled).fixedSize()
                labeled("Min cutoff \(String(format: "%.2f", settings.minCutoff)) Hz") {
                    Slider(value: $settings.minCutoff, in: 0.1...10)
                }
                labeled("Beta \(String(format: "%.3f", settings.beta))") {
                    Slider(value: $settings.beta, in: 0...0.5)
                }
            }
            .disabled(!settings.smoothingEnabled)
            Text("Custom panes share smoothing/pressure code. PencilKit uses only width + pencil-only. Settings apply from the next stroke.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(.bar)
    }

    private func labeled<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).monospacedDigit()
            content()
        }
    }
}
