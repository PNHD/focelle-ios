import SwiftUI

struct PhotoEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var presets: PresetStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var quota: Quota
    @EnvironmentObject private var store: Store
    @StateObject private var model: PhotoEditorModel
    @State private var showsEditor = false
    @State private var showsLimit = false
    @State private var showsPaywall = false

    init(data: Data) {
        _model = StateObject(wrappedValue: PhotoEditorModel(data: data))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if let preview = model.preview {
                    Image(decorative: preview, scale: 1)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.black)
                } else {
                    ContentUnavailableView(
                        "photoEditor.error.load",
                        systemImage: "photo.badge.exclamationmark"
                    )
                }

                filterPicker

                if model.recipe != nil {
                    HStack {
                        Image(systemName: "camera.filters")
                        Slider(
                            value: Binding(
                                get: { model.intensity },
                                set: { model.apply(model.recipe, intensity: $0) }
                            ),
                            in: 0...1
                        )
                        Button("filter.edit") { showsEditor = true }
                    }

                    Text("filter.holdCompare")
                        .font(.footnote)
                        .padding(10)
                        .background(.secondary.opacity(0.12), in: Capsule())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { _ in model.compareOriginal(true) }
                                .onEnded { _ in model.compareOriginal(false) }
                        )
                }
            }
            .padding()
            .navigationTitle("photoEditor.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.save", action: save)
                        .disabled(model.isSaving || model.preview == nil)
                }
            }
            .sheet(isPresented: $showsEditor) {
                if let recipe = model.recipe {
                    PresetEditorView(
                        recipe: recipe,
                        intensity: model.intensity,
                        onPreview: model.apply,
                        onSave: { recipe, intensity in
                            let preset = presets.create(
                                name: String(
                                    format: String(localized: "filter.myPresetFormat"),
                                    presets.presets.count + 1
                                ),
                                recipe: recipe,
                                intensity: intensity
                            )
                            model.apply(preset.recipe, intensity: preset.intensity)
                            Task { await presets.sync() }
                        }
                    )
                }
            }
            .alert(
                "common.error",
                isPresented: Binding(
                    get: { model.errorKey != nil },
                    set: { if !$0 { model.errorKey = nil } }
                )
            ) {
                Button("common.done") { model.errorKey = nil }
            } message: {
                if let errorKey = model.errorKey {
                    Text(LocalizedStringKey(errorKey))
                }
            }
            .sheet(isPresented: $showsLimit) {
                LimitSheet {
                    Task { @MainActor in
                        await Task.yield()
                        showsPaywall = true
                    }
                }
            }
            .sheet(isPresented: $showsPaywall) {
                PaywallView()
            }
        }
    }

    private func save() {
        if model.recipe != nil,
            !quota.snapshot.unlimited,
            !store.isPro,
            quota.snapshot.filterRemaining < 1
        {
            showsLimit = true
            return
        }
        Task {
            guard await model.saveCopy() else { return }
            if model.recipe != nil {
                Analytics.record("filter_save", enabled: settings.analyticsEnabled)
                do {
                    try await quota.consumeFilter()
                } catch Quota.QuotaError.exhausted {
                    showsLimit = true
                    return
                } catch {
                    await quota.refresh()
                }
            }
            dismiss()
        }
    }

    private var filterPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                filterButton(nil, title: Text("filter.none"))
                ForEach(FocelleOriginals.all) {
                    filterButton($0, title: Text(LocalizedStringKey($0.nameKey)))
                }
                ForEach(presets.presets) {
                    filterButton($0.recipe, title: Text(verbatim: $0.name))
                }
            }
        }
    }

    private func filterButton(
        _ recipe: FilterRecipe?,
        title: Text
    ) -> some View {
        let selected = model.recipe?.id == recipe?.id
        return Button {
            model.apply(recipe)
        } label: {
            title
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(selected ? Color.orange : Color.secondary.opacity(0.2), in: Capsule())
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
