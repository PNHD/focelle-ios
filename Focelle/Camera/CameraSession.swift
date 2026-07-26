@preconcurrency import AVFoundation
import CoreImage
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

enum CameraFlash: String, CaseIterable {
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
    @Published var notice: String?

    let session = AVCaptureSession()

    private let queue = DispatchQueue(label: "com.pnhd.focelle.camera")
    private let photoOutput = AVCapturePhotoOutput()
    private let imageContext = CIContext(options: [.cacheIntermediates: false])
    private var input: AVCaptureDeviceInput?
    private var configured = false
    private var rotationAngle: CGFloat = 90
    private var pendingRatio: CameraRatio = .fourThree
    private var standardDimensions: CMVideoDimensions?
    private var maximumDimensions: CMVideoDimensions?

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
        queue.async { [weak self] in self?.rotationAngle = angle }
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

        guard session.canAddInput(cameraInput), session.canAddOutput(photoOutput) else { return false }
        session.addInput(cameraInput)
        session.addOutput(photoOutput)
        input = cameraInput
        configureCapabilities(for: device)
        configured = true
        return true
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

    private func configureDevice(_ change: @escaping (AVCaptureDevice) -> Void) {
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

    private func encodedData(_ data: Data, ratio: CameraRatio) -> Data? {
        guard ratio != .fourThree else { return data }
        guard let image = CIImage(data: data, options: [.applyOrientationProperty: true]),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        else { return nil }

        let extent = image.extent
        let target = ratio.value
        let current = extent.width / extent.height
        let crop: CGRect
        if current > target {
            let width = extent.height * target
            crop = CGRect(x: extent.midX - width / 2, y: extent.minY, width: width, height: extent.height)
        } else {
            let height = extent.width / target
            crop = CGRect(x: extent.minX, y: extent.midY - height / 2, width: extent.width, height: height)
        }
        let rendered = image
            .cropped(to: crop)
            .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
        return imageContext.heifRepresentation(
            of: rendered,
            format: .RGBA8,
            colorSpace: colorSpace
        ) ?? imageContext.jpegRepresentation(of: rendered, colorSpace: colorSpace)
    }

    private func save(_ data: Data) {
        let performSave = {
            PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
            } completionHandler: { [weak self] saved, _ in
                self?.publish(notice: saved ? "camera.saved" : "camera.error.save")
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
        guard error == nil,
              let data = photo.fileDataRepresentation(),
              let outputData = encodedData(data, ratio: pendingRatio)
        else {
            publish(notice: "camera.error.capture")
            return
        }
        save(outputData)
    }
}
