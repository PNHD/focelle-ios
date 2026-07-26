@preconcurrency import AVFoundation
import AVKit
import PhotosUI
import SwiftUI
import UIKit

struct CameraView: View {
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

    var body: some View {
        GeometryReader { geometry in
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
                    if settings.guidanceEnabled, let guidance = camera.guidance {
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
            camera.savesOriginal = settings.saveOriginal
            location.setEnabled(settings.saveLocation)
            camera.photoLocation = settings.saveLocation ? location.latest : nil
            camera.resolution = settings.maximumResolution ? .maximum : .standard
            camera.start()
        }
        .onDisappear {
            countdownTask?.cancel()
            voice.stop()
            camera.stop()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                camera.start()
            } else {
                countdownTask?.cancel()
                countdown = nil
                autoCapture.cancel()
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
        .sheet(isPresented: $showsFilterEditor) {
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
                if photoEditorData == nil { camera.notice = "photoEditor.error.load" }
                photoSelection = nil
            }
        }
        .onChange(of: camera.guidance?.aligned) { oldValue, newValue in
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
            if case let .ready(result, selected) = state {
                camera.applyAIPlan(result.plans[selected])
                if case .loading = oldState {
                    Analytics.record("ai_success", enabled: settings.analyticsEnabled)
                    Task {
                        try? await Task.sleep(for: .milliseconds(500))
                        await beta.refresh()
                        await quota.refresh()
                    }
                }
            } else {
                camera.clearAIPlan()
                if case .loading = oldState, case let .failed(error) = state {
                    Analytics.record("ai_failure", enabled: settings.analyticsEnabled)
                    if error == .quotaExhausted { showsLimit = true }
                }
            }
        }
        .onChange(of: settings.voiceGuidance) { _, enabled in
            if !enabled { voice.stop() }
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
        .onChange(of: settings.maximumResolution) { _, enabled in
            camera.resolution = enabled ? .maximum : .standard
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
        .sheet(isPresented: $showsSettings) {
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
        VStack(spacing: 14) {
            HStack {
                Text("app.name").font(.headline)
                Spacer()
                PhotosPicker(selection: $photoSelection, matching: .images) {
                    if let thumbnail = camera.latestThumbnail {
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

                Button { settings.guidanceEnabled.toggle() } label: {
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

                Button { showsSettings = true } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel(Text("settings.title"))

                Button { camera.showsGrid.toggle() } label: {
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

                Text("beta.badge")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.orange.opacity(0.2), in: Capsule())
                    .foregroundStyle(.orange)
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
                    Menu {
                        Button("24 MP") { camera.resolution = .standard }
                        Button("48 MP") { camera.resolution = .maximum }
                    } label: {
                        Text(camera.resolution == .maximum ? "48" : "24")
                            .font(.caption.weight(.semibold))
                    }
                    .accessibilityLabel(Text("camera.resolution"))
                }

                Spacer()
            }

            Spacer()

            if let notice = camera.notice {
                Text(LocalizedStringKey(notice))
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(.black.opacity(0.7), in: Capsule())
            }

            VStack(spacing: 8) {
                aiResult
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
                    Image(systemName: "sun.max")
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text("camera.exposure"))

                HStack {
                    Text("1×").font(.caption.monospacedDigit())
                    Slider(
                        value: Binding(
                            get: { Double(camera.zoom) },
                            set: { camera.setZoom(CGFloat($0)) }
                        ),
                        in: 1...Double(max(camera.maxZoom, 1))
                    )
                    Text("\(camera.zoom, specifier: "%.1f")×")
                        .font(.caption.monospacedDigit())
                        .frame(width: 38)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text("camera.zoom"))
            }
            .padding(.horizontal, 4)

            HStack {
                Button(action: camera.switchCamera) {
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
                .disabled(camera.state != .running || camera.isCapturing || countdown != nil)

                Spacer()

                Button(action: analyzeScene) {
                    Group {
                        if case .loading = ai.state {
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
    private var aiResult: some View {
        switch ai.state {
        case .idle:
            EmptyView()
        case .loading:
            HStack {
                ProgressView()
                Text("ai.loading")
                Spacer()
                Button("common.cancel", action: ai.cancel)
            }
            .font(.caption.weight(.medium))
            .padding(10)
            .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
        case let .failed(error):
            Text(LocalizedStringKey(aiErrorKey(error)))
                .font(.caption.weight(.medium))
                .padding(10)
                .frame(maxWidth: .infinity)
                .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
        case let .ready(result, selected):
            let plan = result.plans[selected]
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(plan.instruction).font(.subheadline.weight(.semibold))
                    Spacer()
                    Button {
                        ai.cancel()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel(Text("common.close"))
                }
                Text(plan.pose).font(.caption).foregroundStyle(.white.opacity(0.8))
                HStack {
                    ForEach(result.plans.indices, id: \.self) { index in
                        Button(aiPlanTitle(index)) {
                            _ = ai.select(index)
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
        }
    }

    private var filterPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                filterButton(recipe: nil, title: "filter.none")
                ForEach(FocelleOriginals.all) { recipe in
                    filterButton(recipe: recipe, title: LocalizedStringKey(recipe.nameKey))
                }
                ForEach(presets.presets) { preset in
                    userPresetButton(preset)
                }
            }
        }
    }

    private func filterButton(
        recipe: FilterRecipe?,
        title: LocalizedStringKey
    ) -> some View {
        let selected = camera.activeFilter?.id == recipe?.id
        return Button {
            selectedPresetID = nil
            camera.applyFilter(recipe)
        } label: {
            Text(title)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(selected ? Color.orange : Color.black.opacity(0.55), in: Capsule())
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func userPresetButton(_ preset: UserPreset) -> some View {
        Button {
            selectedPresetID = preset.id
            camera.applyFilter(preset.recipe, intensity: preset.intensity)
        } label: {
            HStack(spacing: 4) {
                if preset.isFavorite { Image(systemName: "star.fill") }
                Text(preset.name).lineLimit(1)
            }
            .font(.caption.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                selectedPresetID == preset.id ? Color.orange : Color.black.opacity(0.55),
                in: Capsule()
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
        guard countdown == nil, !camera.isCapturing else { return }
        if camera.activeFilter != nil,
           !quota.snapshot.unlimited,
           !store.isPro,
           quota.snapshot.filterRemaining < 1 {
            showsLimit = true
            return
        }
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
        if case .loading = ai.state {
            ai.cancel()
            return
        }
        if !quota.snapshot.unlimited, !store.isPro, quota.snapshot.aiRemaining < 1 {
            showsLimit = true
            return
        }
        Analytics.record("ai_tap", enabled: settings.analyticsEnabled)
        let measurement = camera.measurement
        camera.requestAIPreview { data in
            Task { @MainActor in
                guard let data else {
                    ai.fail(.unavailable)
                    return
                }
                ai.analyze(data, measurement: measurement)
            }
        }
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
