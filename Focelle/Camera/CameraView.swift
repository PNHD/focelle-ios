@preconcurrency import AVFoundation
import AVKit
import PhotosUI
import SwiftUI
import UIKit
#if DEBUG
    import os
#endif

struct CameraView: View {
    private static let noFilterKey = "none"
    #if DEBUG
        private static let lifecycleLog = Logger(subsystem: "com.pnhd.focelle", category: "camera.view")
    #endif

    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var presets: PresetStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var location: LocationProvider
    @EnvironmentObject private var beta: BetaAccess
    @EnvironmentObject private var quota: Quota
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var account: Account
    @StateObject private var camera = CameraSession()
    @StateObject private var ai = AIAnalysisModel()
    @StateObject private var voice = VoiceGuidance()
    @State private var countdown: Int?
    @State private var countdownTask: Task<Void, Never>?
    @State private var focusMarker: CGPoint?
    @State private var showsFilterEditor = false
    @State private var selectedPresetID: UUID?
    @State private var presetName = ""
    @State private var presetToRename: UserPreset?
    @State private var photoSelection: PhotosPickerItem?
    @State private var photoEditorData: Data?
    @State private var autoCapture = AutoCapture()
    @State private var showsSettings = false
    @State private var showsLimit = false
    @State private var showsPaywall = false
    @State private var recordedCameraPermission = false
    @State private var aiStartedAt: TimeInterval?
    @State private var aiPreviewRequestID: UUID?

    enum GuidanceControlState: Equatable {
        case hidden
        case analyzing
        case capturing
        case recovery
    }

    enum AssistPresentation: Equatable {
        case hidden
        case guidance
        case analyzing
        case capturing
        case recovery
        case aiLoading
        case aiFailure
        case aiCompatibilityControls
    }

    static func guidanceControlState(for state: GuidanceSessionState) -> GuidanceControlState {
        switch state {
        case .analyzing: .analyzing
        case .capturing: .capturing
        case .failedRecoverable: .recovery
        case .ready, .selectingSubject, .guiding, .locked: .hidden
        }
    }

    // One presentation owns the temporary camera-assist surface. Lifecycle
    // states intentionally outrank retained cloud-AI state so a stale plan,
    // load, or error cannot compete with capture/recovery guidance.
    static func assistPresentation(
        for guidanceState: GuidanceSessionState,
        guidance: Guidance?,
        aiState: AIAnalysisModel.State
    ) -> AssistPresentation {
        switch guidanceState {
        case .capturing:
            .capturing
        case .failedRecoverable:
            .recovery
        case .analyzing:
            .analyzing
        case .guiding, .locked:
            guidance == nil ? .hidden : .guidance
        case .ready, .selectingSubject:
            switch aiState {
            case .idle: .hidden
            case .loading: .aiLoading
            case .failed: .aiFailure
            case .ready: .aiCompatibilityControls
            }
        }
    }

    static func showsStandaloneNotice(
        for guidanceState: GuidanceSessionState,
        isRecoverableFailureNotice: Bool
    ) -> Bool {
        !(guidanceState == .failedRecoverable && isRecoverableFailureNotice)
    }

    var body: some View {
        let captureView = GeometryReader { geometry in
            ZStack {
                Color.black.ignoresSafeArea()

                ZStack {
                    CameraPreview(
                        session: camera.session,
                        onFocus: { devicePoint, viewPoint in
                            focusMarker = viewPoint
                            camera.focus(at: devicePoint)
                        },
                        onSubject: camera.selectSubject,
                        onRotation: camera.setRotationAngle
                    )

                    if let filteredPreview = camera.filteredPreview {
                        Image(decorative: filteredPreview, scale: 1)
                            .resizable()
                            .scaledToFill()
                            .allowsHitTesting(false)
                    }

                    if camera.showsGrid { grid }
                    if settings.guidanceEnabled,
                        Self.assistPresentation(
                            for: camera.guidanceSessionState,
                            guidance: camera.guidance,
                            aiState: ai.state
                        ) == .guidance,
                        let guidance = camera.guidance
                    {
                        GuidanceOverlay(guidance: guidance)
                    }
                    focusIndicator
                }
                .aspectRatio(previewRatio(for: geometry.size), contentMode: .fit)
                .clipped()

                if camera.state != .running { statusView }

                controls

                if let countdown {
                    Text("\(countdown)")
                        .font(.system(size: 88, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .shadow(radius: 8)
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            #if DEBUG
                let enabled = settings.guidanceEnabled
                Self.lifecycleLog.debug("CameraView appeared, guidanceEnabled \(enabled, privacy: .public)")
            #endif
            camera.savesOriginal = settings.saveOriginal
            location.setEnabled(settings.saveLocation)
            camera.photoLocation = settings.saveLocation ? location.latest : nil
            camera.setRequestedResolution(settings.requestedResolution)
            camera.start()
        }
        .onDisappear {
            #if DEBUG
                Self.lifecycleLog.debug("CameraView disappeared")
            #endif
            countdownTask?.cancel()
            cancelAI()
            voice.stop()
            camera.stop()
        }
        .onChange(of: scenePhase) { _, phase in
            #if DEBUG
                Self.lifecycleLog.debug("scenePhase -> \(String(describing: phase), privacy: .public)")
            #endif
            if phase == .active {
                camera.start()
            } else {
                countdownTask?.cancel()
                countdown = nil
                autoCapture.cancel()
                cancelAI()
                voice.stop()
                camera.stop()
            }
        }
        .onCameraCaptureEvent(
            isEnabled: camera.state == .running && !camera.isCapturing && countdown == nil,
            action: { event in
                if event.phase == .ended { triggerCapture() }
            }
        )

        let editorView = captureView.sheet(isPresented: $showsFilterEditor) {
            if let recipe = camera.activeFilter {
                PresetEditorView(
                    recipe: recipe,
                    intensity: camera.filterIntensity,
                    onPreview: camera.applyFilter,
                    onSave: savePreset
                )
            }
        }
        .alert("filter.presetName", isPresented: renameAlert) {
            TextField("filter.presetName", text: $presetName)
            Button("common.cancel", role: .cancel) {}
            Button("common.save") {
                guard let preset = presetToRename, !presetName.isEmpty else { return }
                presets.rename(preset.id, to: presetName)
                syncPresets()
            }
        }
        .onChange(of: photoSelection) { _, selection in
            guard let selection else { return }
            Task {
                photoEditorData = try? await selection.loadTransferable(type: Data.self)
                if photoEditorData == nil { camera.showNotice("photoEditor.error.load") }
                photoSelection = nil
            }
        }
        let guidanceView = editorView.onChange(of: camera.guidance?.aligned) { oldValue, newValue in
            if oldValue != true, newValue == true {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                Analytics.record("guidance_aligned", enabled: settings.analyticsEnabled)
            }
        }
        .onChange(of: camera.state) { _, state in
            guard !recordedCameraPermission else { return }
            if state == .running || state == .permissionDenied {
                recordedCameraPermission = true
                Analytics.record(
                    state == .running
                        ? "camera_permission_allowed"
                        : "camera_permission_denied",
                    enabled: settings.analyticsEnabled
                )
            }
        }
        .onChange(of: camera.guidance) { _, guidance in
            guard let guidance else { return }
            if settings.voiceGuidance {
                voice.speak(
                    guidance.instruction
                        ?? NSLocalizedString(guidance.instructionKey, comment: "")
                )
            }
            guard settings.autoCapture, let measurement = camera.measurement else { return }
            if autoCapture.update(
                aligned: guidance.aligned,
                subject: measurement.primaryRect,
                faceReady: measurement.faceReady,
                timestamp: measurement.timestamp
            ) {
                triggerCapture()
            }
        }
        .onChange(of: ai.state) { oldState, state in
            if case .ready(let result, let selected) = state {
                camera.applyAIPlan(result.plans[selected])
                if case .loading = oldState {
                    let latency =
                        aiStartedAt.map {
                            ProcessInfo.processInfo.systemUptime - $0
                        } ?? 0
                    Analytics.record(
                        "ai_success",
                        enabled: settings.analyticsEnabled,
                        latencyBucket: Analytics.latencyBucket(latency),
                        schemaVersion: result.schemaVersion
                    )
                    aiStartedAt = nil
                    Task {
                        try? await Task.sleep(for: .milliseconds(500))
                        await beta.refresh()
                        await quota.refresh()
                    }
                }
            } else {
                camera.clearAIPlan()
                if case .failed(let error) = state, aiStartedAt != nil {
                    let latency =
                        aiStartedAt.map {
                            ProcessInfo.processInfo.systemUptime - $0
                        } ?? 0
                    Analytics.record(
                        "ai_failure",
                        enabled: settings.analyticsEnabled,
                        category: aiFailureCategory(error),
                        latencyBucket: Analytics.latencyBucket(latency)
                    )
                    aiStartedAt = nil
                    if error == .quotaExhausted { showsLimit = true }
                }
                if case .idle = state { aiStartedAt = nil }
            }
        }
        guidanceView.onChange(of: settings.voiceGuidance) { _, enabled in
            if !enabled { voice.stop() }
        }
        .onChange(of: settings.onDeviceOnly) { _, enabled in
            if enabled { cancelAI() }
        }
        .onChange(of: settings.autoCapture) { _, _ in
            autoCapture.cancel()
        }
        .onChange(of: settings.saveOriginal) { _, enabled in
            camera.savesOriginal = enabled
        }
        .onChange(of: settings.saveLocation) { _, enabled in
            location.setEnabled(enabled)
            camera.photoLocation = enabled ? location.latest : nil
        }
        .onChange(of: location.latest) { _, value in
            camera.photoLocation = settings.saveLocation ? value : nil
        }
        .onChange(of: settings.requestedResolution) { _, mode in
            camera.setRequestedResolution(mode)
        }
        .onChange(of: camera.filterSaveSequence) { oldValue, newValue in
            guard newValue > oldValue else { return }
            Analytics.record("filter_save", enabled: settings.analyticsEnabled)
            Task {
                do {
                    try await quota.consumeFilter()
                } catch Quota.QuotaError.exhausted {
                    showsLimit = true
                } catch {
                    await quota.refresh()
                }
            }
        }
        .sheet(isPresented: photoEditorPresented) {
            if let photoEditorData {
                PhotoEditorView(data: photoEditorData)
                    .environmentObject(presets)
            }
        }
        .sheet(
            isPresented: $showsSettings,
            onDismiss: {
                #if DEBUG
                    let enabled = settings.guidanceEnabled
                    let hasGuidance = camera.guidance != nil
                    Self.lifecycleLog.debug(
                        "Settings closed, enabled=\(enabled, privacy: .public) has=\(hasGuidance, privacy: .public)"
                    )
                #endif
                // The session never stopped while Settings was up; give local
                // analysis a clean slate instead of relying on scenePhase
                // (a sheet presentation doesn't reliably change it).
                camera.refreshLocalGuidanceAfterSettings()
            }
        ) {
            SettingsView(supportsMaximumResolution: camera.supportsMaximumResolution)
                .environmentObject(settings)
                .environmentObject(location)
                .environmentObject(beta)
        }
        .sheet(isPresented: $showsLimit) {
            LimitSheet {
                Task { @MainActor in
                    await Task.yield()
                    showsPaywall = true
                }
            }
            .environmentObject(quota)
        }
        .sheet(isPresented: $showsPaywall) {
            PaywallView()
                .environmentObject(store)
                .environmentObject(account)
        }
    }

    private var controls: some View {
        let latestThumbnail = camera.latestThumbnail

        return VStack(spacing: 14) {
            HStack {
                Text("app.name").font(.headline)
                Spacer()
                PhotosPicker(selection: $photoSelection, matching: .images) {
                    if let thumbnail = latestThumbnail {
                        Image(decorative: thumbnail, scale: 1)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 28, height: 28)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    } else {
                        Image(systemName: "photo.on.rectangle")
                    }
                }
                .accessibilityLabel(Text("photoEditor.pick"))

                Button {
                    settings.guidanceEnabled.toggle()
                } label: {
                    Image(
                        systemName: settings.guidanceEnabled ? "sparkles" : "sparkles.slash"
                    )
                }
                .accessibilityLabel(Text("guidance.toggle"))

                Menu {
                    Toggle("voice.toggle", isOn: $settings.voiceGuidance)
                    Toggle("autoCapture.toggle", isOn: $settings.autoCapture)
                } label: {
                    Image(systemName: "ear.badge.waveform")
                }
                .accessibilityLabel(Text("camera.assist"))

                Button {
                    showsSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel(Text("settings.title"))

                Button {
                    camera.showsGrid.toggle()
                } label: {
                    Image(systemName: camera.showsGrid ? "grid" : "square")
                }
                .accessibilityLabel(Text("camera.grid"))

                Menu {
                    ForEach(CameraTimer.allCases, id: \.self) { timer in
                        Button(timer.rawValue == 0 ? "camera.timer.off" : "\(timer.rawValue)s") {
                            camera.timer = timer
                        }
                    }
                } label: {
                    Image(systemName: "timer")
                }
                .accessibilityLabel(Text("camera.timer"))

                if beta.snapshot.enabled {
                    Text("beta.badge")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.orange.opacity(0.2), in: Capsule())
                        .foregroundStyle(.orange)
                }
            }

            HStack {
                Menu {
                    ForEach(CameraFlash.allCases, id: \.self) { mode in
                        Button(mode.label) { camera.flash = mode }
                    }
                } label: {
                    Image(systemName: flashIcon)
                }
                .accessibilityLabel(Text("camera.flash"))

                Menu {
                    ForEach(CameraRatio.allCases, id: \.self) { ratio in
                        Button(ratio.rawValue) { camera.ratio = ratio }
                    }
                } label: {
                    Text(camera.ratio.rawValue).font(.caption.weight(.semibold))
                }
                .accessibilityLabel(Text("camera.ratio"))

                if camera.supportsMaximumResolution {
                    VStack(spacing: 2) {
                        Menu {
                            Button("\(camera.standardModeLabel) MP") {
                                settings.requestedResolution = .standard
                            }
                            Button("\(camera.maximumModeLabel) MP") {
                                settings.requestedResolution = .maximum
                            }
                        } label: {
                            Text(camera.resolvedResolution.label)
                                .font(.caption.weight(.semibold))
                        }
                        .accessibilityLabel(Text("camera.resolution"))

                        // A downgrade is only worth calling out inline — no alert,
                        // since it isn't an error and shouldn't interrupt shooting.
                        if camera.resolvedResolution.isDowngraded {
                            Text("camera.resolution.downgraded")
                                .font(.system(size: 9))
                                .foregroundStyle(.orange)
                        }
                    }
                }

                Spacer()
            }

            Spacer()

            if let notice = camera.notice,
                Self.showsStandaloneNotice(
                    for: camera.guidanceSessionState,
                    isRecoverableFailureNotice: camera.isRecoverableFailureNotice
                )
            {
                Text(LocalizedStringKey(notice))
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(.black.opacity(0.7), in: Capsule())
            }

            VStack(spacing: 8) {
                cameraAssistPresentation
                filterPicker

                if camera.activeFilter != nil {
                    HStack {
                        Image(systemName: "camera.filters")
                        Slider(
                            value: Binding(
                                get: { camera.filterIntensity },
                                set: { camera.applyFilter(camera.activeFilter, intensity: $0) }
                            ),
                            in: 0...1
                        )
                        .tint(.orange)
                        Button("filter.edit") { showsFilterEditor = true }
                            .font(.caption.weight(.semibold))
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(Text("filter.intensity"))
                }

                HStack {
                    Image(systemName: "sun.min")
                    Slider(
                        value: Binding(
                            get: { Double(camera.exposure) },
                            set: { camera.setExposure(Float($0)) }
                        ),
                        in: -2...2,
                        step: 0.1
                    )
                    .tint(.orange)
                    Image(systemName: "sun.max")
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text("camera.exposure"))

                HStack {
                    Image(systemName: "magnifyingglass")
                    Slider(
                        value: Binding(
                            get: { Double(camera.zoom) },
                            set: { camera.setZoom(CGFloat($0)) }
                        ),
                        in: 1...Double(max(camera.maxZoom, 1))
                    )
                    .tint(.orange)
                    // The left end of the track already means 1x; a static "1x"
                    // label beside the live value read as the same number twice.
                    Text("\(camera.zoom, specifier: "%.1f")×")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(camera.zoom > 1.05 ? Color.orange : .secondary)
                        .frame(width: 42, alignment: .trailing)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text("camera.zoom"))
            }
            .padding(.horizontal, 4)

            HStack {
                Button {
                    cancelAI()
                    camera.switchCamera()
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath.camera")
                        .frame(width: 52, height: 52)
                        .background(.black.opacity(0.5), in: Circle())
                }
                .accessibilityLabel(Text("camera.switch"))
                .disabled(camera.state != .running)

                Spacer()

                Button(action: triggerCapture) {
                    Circle()
                        .fill(Color(red: 0.96, green: 0.94, blue: 0.88))
                        .frame(width: 72, height: 72)
                        .overlay(Circle().stroke(.white.opacity(0.4), lineWidth: 5).padding(-7))
                }
                .accessibilityLabel(Text("camera.shutter"))
                .disabled(
                    !CameraSession.manualCaptureAllowed(
                        state: camera.state,
                        isCapturing: camera.isCapturing,
                        countdownActive: countdown != nil,
                        filterQuotaExhausted: camera.activeFilter != nil
                            && !quota.snapshot.unlimited
                            && !store.isPro
                            && quota.snapshot.filterRemaining < 1
                    )
                )

                Spacer()

                Button(action: analyzeScene) {
                    Group {
                        if aiPreviewRequestID != nil {
                            ProgressView()
                        } else if case .loading = ai.state {
                            ProgressView()
                        } else {
                            Image(systemName: "wand.and.sparkles")
                        }
                    }
                    .frame(width: 52, height: 52)
                    .background(.orange.opacity(0.85), in: Circle())
                }
                .accessibilityLabel(Text("ai.analyze"))
                .disabled(camera.state != .running || settings.onDeviceOnly)
            }
        }
        .foregroundStyle(.white)
        .padding(24)
    }

    @ViewBuilder
    private var cameraAssistPresentation: some View {
        switch Self.assistPresentation(
            for: camera.guidanceSessionState,
            guidance: camera.guidance,
            aiState: ai.state
        ) {
        case .hidden, .guidance:
            EmptyView()
        case .analyzing:
            HStack {
                ProgressView()
                Text("ai.loading")
                Spacer()
            }
            .font(.caption.weight(.medium))
            .padding(10)
            .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
        case .capturing:
            HStack {
                ProgressView()
                Spacer()
            }
            .font(.caption.weight(.medium))
            .padding(10)
            .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
        case .recovery:
            HStack {
                Text("common.error")
                Spacer()
                Button("camera.error.captureCancelled", action: recoverAssistance)
            }
            .font(.caption.weight(.medium))
            .padding(10)
            .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
        case .aiLoading:
            HStack {
                ProgressView()
                Text("ai.loading")
                Spacer()
                Button("common.cancel", action: ai.cancel)
            }
            .font(.caption.weight(.medium))
            .padding(10)
            .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
        case .aiFailure:
            if case .failed(let error) = ai.state {
                Text(LocalizedStringKey(aiErrorKey(error)))
                    .font(.caption.weight(.medium))
                    .padding(10)
                    .frame(maxWidth: .infinity)
                    .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
            }
        case .aiCompatibilityControls:
            aiCompatibilityControls
        }
    }

    @ViewBuilder
    private var aiCompatibilityControls: some View {
        switch ai.state {
        case .ready(let result, let selected):
            let plan = result.plans[selected]
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Spacer()
                    Button {
                        ai.cancel()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel(Text("common.close"))
                }
                HStack {
                    ForEach(result.plans.indices, id: \.self) { index in
                        Button(aiPlanTitle(index)) {
                            _ = ai.select(index)
                            if index > 0 {
                                Analytics.record(
                                    "ai_alternative_selected",
                                    enabled: settings.analyticsEnabled
                                )
                            }
                        }
                        .buttonStyle(.bordered)
                        .tint(index == selected ? .orange : .white)
                    }
                }
                HStack {
                    if plan.flash != .off {
                        Button("ai.applyFlash") { camera.flash = plan.flash }
                    }
                    if let recipe = FocelleOriginals.all.first(
                        where: { plan.presetIDs.contains($0.id) }
                    ) {
                        Button("ai.applyFilter") {
                            selectedPresetID = nil
                            camera.applyFilter(recipe)
                        }
                    }
                }
                .font(.caption.weight(.semibold))
            }
            .padding(12)
            .background(.black.opacity(0.76), in: RoundedRectangle(cornerRadius: 14))
        case .idle, .loading, .failed:
            EmptyView()
        }
    }

    private var filterPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                filterButton(recipe: nil, title: "filter.none")
                ForEach(FocelleOriginals.all) { recipe in
                    filterButton(recipe: recipe, title: LocalizedStringKey(recipe.nameKey))
                }
                ForEach(presets.presets) { preset in
                    userPresetButton(preset)
                }
            }
            // Without this the first and last chip sit flush against the edge
            // and read as cut off rather than scrollable.
            .padding(.horizontal, 16)
        }
        .onAppear(perform: refreshFilterThumbnails)
        .onChange(of: presets.presets.map(\.id)) { _, _ in refreshFilterThumbnails() }
    }

    private func refreshFilterThumbnails() {
        camera.setFilterThumbnailRequests(
            [FilterThumbnailRequest(key: Self.noFilterKey, recipe: nil)]
                + FocelleOriginals.all.map {
                    FilterThumbnailRequest(key: $0.id, recipe: $0)
                }
                + presets.presets.map {
                    FilterThumbnailRequest(
                        key: $0.id.uuidString,
                        recipe: $0.recipe,
                        intensity: $0.intensity
                    )
                }
        )
    }

    // Each look is rendered onto the live frame, so the strip previews the
    // scene being shot instead of a bundled sample photo.
    private func filterChip(
        key: String,
        title: Text,
        selected: Bool,
        favorite: Bool = false
    ) -> some View {
        VStack(spacing: 5) {
            ZStack {
                if let thumbnail = camera.filterThumbnails[key] {
                    Image(decorative: thumbnail, scale: 1)
                        .resizable()
                        .scaledToFill()
                } else {
                    Color.white.opacity(0.12)
                }
                if favorite {
                    Image(systemName: "star.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.white)
                        .shadow(radius: 2)
                        .padding(4)
                        .frame(
                            maxWidth: .infinity,
                            maxHeight: .infinity,
                            alignment: .topTrailing
                        )
                }
            }
            .frame(width: 54, height: 54)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(
                        selected ? Color.orange : Color.white.opacity(0.25),
                        lineWidth: selected ? 2.5 : 1
                    )
            }
            title
                .font(.caption2.weight(.medium))
                .lineLimit(1)
                .foregroundStyle(selected ? Color.orange : Color.white.opacity(0.85))
        }
        .frame(width: 66)
    }

    private func filterButton(
        recipe: FilterRecipe?,
        title: LocalizedStringKey
    ) -> some View {
        let selected = camera.activeFilter?.id == recipe?.id
        return Button {
            selectedPresetID = nil
            camera.applyFilter(recipe)
            if recipe != nil {
                Analytics.record("filter_selected", enabled: settings.analyticsEnabled)
            }
        } label: {
            filterChip(
                key: recipe?.id ?? Self.noFilterKey,
                title: Text(title),
                selected: selected
            )
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func userPresetButton(_ preset: UserPreset) -> some View {
        Button {
            selectedPresetID = preset.id
            camera.applyFilter(preset.recipe, intensity: preset.intensity)
            Analytics.record("preset_selected", enabled: settings.analyticsEnabled)
        } label: {
            filterChip(
                key: preset.id.uuidString,
                title: Text(preset.name),
                selected: selectedPresetID == preset.id,
                favorite: preset.isFavorite
            )
        }
        .contextMenu {
            if preset.isFavorite {
                Button("filter.unfavorite") {
                    presets.setFavorite(preset.id, false)
                    syncPresets()
                }
            } else {
                Button("filter.favorite") {
                    presets.setFavorite(preset.id, true)
                    syncPresets()
                }
            }
            Button("filter.rename") {
                presetName = preset.name
                presetToRename = preset
            }
            Button("common.delete", role: .destructive) {
                if selectedPresetID == preset.id {
                    selectedPresetID = nil
                    camera.applyFilter(nil)
                }
                presets.delete(preset.id)
                syncPresets()
            }
        }
    }

    private var renameAlert: Binding<Bool> {
        Binding(
            get: { presetToRename != nil },
            set: { if !$0 { presetToRename = nil } }
        )
    }

    private var photoEditorPresented: Binding<Bool> {
        Binding(
            get: { photoEditorData != nil },
            set: { if !$0 { photoEditorData = nil } }
        )
    }

    private func savePreset(_ recipe: FilterRecipe, intensity: Double) {
        if let selectedPresetID {
            presets.edit(selectedPresetID, recipe: recipe, intensity: intensity)
        } else {
            let number = presets.presets.count + 1
            let preset = presets.create(
                name: String(format: String(localized: "filter.myPresetFormat"), number),
                recipe: recipe,
                intensity: intensity
            )
            selectedPresetID = preset.id
        }
        Analytics.record("preset_save", enabled: settings.analyticsEnabled)
        syncPresets()
    }

    private func syncPresets() {
        Task { await presets.sync() }
    }

    private var grid: some View {
        GeometryReader { geometry in
            Path { path in
                for part in [CGFloat(1) / 3, CGFloat(2) / 3] {
                    path.move(to: CGPoint(x: geometry.size.width * part, y: 0))
                    path.addLine(to: CGPoint(x: geometry.size.width * part, y: geometry.size.height))
                    path.move(to: CGPoint(x: 0, y: geometry.size.height * part))
                    path.addLine(to: CGPoint(x: geometry.size.width, y: geometry.size.height * part))
                }
            }
            .stroke(.white.opacity(0.35), lineWidth: 0.7)
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var focusIndicator: some View {
        GeometryReader { geometry in
            if let focusMarker {
                RoundedRectangle(cornerRadius: 4)
                    .stroke(.orange, lineWidth: 1.5)
                    .frame(width: 64, height: 64)
                    .position(
                        x: focusMarker.x * geometry.size.width,
                        y: focusMarker.y * geometry.size.height
                    )
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder
    private var statusView: some View {
        Color.black.ignoresSafeArea()
        VStack(spacing: 14) {
            Image(systemName: camera.state == .permissionDenied ? "camera.fill" : "viewfinder")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(.orange)
            Text(statusKey).font(.title3.weight(.semibold))
            if camera.state == .permissionDenied {
                Button("camera.openSettings") {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    UIApplication.shared.open(url)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
            }
        }
        .multilineTextAlignment(.center)
        .padding(32)
        .foregroundStyle(.white)
    }

    private var statusKey: LocalizedStringKey {
        switch camera.state {
        case .starting: "camera.starting"
        case .interrupted: "camera.interrupted"
        case .permissionDenied: "camera.permissionDenied"
        case .unavailable: "camera.unavailable"
        case .running: ""
        }
    }

    private var flashIcon: String {
        switch camera.flash {
        case .off: "bolt.slash"
        case .auto: "bolt.badge.a"
        case .on: "bolt.fill"
        }
    }

    private func previewRatio(for size: CGSize) -> CGFloat {
        size.width > size.height ? camera.ratio.value : 1 / camera.ratio.value
    }

    private func triggerCapture() {
        guard CameraSession.manualCaptureAllowed(
            state: camera.state,
            isCapturing: camera.isCapturing,
            countdownActive: countdown != nil,
            filterQuotaExhausted: camera.activeFilter != nil
                && !quota.snapshot.unlimited
                && !store.isPro
                && quota.snapshot.filterRemaining < 1
        ) else { return }
        autoCapture.cancel()
        if case .ready = ai.state {
            Analytics.record("capture_after_guidance", enabled: settings.analyticsEnabled)
        }
        guard camera.timer.rawValue > 0 else {
            camera.capture()
            return
        }
        countdownTask = Task { @MainActor in
            for value in stride(from: camera.timer.rawValue, through: 1, by: -1) {
                countdown = value
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
            }
            countdown = nil
            camera.capture()
        }
    }

    private func analyzeScene() {
        if aiPreviewRequestID != nil {
            cancelAI()
            return
        }
        if case .loading = ai.state {
            cancelAI()
            return
        }
        // An explicit user analysis request is the production recovery path
        // for local guidance after a recoverable capture failure.
        camera.beginGuidanceAnalysis()
        if !quota.snapshot.unlimited, !store.isPro, quota.snapshot.aiRemaining < 1 {
            showsLimit = true
            return
        }
        Analytics.record("ai_tap", enabled: settings.analyticsEnabled)
        aiStartedAt = ProcessInfo.processInfo.systemUptime
        let measurement = camera.measurement
        let requestID = UUID()
        aiPreviewRequestID = requestID
        camera.requestAIPreview { data in
            Task { @MainActor in
                guard aiPreviewRequestID == requestID else { return }
                aiPreviewRequestID = nil
                guard let data else {
                    ai.fail(.unavailable)
                    return
                }
                ai.analyze(data, measurement: measurement)
            }
        }
    }

    private func recoverAssistance() {
        // Retire any retained cloud state first; CameraSession then explicitly
        // retires the failure notice and starts the fresh local analysis pass.
        cancelAI()
        camera.recoverGuidance()
    }

    private func cancelAI() {
        aiPreviewRequestID = nil
        aiStartedAt = nil
        camera.cancelAIPreview()
        ai.cancel()
    }

    private func aiErrorKey(_ error: AIClientError) -> String {
        switch error {
        case .unavailable: "ai.error.unavailable"
        case .offline: "ai.error.offline"
        case .timedOut: "ai.error.timeout"
        case .rateLimited: "ai.error.rate"
        case .quotaExhausted: "limit.aiExhausted"
        case .invalidResponse, .server: "ai.error.server"
        }
    }

    private func aiFailureCategory(_ error: AIClientError) -> String {
        switch error {
        case .unavailable: "unavailable"
        case .offline: "offline"
        case .timedOut: "timed_out"
        case .rateLimited: "rate_limited"
        case .invalidResponse: "invalid_response"
        case .quotaExhausted: "quota_exhausted"
        case .server: "server"
        }
    }

    private func aiPlanTitle(_ index: Int) -> LocalizedStringKey {
        switch index {
        case 0: "ai.plan.primary"
        case 1: "ai.plan.safe"
        default: "ai.plan.creative"
        }
    }
}

private struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let onFocus: (CGPoint, CGPoint) -> Void
    let onSubject: (CGPoint) -> Void
    let onRotation: (CGFloat) -> Void

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer?.session = session
        view.previewLayer?.videoGravity = .resizeAspectFill
        view.onFocus = onFocus
        view.onSubject = onSubject
        view.onRotation = onRotation
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.onFocus = onFocus
        uiView.onSubject = onSubject
        uiView.onRotation = onRotation
    }
}

private final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer? { layer as? AVCaptureVideoPreviewLayer }
    var onFocus: ((CGPoint, CGPoint) -> Void)?
    var onSubject: ((CGPoint) -> Void)?
    var onRotation: ((CGFloat) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(didTap)))
        addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(didPress)))
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(didTap)))
        addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(didPress)))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let previewLayer,
            let orientation = window?.windowScene?.interfaceOrientation
        else { return }
        let angle = CameraRotation.angle(for: orientation)
        if let connection = previewLayer.connection,
            connection.isVideoRotationAngleSupported(angle)
        {
            connection.videoRotationAngle = angle
        }
        onRotation?(angle)
    }

    @objc private func didTap(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: self)
        guard let previewLayer, bounds.width > 0, bounds.height > 0 else { return }
        onFocus?(
            previewLayer.captureDevicePointConverted(fromLayerPoint: point),
            CGPoint(x: point.x / bounds.width, y: point.y / bounds.height)
        )
    }

    @objc private func didPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began, bounds.width > 0, bounds.height > 0 else { return }
        let point = gesture.location(in: self)
        onSubject?(CGPoint(x: point.x / bounds.width, y: point.y / bounds.height))
    }
}

#Preview {
    CameraView()
}
