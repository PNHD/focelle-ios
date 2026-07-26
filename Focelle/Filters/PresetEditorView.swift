import SwiftUI

struct PresetEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: PresetDraft

    let original: PresetDraft
    let onPreview: (FilterRecipe, Double) -> Void
    let onSave: (FilterRecipe, Double) -> Void

    init(
        recipe: FilterRecipe,
        intensity: Double,
        onPreview: @escaping (FilterRecipe, Double) -> Void,
        onSave: @escaping (FilterRecipe, Double) -> Void
    ) {
        var value = PresetDraft(base: recipe)
        value.recipe = recipe
        value.intensity = intensity
        _draft = State(initialValue: value)
        original = value
        self.onPreview = onPreview
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    ToneColorPad(draft: $draft)
                        .frame(height: 220)

                    adjustment("filter.intensity", value: $draft.intensity, range: 0...1)

                    VStack(spacing: 14) {
                        adjustment("filter.exposure", keyPath: \.exposure, range: -1...1)
                        adjustment("filter.highlights", keyPath: \.highlights, range: -1...1)
                        adjustment("filter.shadows", keyPath: \.shadows, range: -1...1)
                        adjustment("filter.contrast", keyPath: \.contrast, range: -1...1)
                        adjustment("filter.saturation", keyPath: \.saturation, range: -1...1)
                        adjustment("filter.warmth", keyPath: \.warmth, range: -1...1)
                        adjustment("filter.tint", keyPath: \.tint, range: -1...1)
                        adjustment("filter.fade", keyPath: \.fade, range: 0...1)
                        adjustment("filter.grain", keyPath: \.grain, range: 0...1)
                        adjustment("filter.vignette", keyPath: \.vignette, range: 0...1)
                    }

                    HStack {
                        Button("filter.reset") { draft.reset() }
                            .buttonStyle(.bordered)

                        Spacer()

                        Text("filter.holdCompare")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(10)
                            .background(.secondary.opacity(0.12), in: Capsule())
                            .gesture(
                                DragGesture(minimumDistance: 0)
                                    .onChanged { _ in onPreview(draft.recipe, 0) }
                                    .onEnded { _ in onPreview(draft.recipe, draft.intensity) }
                            )
                    }
                }
                .padding(20)
            }
            .navigationTitle(LocalizedStringKey(draft.recipe.nameKey))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel") {
                        onPreview(original.recipe, original.intensity)
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("filter.savePreset") {
                        onSave(draft.recipe, draft.intensity)
                        dismiss()
                    }
                }
            }
            .onChange(of: draft) { _, value in
                onPreview(value.recipe, value.intensity)
            }
        }
        .interactiveDismissDisabled()
    }

    private func adjustment(
        _ key: LocalizedStringKey,
        value: Binding<Double>,
        range: ClosedRange<Double>
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(key)
                Spacer()
                Text(value.wrappedValue, format: .number.precision(.fractionLength(2)))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: value, in: range)
        }
        .font(.subheadline)
    }

    private func adjustment(
        _ key: LocalizedStringKey,
        keyPath: WritableKeyPath<FilterRecipe, Double>,
        range: ClosedRange<Double>
    ) -> some View {
        adjustment(
            key,
            value: Binding(
                get: { draft.recipe[keyPath: keyPath] },
                set: { draft.recipe[keyPath: keyPath] = $0 }
            ),
            range: range
        )
    }
}

private struct ToneColorPad: View {
    @Binding var draft: PresetDraft

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                RoundedRectangle(cornerRadius: 24)
                    .fill(
                        LinearGradient(
                            colors: [.cyan.opacity(0.8), .gray.opacity(0.25), .orange.opacity(0.9)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .overlay {
                        LinearGradient(
                            colors: [.white.opacity(0.65), .clear, .black.opacity(0.55)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 24))
                    }

                Circle()
                    .fill(.white)
                    .frame(width: 24, height: 24)
                    .overlay(Circle().stroke(.black.opacity(0.45), lineWidth: 2))
                    .position(
                        x: min(max(draft.recipe.warmth + 0.5, 0), 1) * geometry.size.width,
                        y: min(max(0.5 - draft.recipe.exposure / 0.7, 0), 1) * geometry.size.height
                    )
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        let color = gesture.location.x / geometry.size.width * 2 - 1
                        let tone = 1 - gesture.location.y / geometry.size.height * 2
                        draft.setToneColor(tone: tone, color: color)
                    }
            )
        }
        .accessibilityElement()
        .accessibilityLabel(Text("filter.toneColor"))
        .accessibilityValue(
            Text("\(draft.recipe.exposure, specifier: "%.2f"), \(draft.recipe.warmth, specifier: "%.2f")")
        )
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                draft.recipe.exposure = min(draft.recipe.exposure + 0.05, 1)
            case .decrement:
                draft.recipe.exposure = max(draft.recipe.exposure - 0.05, -1)
            @unknown default:
                break
            }
        }
    }
}
