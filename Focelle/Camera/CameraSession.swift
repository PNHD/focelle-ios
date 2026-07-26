@preconcurrency import AVFoundation
@preconcurrency import CoreLocation
import Photos
import SwiftUI
import UIKit

enum CameraPermission: Equatable {
    case undecided
    case allowed
    case denied

    init(_ status: AVAuthorizationStatus) {
        switch status {
        case .authorized: self = .allowed
        case .notDetermined: self = .undecided
        case .denied, .restricted: self = .denied
        @unknown default: self = .denied
        }
    }
}

enum CameraFlash: String, CaseIterable, Codable, Sendable {
    case off
    case auto
    case on

    var mode: AVCaptureDevice.FlashMode {
        switch self {
        case .off: .off
        case .auto: .auto
        case .on: .on
        }
    }

    var label: LocalizedStringKey {
        switch self {
        case .off: "camera.flash.off"
        case .auto: "camera.flash.auto"
        case .on: "camera.flash.on"
        }
    }
}

enum CameraRatio: String, CaseIterable {
    case fourThree = "4:3"
    case square = "1:1"
    case sixteenNine = "16:9"

    var value: CGFloat {
        switch self {
        case .fourThree: 4 / 3
        case .square: 1
        case .sixteenNine: 16 / 9
        }
    }
}

enum CameraTimer: Int, CaseIterable {
    case off = 0
    case three = 3
    case ten = 10
}

enum CameraResolution: String, CaseIterable {
    case standard
    case maximum
}

struct PhotoDimensions: Equatable {
    let width: Int32
    let height: Int32

    var pixels: Int64 { Int64(width) * Int64(height) }

    static func standard(in options: [PhotoDimensions]) -> PhotoDimensions? {
        options.min { abs($0.pixels - 24_000_000) < abs($1.pixels - 24_000_000) }
    }
}

enum CameraRotation {
    static func angle(for orientation: UIInterfaceOrientation) -> CGFloat {
        switch orientation {
        case .portrait: 90
        case .portraitUpsideDown: 270
        case .landscapeLeft: 0
        case .landscapeRight: 180
        default: 90
        }
    }
}

final class CameraSession: NSObject, ObservableObject, @unchecked Sendable {
    enum State: Equatable {
        case starting
        case running
        case interrupted
        case permissionDenied
        case unavailable
    }

    @Published private(set) var state: State = .starting
    @Published private(set) var isCapturing = false
    @Published private(set) var maxZoom: CGFloat = 1
    @Published private(set) var supportsMaximumResolution = false
    @Published var zoom: CGFloat = 1
    @Published var exposure: Float = 0
    @Published var flash: CameraFlash = .off
    @Published var ratio: CameraRatio = .fourThree
    @Published var timer: CameraTimer = .off
    @Published var resolution: CameraResolution = .standard
    @Published var showsGrid = true
    @Published var savesOriginal = false
    var photoLocation: CLLocation?
    @Published private(set) var activeFilter: FilterRecipe?
    @Published private(set) var filterIntensity = 1.0
    @Published private(set) var filteredPreview: CGImage?
    @Published private(set) var measurement: SceneMeasurement?
    @Published private(set) var guidance: Guidance?
    @Published private(set) var filterSaveSequence = 0
    @Published private(set) var latestThumbnail: CGImage?
    @Published var notice: String?

    let session = AVCaptureSession()

    private let queue = DispatchQueue(label: "com.pnhd.focelle.camera")
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let filterRenderer = FilterRenderer()
    private let analyzer = OnDeviceAnalyzer()
    private var input: AVCaptureDeviceInput?
    private var configured = false
    private var rotationAngle: CGFloat = 90
    private var pendingRatio: CameraRatio = .fourThree
    private var pendingFilter: FilterRecipe?
    private var pendingFilterIntensity = 1.0
    private var pendingSaveOriginal = false
    private var pendingLocation: CLLocation?
    private var standardDimensions: CMVideoDimensions?
    private var maximumDimensions: CMVideoDimensions?
    private var previewRecipe: FilterRecipe?
    private var previewIntensity = 1.0
    private var lastPreviewTime = CMTime.zero
    private var lastAnalysisTime = CMTime.zero
    private var analysisInFlight = false
    private var stabilizer = MeasurementStabilizer()
    private var guidanceEngine = GuidanceEngine()
    private var pendingAIPreview: (@Sendable (Data?) -> Void)?
    private var cloudPlan: AICompositionPlan?

    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(sessionWasInterrupted),
            name: AVCaptureSession.wasInterruptedNotification,
            object: session
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(sessionInterruptionEnded),
            name: AVCaptureSession.interruptionEndedNotification,
            object: session
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(sessionRuntimeError),
            name: AVCaptureSession.runtimeErrorNotification,
            object: session
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func start() {
#if targetEnvironment(simulator)
        state = .unavailable
#else
        switch CameraPermission(AVCaptureDevice.authorizationStatus(for: .video)) {
        case .allowed:
            configureAndStart()
        case .undecided:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] allowed in
                allowed ? self?.configureAndStart() : self?.publish(state: .permissionDenied)
            }
        case .denied:
            state = .permissionDenied
        }
#endif
    }

    func stop() {
        queue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    func setRotationAngle(_ angle: CGFloat) {
        queue.async { [weak self] in
            guard let self else { return }
            self.rotationAngle = angle
            if let connection = self.videoOutput.connection(with: .video),
               connection.isVideoRotationAngleSupported(angle)
            {
                connection.videoRotationAngle = angle
            }
        }
    }

    func applyFilter(_ recipe: FilterRecipe?, intensity: Double = 1) {
        let value = min(max(intensity, 0), 1)
        activeFilter = recipe
        filterIntensity = value
        if recipe == nil { filteredPreview = nil }
        queue.async { [weak self] in
            self?.previewRecipe = recipe
            self?.previewIntensity = value
        }
    }

    func switchCamera() {
        queue.async { [weak self] in
            guard let self, let oldInput = self.input else { return }
            let newPosition: AVCaptureDevice.Position = oldInput.device.position == .back ? .front : .back
            guard let device = Self.device(position: newPosition),
                  let newInput = try? AVCaptureDeviceInput(device: device)
            else {
                self.publish(notice: "camera.error.switch")
                return
            }

            self.session.beginConfiguration()
            self.session.removeInput(oldInput)
            if self.session.canAddInput(newInput) {
                self.session.addInput(newInput)
                self.input = newInput
                self.configureCapabilities(for: device)
                self.updateVideoConnection(for: device)
            } else {
                self.session.addInput(oldInput)
            }
            self.session.commitConfiguration()
        }
    }

    func setZoom(_ requested: CGFloat) {
        let clamped = min(max(requested, 1), maxZoom)
        DispatchQueue.main.async { self.zoom = clamped }
        configureDevice { device in device.videoZoomFactor = clamped }
    }

    func focus(at point: CGPoint) {
        configureDevice { device in
            if device.isFocusPointOfInterestSupported {
                device.focusPointOfInterest = point
                if device.isFocusModeSupported(.continuousAutoFocus) {
                    device.focusMode = .continuousAutoFocus
                }
            }
            if device.isExposurePointOfInterestSupported {
                device.exposurePointOfInterest = point
                if device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposureMode = .continuousAutoExposure
                }
            }
        }
    }

    func setExposure(_ requested: Float) {
        configureDevice { device in
            let value = min(max(requested, device.minExposureTargetBias), device.maxExposureTargetBias)
            device.setExposureTargetBias(value, completionHandler: nil)
            DispatchQueue.main.async { self.exposure = value }
        }
    }

    func capture() {
        guard !isCapturing else { return }
        let selectedFlash = flash
        let selectedRatio = ratio
        let selectedResolution = resolution
        let selectedFilter = activeFilter
        let selectedFilterIntensity = filterIntensity
        isCapturing = true

        queue.async { [weak self] in
            guard let self, self.session.isRunning else {
                self?.finishCapture()
                return
            }
            let settings = AVCapturePhotoSettings()
            settings.photoQualityPrioritization = .quality
            if self.photoOutput.supportedFlashModes.contains(selectedFlash.mode) {
                settings.flashMode = selectedFlash.mode
            }
            if let dimensions = selectedResolution == .maximum
                ? self.maximumDimensions
                : self.standardDimensions
            {
                settings.maxPhotoDimensions = dimensions
            }
            if let connection = self.photoOutput.connection(with: .video),
               connection.isVideoRotationAngleSupported(self.rotationAngle)
            {
                connection.videoRotationAngle = self.rotationAngle
            }
            self.pendingRatio = selectedRatio
            self.pendingFilter = selectedFilter
            self.pendingFilterIntensity = selectedFilterIntensity
            self.pendingSaveOriginal = self.savesOriginal
            self.pendingLocation = self.photoLocation
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    private func configureAndStart() {
        queue.async { [weak self] in
            guard let self else { return }
            if !self.configured && !self.configure() {
                self.publish(state: .unavailable)
                return
            }
            if !self.session.isRunning { self.session.startRunning() }
            self.publish(state: .running)
        }
    }

    private func configure() -> Bool {
        guard let device = Self.device(position: .back),
              let cameraInput = try? AVCaptureDeviceInput(device: device)
        else { return false }

        session.beginConfiguration()
        session.sessionPreset = .photo
        defer { session.commitConfiguration() }

        guard session.canAddInput(cameraInput),
              session.canAddOutput(photoOutput),
              session.canAddOutput(videoOutput)
        else { return false }
        session.addInput(cameraInput)
        session.addOutput(photoOutput)
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoOutput.setSampleBufferDelegate(self, queue: queue)
        session.addOutput(videoOutput)
        input = cameraInput
        configureCapabilities(for: device)
        updateVideoConnection(for: device)
        configured = true
        return true
    }

    @objc private func sessionWasInterrupted(_ notification: Notification) {
        publish(state: .interrupted)
    }

    @objc private func sessionInterruptionEnded(_ notification: Notification) {
        configureAndStart()
    }

    @objc private func sessionRuntimeError(_ notification: Notification) {
        let error = notification.userInfo?[AVCaptureSessionErrorKey] as? AVError
        if Self.canRestart(after: error) {
            configureAndStart()
        } else {
            publish(state: .unavailable)
        }
    }

    static func canRestart(after error: AVError?) -> Bool {
        error?.code == .mediaServicesWereReset
    }

    func requestAIPreview(_ completion: @escaping @Sendable (Data?) -> Void) {
        queue.async { [weak self] in
            self?.pendingAIPreview = completion
        }
    }

    func cancelAIPreview() {
        queue.async { [weak self] in
            self?.pendingAIPreview = nil
        }
    }

    func applyAIPlan(_ plan: AICompositionPlan) {
        setZoom(CGFloat(plan.zoom))
        setExposure(Float(plan.exposureBias))
        queue.async {
            self.cloudPlan = plan
            guard let measurement = self.measurement else { return }
            let guidance = Self.cloudGuidance(plan, measurement: measurement)
            DispatchQueue.main.async { self.guidance = guidance }
        }
    }

    func clearAIPlan() {
        queue.async {
            self.cloudPlan = nil
            guard let measurement = self.measurement else { return }
            let guidance = self.guidanceEngine.update(measurement)
            DispatchQueue.main.async { self.guidance = guidance }
        }
    }

    func selectSubject(at point: CGPoint) {
        queue.async { [weak self] in
            guard let self, var measurement = self.measurement else { return }
            let visionPoint = CGPoint(x: point.x, y: 1 - point.y)
            let candidates = measurement.faceRects
                + [measurement.subjectRect, measurement.salientRect].compactMap { $0 }
            guard let selected = candidates.min(by: {
                Self.distance(from: visionPoint, to: $0)
                    < Self.distance(from: visionPoint, to: $1)
            }) else { return }
            measurement.subjectRect = selected
            self.stabilizer = MeasurementStabilizer()
            let guidance = self.cloudPlan.map {
                Self.cloudGuidance($0, measurement: measurement)
            } ?? self.guidanceEngine.update(measurement)
            DispatchQueue.main.async {
                self.measurement = measurement
                self.guidance = guidance
            }
        }
    }

    private func updateVideoConnection(for device: AVCaptureDevice) {
        guard let connection = videoOutput.connection(with: .video) else { return }
        if connection.isVideoRotationAngleSupported(rotationAngle) {
            connection.videoRotationAngle = rotationAngle
        }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = device.position == .front
        }
    }

    private func configureCapabilities(for device: AVCaptureDevice) {
        let options = device.activeFormat.supportedMaxPhotoDimensions
        let sorted = options.sorted {
            Int64($0.width) * Int64($0.height) < Int64($1.width) * Int64($1.height)
        }
        let mapped = sorted.map { PhotoDimensions(width: $0.width, height: $0.height) }
        let standard = PhotoDimensions.standard(in: mapped)
        standardDimensions = sorted.first {
            $0.width == standard?.width && $0.height == standard?.height
        }
        maximumDimensions = sorted.last
        if let maximumDimensions {
            photoOutput.maxPhotoDimensions = maximumDimensions
        }

        let deviceMaxZoom = min(device.activeFormat.videoMaxZoomFactor, 10)
        let supportsMaximum =
            (maximumDimensions.map { Int64($0.width) * Int64($0.height) } ?? 0) > 30_000_000
        DispatchQueue.main.async {
            self.maxZoom = max(deviceMaxZoom, 1)
            self.zoom = 1
            self.exposure = 0
            self.supportsMaximumResolution = supportsMaximum
            if !self.supportsMaximumResolution { self.resolution = .standard }
        }
    }

    private static func device(position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera],
            mediaType: .video,
            position: position
        ).devices.first
    }

    private func configureDevice(_ change: @escaping @Sendable (AVCaptureDevice) -> Void) {
        queue.async { [weak self] in
            guard let device = self?.input?.device else { return }
            do {
                try device.lockForConfiguration()
                change(device)
                device.unlockForConfiguration()
            } catch {
                self?.publish(notice: "camera.error.configuration")
            }
        }
    }

    private func save(_ data: Data, countsFilter: Bool, showsThumbnail: Bool) {
        let location = pendingLocation
        let performSave: @Sendable () -> Void = {
            PHPhotoLibrary.shared().performChanges {
                let creation = PHAssetCreationRequest.forAsset()
                creation.location = location
                creation.addResource(with: .photo, data: data, options: nil)
            } completionHandler: { [weak self] saved, _ in
                self?.publish(notice: saved ? "camera.saved" : "camera.error.save")
                if saved, showsThumbnail, let thumbnail = UIImage(data: data)?.cgImage {
                    DispatchQueue.main.async { self?.latestThumbnail = thumbnail }
                }
                if saved, countsFilter {
                    DispatchQueue.main.async { self?.filterSaveSequence += 1 }
                }
            }
        }

        switch PHPhotoLibrary.authorizationStatus(for: .addOnly) {
        case .authorized, .limited:
            performSave()
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                if status == .authorized || status == .limited {
                    performSave()
                } else {
                    self.publish(notice: "camera.error.photosPermission")
                }
            }
        default:
            publish(notice: "camera.error.photosPermission")
        }
    }

    private func finishCapture() {
        DispatchQueue.main.async { self.isCapturing = false }
    }

    private func publish(state: State) {
        DispatchQueue.main.async { self.state = state }
    }

    private func publish(notice: String) {
        DispatchQueue.main.async {
            self.notice = notice
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.notice = nil }
        }
    }
}

extension CameraSession: AVCapturePhotoCaptureDelegate {
    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        defer { finishCapture() }
        guard error == nil, let data = photo.fileDataRepresentation() else {
            publish(notice: "camera.error.capture")
            return
        }
        let outputData = filterRenderer.renderedData(
            from: data,
            recipe: pendingFilter,
            intensity: pendingFilterIntensity,
            aspectRatio: pendingRatio == .fourThree ? nil : pendingRatio.value
        ) ?? data
        if pendingSaveOriginal, pendingFilter != nil {
            save(data, countsFilter: false, showsThumbnail: false)
        }
        save(outputData, countsFilter: pendingFilter != nil, showsThumbnail: true)
    }

    private static func distance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        hypot(point.x - rect.midX, point.y - rect.midY)
    }

    static func cloudGuidance(
        _ plan: AICompositionPlan,
        measurement: SceneMeasurement
    ) -> Guidance {
        let target = CGPoint(x: plan.target.cgRect.midX, y: plan.target.cgRect.midY)
        guard let visionRect = measurement.primaryRect else {
            return Guidance(
                target: target,
                direction: .none,
                instructionKey: "guidance.findSubject",
                aligned: false
            )
        }
        let subject = CGRect(
            x: visionRect.minX,
            y: 1 - visionRect.maxY,
            width: visionRect.width,
            height: visionRect.height
        )
        let x = subject.midX - target.x
        let y = subject.midY - target.y
        let areaRatio = subject.width * subject.height
            / max(plan.target.cgRect.width * plan.target.cgRect.height, 0.01)

        let direction: GuidanceDirection
        let key: String
        if let horizon = measurement.horizonAngle, abs(horizon) > 0.05 {
            direction = .level
            key = "guidance.level"
        } else if areaRatio < 0.65 {
            direction = .closer
            key = "guidance.closer"
        } else if areaRatio > 1.45 {
            direction = .farther
            key = "guidance.farther"
        } else if x < -0.06 {
            direction = .left
            key = "guidance.left"
        } else if x > 0.06 {
            direction = .right
            key = "guidance.right"
        } else if y < -0.07 {
            direction = .up
            key = "guidance.up"
        } else if y > 0.07 {
            direction = .down
            key = "guidance.down"
        } else {
            direction = .none
            key = "guidance.ready"
        }
        return Guidance(
            subjectRect: subject,
            target: target,
            direction: direction,
            instructionKey: key,
            instruction: direction == .none ? nil : plan.instruction,
            aligned: direction == .none
        )
    }
}

extension CameraSession: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let image = CIImage(cvPixelBuffer: buffer)

        if let completion = pendingAIPreview {
            pendingAIPreview = nil
            completion(filterRenderer.aiPreviewData(image))
        }

        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let analysisInterval = ProcessInfo.processInfo.thermalState == .nominal ? 0.35 : 0.8
        if !analysisInFlight,
           CMTimeGetSeconds(timestamp - lastAnalysisTime) >= analysisInterval
        {
            analysisInFlight = true
            lastAnalysisTime = timestamp
            analyzer.analyze(buffer) { [weak self] measurement in
                guard let self else { return }
                self.queue.async {
                    self.analysisInFlight = false
                    guard let measurement else { return }
                    let stable = self.stabilizer.update(measurement)
                    let guidance = self.cloudPlan.map {
                        Self.cloudGuidance($0, measurement: stable)
                    } ?? self.guidanceEngine.update(stable)
                    DispatchQueue.main.async {
                        self.measurement = stable
                        self.guidance = guidance
                    }
                }
            }
        }

        guard let recipe = previewRecipe else { return }
        guard CMTimeGetSeconds(timestamp - lastPreviewTime) >= 1.0 / 15.0 else { return }
        lastPreviewTime = timestamp

        guard let rendered = filterRenderer.previewImage(
            image,
            recipe: recipe,
            intensity: previewIntensity
        ) else { return }
        DispatchQueue.main.async { self.filteredPreview = rendered }
    }
}
