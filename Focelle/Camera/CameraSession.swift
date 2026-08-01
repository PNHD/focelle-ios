@preconcurrency import AVFoundation
@preconcurrency import CoreLocation
import ImageIO
import Photos
import SwiftUI
import UIKit
#if DEBUG
    import os
#endif

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

// The requested tier. `.standard` is the smallest meaningful tier, `.balanced`
// is the 24 MP class (delivered only through deferred photo processing), and
// `.maximum` is the highest this active camera and format can deliver — never
// a promise of a specific pixel count, since that varies by device and format.
// See ResolvedResolution for the truthful, dimension-based value a tier
// resolves to.
enum CameraResolution: String, CaseIterable, Sendable {
    case standard
    case balanced
    case maximum
}

struct PhotoDimensions: Equatable, Sendable {
    let width: Int32
    let height: Int32

    var pixels: Int64 { Int64(width) * Int64(height) }
}

// Every meaningful photo dimension the active format exposes, preserved in
// ascending pixel order, plus the three named tiers derived from it:
// standard = smallest, balanced = the 24 MP class (nearest to 24 MP when it is
// a genuinely distinct, larger tier), maximum = largest. A tier is nil when
// the format has no such distinct option — never invented.
struct PhotoCapabilityTiers: Equatable, Sendable {
    let supported: [PhotoDimensions]
    let standard: PhotoDimensions?
    let balanced: PhotoDimensions?
    let maximum: PhotoDimensions?

    static func resolve(from options: [PhotoDimensions]) -> PhotoCapabilityTiers {
        let supported = options
            .filter { $0.pixels > 0 }
            .sorted { $0.pixels < $1.pixels }
        let standard = supported.first
        let nearestTwentyFour = supported.min {
            abs($0.pixels - 24_000_000) < abs($1.pixels - 24_000_000)
        }
        let balanced =
            nearestTwentyFour.flatMap {
                $0.pixels > (standard?.pixels ?? 0) ? $0 : nil
            }
        return PhotoCapabilityTiers(
            supported: supported,
            standard: standard,
            balanced: balanced,
            maximum: supported.last
        )
    }
}

// Why a requested resolution did not resolve to a distinctly higher tier.
enum ResolutionDowngradeReason: String, Equatable, Sendable {
    case none
    // The active device/format offers nothing distinctly larger than standard.
    case unsupportedByActiveFormat
    // AVCapturePhotoOutput's own ceiling capped the request further.
    case outputLimited
    // The 24 MP tier is only serviced through deferred photo processing, and
    // this output does not support it.
    case deferredUnavailable
    // A filter or non-4:3 crop must be applied to the immediately delivered
    // photo; the deferred proxy path cannot honor that, so the capture
    // truthfully falls back to the standard tier.
    case immediateProcessingRequired
}

// The truthful three-way split this feature is built on: what the user
// asked for (`requested`), and what AVFoundation will actually be asked to
// capture (`dimensions`) — kept separate from what a finished photo turns
// out to contain (see CaptureResolutionRecord). A pure value type so the
// resolution rule is testable without any camera hardware.
struct ResolvedResolution: Equatable, Sendable {
    var requested: CameraResolution
    var dimensions: PhotoDimensions?
    var downgradeReason: ResolutionDowngradeReason

    var isDowngraded: Bool { downgradeReason != .none }

    var label: String { Self.label(for: dimensions) }

    // A known megapixel bucket when the dimensions land close to one;
    // otherwise the literal pixel dimensions. Never a borrowed "24"/"48"
    // the hardware didn't actually deliver.
    static func label(for dimensions: PhotoDimensions?) -> String {
        guard let dimensions, dimensions.pixels > 0 else { return "—" }
        let megapixels = Double(dimensions.pixels) / 1_000_000
        let knownBuckets: [Double] = [12, 24, 48]
        if let nearest = knownBuckets.min(by: { abs($0 - megapixels) < abs($1 - megapixels) }),
            abs(nearest - megapixels) <= 2
        {
            return "\(Int(nearest))"
        }
        return "\(dimensions.width)×\(dimensions.height)"
    }

    // Whether the active format actually offers a maximum tier distinctly
    // larger than standard — the only truthful basis for exposing a
    // "maximum" choice at all.
    static func hasDistinctMaximum(standard: PhotoDimensions?, maximum: PhotoDimensions?) -> Bool {
        guard let standard, let maximum else { return false }
        return maximum.pixels > standard.pixels
    }

    // The explicit, deterministic resolution rule: standard always maps to
    // the smallest tier; balanced maps to the distinct 24 MP tier when one
    // exists and deferred delivery is supported (else a truthful fallback to
    // standard); maximum maps to the distinct larger tier when one exists,
    // else falls back to standard rather than silently claiming a capability
    // that isn't there. The output's own ceiling is applied last.
    static func resolve(
        requested: CameraResolution,
        standard: PhotoDimensions?,
        balanced: PhotoDimensions?,
        maximum: PhotoDimensions?,
        outputLimit: PhotoDimensions?,
        deferredSupported: Bool
    ) -> ResolvedResolution {
        guard let standard else {
            return ResolvedResolution(requested: requested, dimensions: nil, downgradeReason: .none)
        }
        let distinctBalanced = balanced.map { $0.pixels > standard.pixels } ?? false
        let distinctMaximum = hasDistinctMaximum(standard: standard, maximum: maximum)
        var ideal = standard
        var reason = ResolutionDowngradeReason.none
        switch requested {
        case .standard:
            break
        case .balanced:
            if distinctBalanced, deferredSupported {
                ideal = balanced ?? standard
            } else if !distinctBalanced {
                reason = .unsupportedByActiveFormat
            } else {
                reason = .deferredUnavailable
            }
        case .maximum:
            if distinctMaximum {
                ideal = maximum ?? standard
            } else {
                reason = .unsupportedByActiveFormat
            }
        }
        if let outputLimit, outputLimit.pixels > 0, ideal.pixels > outputLimit.pixels {
            ideal = outputLimit
            reason = .outputLimited
        }
        return ResolvedResolution(requested: requested, dimensions: ideal, downgradeReason: reason)
    }
}

// Privacy-safe record of what actually happened at capture: the requested
// tier, what the capture was configured to request, what the deferred proxy
// contained, and what the finished photo turned out to contain. Dimensions
// and enum labels only — never image bytes, scene content, or identifiers.
struct CaptureResolutionRecord: Equatable, Sendable {
    let requested: CameraResolution
    // What the capture was configured to request from AVFoundation.
    let resolvedDimensions: PhotoDimensions?
    // Pixel dimensions of the deferred proxy JPEG the system delivered
    // instead of the full photo (nil for the normal immediate path).
    let proxyResolvedDimensions: PhotoDimensions?
    // What the finished photo actually contains: the saved JPEG for the
    // normal path, or Photos' completed asset dimensions for the deferred
    // path. Nil while a deferred photo is still being fused by Photos.
    let savedDimensions: PhotoDimensions?
    let downgradeReason: ResolutionDowngradeReason

    var isDowngraded: Bool { downgradeReason != .none }
    var requestedLabel: String { requested.rawValue }
    var isDeferredProxy: Bool { proxyResolvedDimensions != nil }
    var isFinalized: Bool { savedDimensions != nil }

    init(
        requested: CameraResolution,
        resolvedDimensions: PhotoDimensions?,
        proxyResolvedDimensions: PhotoDimensions? = nil,
        savedDimensions: PhotoDimensions?,
        downgradeReason: ResolutionDowngradeReason = .none
    ) {
        self.requested = requested
        self.resolvedDimensions = resolvedDimensions
        self.proxyResolvedDimensions = proxyResolvedDimensions
        self.savedDimensions = savedDimensions
        self.downgradeReason = downgradeReason
    }

    // Pure transition used by the Photos change observer: a deferred record
    // is finalized only once Photos reports asset dimensions that are no
    // longer the proxy's (ideally the requested 24 MP size). Until then the
    // capture must not be reported as a completed 24 MP photo.
    static func deferredConfirmation(
        for pending: CaptureResolutionRecord,
        assetDimensions: PhotoDimensions?
    ) -> CaptureResolutionRecord? {
        guard pending.isDeferredProxy, !pending.isFinalized,
            let assetDimensions, assetDimensions.pixels > 0
        else { return nil }
        guard assetDimensions != pending.proxyResolvedDimensions else { return nil }
        return CaptureResolutionRecord(
            requested: pending.requested,
            resolvedDimensions: pending.resolvedDimensions,
            proxyResolvedDimensions: pending.proxyResolvedDimensions,
            savedDimensions: assetDimensions,
            downgradeReason: pending.downgradeReason
        )
    }
}

// A single immutable snapshot taken on `queue` at the moment of an actual
// capture. Both the AVCapturePhotoSettings sent to the output and the
// eventual CaptureResolutionRecord are built from this one value, so they
// can never disagree — and `capabilityGeneration` ties it to the exact
// capability set (device/format) it was resolved against.
struct CaptureResolutionSnapshot: Equatable, Sendable {
    let resolved: ResolvedResolution
    let capabilityGeneration: Int
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
    // Not directly settable from outside — setRequestedResolution(_:) is the
    // one path in, so this can no longer drift from AppSettings the way a
    // freely-writable property could.
    @Published private(set) var resolution: CameraResolution = .balanced {
        didSet {
            guard resolution != oldValue else { return }
            recomputeResolvedResolution()
        }
    }
    @Published private(set) var resolvedResolution = ResolvedResolution(
        requested: .balanced,
        dimensions: nil,
        downgradeReason: .none
    )
    @Published private(set) var standardModeLabel = "—"
    @Published private(set) var balancedModeLabel = "—"
    @Published private(set) var maximumModeLabel = "—"
    @Published private(set) var supportsBalancedResolution = false
    @Published private(set) var lastCaptureResolution: CaptureResolutionRecord?
    @Published var showsGrid = true
    @Published var savesOriginal = false
    var photoLocation: CLLocation?
    @Published private(set) var activeFilter: FilterRecipe?
    @Published private(set) var filterIntensity = 1.0
    @Published private(set) var filteredPreview: CGImage?
    @Published private(set) var filterThumbnails: [String: CGImage] = [:]
    @Published private(set) var measurement: SceneMeasurement?
    @Published private(set) var sceneDescriptor: SceneDescriptor?
    @Published private(set) var guidance: Guidance?
    @Published private(set) var coachPlans: [CoachPlan] = []
    @Published private(set) var selectedCoachPlan: CoachPlan?
    @Published private(set) var coachSession: PlanSession?
    @Published private(set) var coachPlanApplied = false
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
    private let deferredObserver = DeferredCompletionObserver()
    // Main-thread only: deferred proxy captures waiting for Photos to finish
    // fusing the full photo, keyed by the created asset's local identifier.
    private var pendingDeferredConfirmations: [String: CaptureResolutionRecord] = [:]
    private var configured = false
    private var rotationAngle: CGFloat = 90
    private var pendingRatio: CameraRatio = .fourThree
    private var pendingFilter: FilterRecipe?
    private var pendingFilterIntensity = 1.0
    private var pendingSaveOriginal = false
    private var pendingLocation: CLLocation?
    private var pendingCaptureSnapshot = CaptureResolutionSnapshot(
        resolved: ResolvedResolution(requested: .balanced, dimensions: nil, downgradeReason: .none),
        capabilityGeneration: 0
    )
    // Queue-owned canonical capability state — currentCaptureSnapshot(for:)
    // reads these directly so a capture is never configured from stale or
    // independently-drifted dimensions. Not `private`: regression tests
    // simulate a capability change without a real device.
    var standardDimensions: PhotoDimensions?
    var balancedDimensions: PhotoDimensions?
    var maximumDimensions: PhotoDimensions?
    var outputLimitDimensions: PhotoDimensions?
    // Every meaningful dimension the active format exposes, ascending.
    var supportedPhotoDimensions: [PhotoDimensions] = []
    var deferredDeliverySupported = false
    // Bumped every time configureCapabilities(for:) runs (initial configure,
    // camera switch); ties a snapshot to the exact capability set it came from.
    var capabilityGeneration = 0
    // Main-thread mirrors of the capability state above, so resolution's
    // didSet can recompute the UI-facing resolvedResolution without reaching
    // across queue-owned state. Never used to configure an actual capture.
    // Not `private`: regression tests simulate a capability change.
    var cachedStandardDimensions: PhotoDimensions?
    var cachedBalancedDimensions: PhotoDimensions?
    var cachedMaximumDimensions: PhotoDimensions?
    var cachedOutputLimit: PhotoDimensions?
    var cachedDeferredDeliverySupported = false
    private var cachedCapabilityGeneration = 0
    private var previewRecipe: FilterRecipe?
    private var previewIntensity = 1.0
    private var lastPreviewTime = CMTime.zero
    private var thumbnailRequests: [FilterThumbnailRequest] = []
    private var lastThumbnailTime = CMTime.zero
    private var lastAnalysisTime = CMTime.zero
    private var stabilizer = MeasurementStabilizer()
    private var descriptorStabilizer = DescriptorStabilizer()
    private var guidanceEngine = GuidanceEngine()
    private var pendingAIPreview: (@Sendable (Data?) -> Void)?
    private var cloudPlan: AICompositionPlan?
    private var selectedSubjectPoint: CGPoint?
    // Not `private`: regression tests confirm a resume can't leave this wedged.
    var analysisInFlight = false
    var analysisGeneration = 0

    #if DEBUG
        private let lifecycleLog = Logger(subsystem: "com.pnhd.focelle", category: "camera.lifecycle")
    #endif

    override init() {
        super.init()
        deferredObserver.onChange = { [weak self] change in
            self?.handlePhotoLibraryChange(change)
        }
        PHPhotoLibrary.shared().register(deferredObserver)
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
        PHPhotoLibrary.shared().unregisterChangeObserver(deferredObserver)
        NotificationCenter.default.removeObserver(self)
    }

    func start() {
        #if targetEnvironment(simulator)
            state = .unavailable
        #else
            let permission = CameraPermission(AVCaptureDevice.authorizationStatus(for: .video))
            #if DEBUG
                lifecycleLog.debug("start requested (permission=\(String(describing: permission), privacy: .public))")
            #endif
            switch permission {
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
            #if DEBUG
                self.lifecycleLog.debug("session stop")
            #endif
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

    func setFilterThumbnailRequests(_ requests: [FilterThumbnailRequest]) {
        queue.async { [weak self] in
            guard let self, self.thumbnailRequests != requests else { return }
            self.thumbnailRequests = requests
            self.lastThumbnailTime = .zero
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
                self.selectedSubjectPoint = nil
                self.resetAnalysisForResume()
                self.configureCapabilities(for: device)
                self.updateVideoConnection(for: device)
            } else {
                self.session.addInput(oldInput)
            }
            self.session.commitConfiguration()
        }
    }

    // The one path that may change `resolution` — AppSettings.requestedResolution
    // is the persisted single source of truth; CameraView mirrors it in here on
    // appear/change instead of writing `resolution` directly, so the toolbar and
    // Settings can no longer drift apart. Does not touch zoom or exposure.
    func setRequestedResolution(_ mode: CameraResolution) {
        resolution = mode
    }

    // Not `private`: regression tests simulate a capability change directly.
    func recomputeResolvedResolution() {
        let balancedResolution = ResolvedResolution.resolve(
            requested: .balanced,
            standard: cachedStandardDimensions,
            balanced: cachedBalancedDimensions,
            maximum: cachedMaximumDimensions,
            outputLimit: cachedOutputLimit,
            deferredSupported: cachedDeferredDeliverySupported
        )
        balancedModeLabel = balancedResolution.label
        supportsBalancedResolution =
            !balancedResolution.isDowngraded && balancedResolution.dimensions != nil
        resolvedResolution = ResolvedResolution.resolve(
            requested: resolution,
            standard: cachedStandardDimensions,
            balanced: cachedBalancedDimensions,
            maximum: cachedMaximumDimensions,
            outputLimit: cachedOutputLimit,
            deferredSupported: cachedDeferredDeliverySupported
        )
        standardModeLabel =
            ResolvedResolution.resolve(
                requested: .standard,
                standard: cachedStandardDimensions,
                balanced: cachedBalancedDimensions,
                maximum: cachedMaximumDimensions,
                outputLimit: cachedOutputLimit,
                deferredSupported: cachedDeferredDeliverySupported
            ).label
        maximumModeLabel =
            ResolvedResolution.resolve(
                requested: .maximum,
                standard: cachedStandardDimensions,
                balanced: cachedBalancedDimensions,
                maximum: cachedMaximumDimensions,
                outputLimit: cachedOutputLimit,
                deferredSupported: cachedDeferredDeliverySupported
            ).label
    }

    // Runs on `queue`. The one place a resolved snapshot is built for an
    // actual capture, from the queue-owned capability state current at this
    // exact moment — never the main-thread cache used for UI, and never
    // reconstructed a second time for the saved record (see capture()).
    // Not `private` so regression tests can drive it directly.
    func currentCaptureSnapshot(for requested: CameraResolution) -> CaptureResolutionSnapshot {
        Self.captureSnapshot(
            requested: requested,
            requiresImmediateProcessing: false,
            standard: standardDimensions,
            balanced: balancedDimensions,
            maximum: maximumDimensions,
            outputLimit: outputLimitDimensions,
            deferredSupported: deferredDeliverySupported,
            capabilityGeneration: capabilityGeneration
        )
    }

    // The pure capture-time resolution rule, including the one constraint
    // deferred delivery cannot honor: in-app post-processing (a filter or a
    // non-4:3 crop) needs the immediately delivered photo, so a balanced
    // capture with that constraint truthfully resolves to the standard tier.
    static func captureSnapshot(
        requested: CameraResolution,
        requiresImmediateProcessing: Bool,
        standard: PhotoDimensions?,
        balanced: PhotoDimensions?,
        maximum: PhotoDimensions?,
        outputLimit: PhotoDimensions?,
        deferredSupported: Bool,
        capabilityGeneration: Int
    ) -> CaptureResolutionSnapshot {
        var snapshot = CaptureResolutionSnapshot(
            resolved: ResolvedResolution.resolve(
                requested: requested,
                standard: standard,
                balanced: balanced,
                maximum: maximum,
                outputLimit: outputLimit,
                deferredSupported: deferredSupported
            ),
            capabilityGeneration: capabilityGeneration
        )
        if requiresImmediateProcessing, requested == .balanced, snapshot.resolved.downgradeReason == .none {
            let fallback = ResolvedResolution.resolve(
                requested: .standard,
                standard: standard,
                balanced: balanced,
                maximum: maximum,
                outputLimit: outputLimit,
                deferredSupported: deferredSupported
            )
            snapshot = CaptureResolutionSnapshot(
                resolved: ResolvedResolution(
                    requested: .balanced,
                    dimensions: fallback.dimensions,
                    downgradeReason: .immediateProcessingRequired
                ),
                capabilityGeneration: capabilityGeneration
            )
        }
        return snapshot
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
            // Taken on `queue` right now, from queue-owned capability state —
            // not a main-thread cache — so this exact snapshot is what both
            // configures the output below and becomes the saved record; a
            // concurrent camera switch can't leave the two disagreeing.
            // A filter or a non-4:3 crop is applied to the immediately
            // delivered photo; the deferred 24 MP proxy path cannot honor
            // that, so the snapshot accounts for it up front.
            let snapshot = Self.captureSnapshot(
                requested: selectedResolution,
                requiresImmediateProcessing: selectedFilter != nil || selectedRatio != .fourThree,
                standard: self.standardDimensions,
                balanced: self.balancedDimensions,
                maximum: self.maximumDimensions,
                outputLimit: self.outputLimitDimensions,
                deferredSupported: self.deferredDeliverySupported,
                capabilityGeneration: self.capabilityGeneration
            )
            // capturePhoto raises NSInvalidArgumentException for any setting the output
            // does not allow, and an ObjC exception cannot be caught in Swift, so every
            // value below is taken from what the output itself reports.
            let settings = AVCapturePhotoSettings()
            settings.photoQualityPrioritization = self.photoOutput.maxPhotoQualityPrioritization
            if self.photoOutput.supportedFlashModes.contains(selectedFlash.mode) {
                settings.flashMode = selectedFlash.mode
            }
            if let dimensions = snapshot.resolved.dimensions {
                settings.maxPhotoDimensions = CMVideoDimensions(
                    width: dimensions.width,
                    height: dimensions.height
                )
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
            self.pendingCaptureSnapshot = snapshot
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
            let wasRunning = self.session.isRunning
            if !wasRunning { self.session.startRunning() }
            #if DEBUG
                self.lifecycleLog.debug("session start (wasRunning=\(wasRunning, privacy: .public))")
            #endif
            // A session that was not already running just resumed (first launch,
            // Settings dismissal, interruption recovery, ...). Whatever the analyzer
            // was doing before is stale, so give it a clean slate rather than trust
            // in-flight/generation state that predates the pause.
            if !wasRunning { self.resetAnalysisForResume() }
            self.publish(state: .running)
        }
    }

    // Settings is a sheet over a still-running session — nothing here stops
    // or reconfigures the capture session, camera settings (zoom, exposure,
    // ratio, filter, flash, timer) are untouched, and no cloud AI state is
    // involved. Safe to call repeatedly; each call just invalidates whatever
    // analysis was in flight and lets the next frame start clean.
    func refreshLocalGuidanceAfterSettings() {
        queue.async { [weak self] in
            self?.resetAnalysisForResume()
        }
    }

    // Runs on `queue`. Also used by switchCamera() and
    // refreshLocalGuidanceAfterSettings(), which need the same clean slate.
    // Not `private` so regression tests can drive it directly.
    func resetAnalysisForResume() {
        analysisInFlight = false
        analysisGeneration += 1
        analyzer.resetTracking()
        stabilizer = MeasurementStabilizer()
        descriptorStabilizer = DescriptorStabilizer()
        guidanceEngine = GuidanceEngine()
        #if DEBUG
            lifecycleLog.debug("analyzer reset for resume (generation=\(self.analysisGeneration, privacy: .public))")
        #endif
        DispatchQueue.main.async {
            self.measurement = nil
            self.sceneDescriptor = nil
            self.guidance = nil
        }
    }

    #if DEBUG
        // Lets regression tests dirty published state before asserting that a
        // resume clears it; production code never needs to set these directly.
        func debugSeedGuidanceForTesting(measurement: SceneMeasurement?, guidance: Guidance?) {
            self.measurement = measurement
            self.guidance = guidance
        }
    #endif

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

    // A result that started before the most recent reset (camera switch, resume
    // from a stopped session, Settings dismissal) belongs to a scene that no
    // longer applies.
    static func shouldAcceptAnalysis(requestGeneration: Int, currentGeneration: Int) -> Bool {
        requestGeneration == currentGeneration
    }

    // Runs on `queue`. A reset (resume, camera switch, Settings dismissal) can
    // fire while an older request is still processing in the analyzer's own
    // queue; that request's generation is now stale, and ownership of
    // `analysisInFlight` has already passed to whichever request matches the
    // current generation. A stale completion must not clear a flag it no
    // longer owns, so the generation check gates the clear rather than
    // following it. Returns whether this completion owns the in-flight slot
    // and should have its result processed.
    func acceptAnalysisCompletion(requestGeneration: Int) -> Bool {
        guard Self.shouldAcceptAnalysis(requestGeneration: requestGeneration, currentGeneration: analysisGeneration)
        else { return false }
        analysisInFlight = false
        return true
    }

    static func photoDimensions(
        _ requested: CMVideoDimensions?,
        within limit: CMVideoDimensions
    ) -> CMVideoDimensions? {
        let allowed = Int64(limit.width) * Int64(limit.height)
        guard allowed > 0, let requested else { return nil }
        let wanted = Int64(requested.width) * Int64(requested.height)
        guard wanted > 0 else { return nil }
        return wanted <= allowed ? requested : limit
    }

    // Reads the pixel dimensions actually saved, without decoding image
    // content — this is what proves or disproves a resolution claim.
    static func pixelDimensions(of data: Data) -> PhotoDimensions? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return PhotoDimensions(width: Int32(width), height: Int32(height))
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

    // Coach V2 local planning. Analyze only snapshots the zoom/exposure
    // baseline and creates plans — it never mutates the camera.
    func analyzeSceneV2() {
        guard let descriptor = sceneDescriptor else {
            publish(notice: "coach.error.noScene")
            return
        }
        let templates = PoseTemplateStore.shared.templates
        let capabilities = LocalPlanner.Capabilities(
            maxZoom: Double(maxZoom),
            aspectRatio: Double(ratio.value)
        )
        let plans = LocalPlanner.plan(
            scene: descriptor,
            intent: Self.framingIntent(for: descriptor),
            templates: templates,
            capabilities: capabilities,
            selectedSubject: descriptor.subjectRect
        )
        guard !plans.isEmpty else {
            publish(notice: "coach.error.noPlans")
            return
        }
        coachSession = PlanSession(
            baselineZoom: Double(zoom),
            baselineExposureBias: Double(exposure),
            capabilityGeneration: cachedCapabilityGeneration
        )
        coachPlans = plans
        coachPlanApplied = false
        selectCoachPlan(plans[0].id)
    }

    func selectCoachPlan(_ id: String) {
        guard let plan = coachPlans.first(where: { $0.id == id }) else { return }
        selectedCoachPlan = plan
        coachPlanApplied = false
        updateCoachGuidance(for: plan, descriptor: sceneDescriptor)
    }

    // Explicit Apply uses absolute zoom/exposure values from the plan —
    // never relative to the current value, so repeated cycles cannot drift.
    func applyCoachPlan(_ id: String) {
        guard let plan = coachPlans.first(where: { $0.id == id }),
            let session = coachSession,
            session.isValid(for: cachedCapabilityGeneration)
        else { return }
        coachSession = session.applying(
            zoom: plan.recommendedZoom,
            exposureBias: plan.recommendedExposureBias
        )
        setZoom(CGFloat(plan.recommendedZoom))
        setExposure(Float(plan.recommendedExposureBias))
        coachPlanApplied = true
        selectedCoachPlan = plan
        updateCoachGuidance(for: plan, descriptor: sceneDescriptor)
    }

    // Undo restores the exact pre-Analyze baseline.
    func undoCoachPlan() {
        guard let session = coachSession, coachPlanApplied else { return }
        let undo = session.undo
        coachSession = session.undoing()
        setZoom(CGFloat(undo.zoom))
        setExposure(Float(undo.exposureBias))
        coachPlanApplied = false
        refreshLocalGuidanceAfterSettings()
    }

    static func framingIntent(for descriptor: SceneDescriptor) -> FramingIntent {
        if descriptor.classifications.contains("group") { return .group }
        if descriptor.classifications.contains("onePerson") {
            let subject = descriptor.subjectRect ?? .zero
            return subject.height > 0.65 ? .fullBody : .portrait
        }
        if descriptor.horizonAngle != nil, descriptor.saliencyRect == nil { return .scenery }
        if descriptor.saliencyRect != nil { return .product }
        return .portrait
    }

    private func updateCoachGuidance(for plan: CoachPlan, descriptor: SceneDescriptor?) {
        guard let descriptor, let subject = descriptor.subjectRect else {
            guidance = nil
            return
        }
        let frame = plan.targetFraming
        let targetRect = CGRect(
            x: frame.centerX - frame.subjectWidth / 2,
            y: 1 - frame.centerY - frame.subjectHeight / 2,
            width: frame.subjectWidth,
            height: frame.subjectHeight
        )
        let target = CGPoint(x: frame.centerX, y: 1 - frame.centerY)
        let instruction =
            Locale.current.language.languageCode?.identifier == "vi"
            ? plan.instructionVI : plan.instructionEN
        guidance = Guidance(
            subjectRect: subject,
            target: target,
            targetRect: targetRect,
            direction: .none,
            instructionKey: "coach.v2.aligned",
            instruction: instruction,
            aligned: true
        )
    }

    func selectSubject(at point: CGPoint) {
        queue.async { [weak self] in
            guard let self else { return }
            let visionPoint = CGPoint(x: point.x, y: 1 - point.y)
            self.selectedSubjectPoint = visionPoint
            guard var measurement = self.measurement,
                let selected = measurement.subject(near: visionPoint)
            else { return }
            measurement.subjectRect = selected
            self.selectedSubjectPoint = CGPoint(x: selected.midX, y: selected.midY)
            self.analyzer.track(selected)
            self.stabilizer = MeasurementStabilizer()
            let guidance =
                self.cloudPlan.map {
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
        let tiers = PhotoCapabilityTiers.resolve(
            from: device.activeFormat.supportedMaxPhotoDimensions.map {
                PhotoDimensions(width: $0.width, height: $0.height)
            }
        )
        if let maximum = tiers.maximum {
            photoOutput.maxPhotoDimensions = CMVideoDimensions(
                width: maximum.width,
                height: maximum.height
            )
        }
        // Raise the ceiling here rather than per capture: the output defaults to
        // .balanced and rejects a higher value on the settings object.
        photoOutput.maxPhotoQualityPrioritization = .quality
        // The 24 MP tier is only serviced as a fused photo through automatic
        // deferred delivery. Enable it before the session starts or
        // reconfigures — configure() and switchCamera() both call this inside
        // beginConfiguration/commitConfiguration — and only when supported.
        let deferredSupported = photoOutput.isAutoDeferredPhotoDeliverySupported
        if deferredSupported {
            photoOutput.isAutoDeferredPhotoDeliveryEnabled = true
        }
        let outputLimitPhoto = PhotoDimensions(
            width: photoOutput.maxPhotoDimensions.width,
            height: photoOutput.maxPhotoDimensions.height
        )

        // The queue-owned truth a capture snapshot is built from. Bumping the
        // generation here — rather than only replacing the values — is what
        // lets a snapshot be tied to (and a stale one told apart from) the
        // exact capability set it was resolved against.
        standardDimensions = tiers.standard
        balancedDimensions = tiers.balanced
        maximumDimensions = tiers.maximum
        supportedPhotoDimensions = tiers.supported
        deferredDeliverySupported = deferredSupported
        outputLimitDimensions = outputLimitPhoto
        capabilityGeneration += 1

        let deviceMaxZoom = min(device.activeFormat.videoMaxZoomFactor, 10)
        let generation = capabilityGeneration
        // Whether the device/format genuinely has more to offer than standard —
        // not an arbitrary pixel-count threshold, so a modest-but-real jump
        // (or a hardware ceiling below any "48 MP" claim) is represented truthfully.
        let supportsMaximum = ResolvedResolution.hasDistinctMaximum(
            standard: tiers.standard,
            maximum: tiers.maximum
        )
        DispatchQueue.main.async {
            self.maxZoom = max(deviceMaxZoom, 1)
            self.zoom = 1
            self.exposure = 0
            self.supportsMaximumResolution = supportsMaximum
            // The requested tier is the user's intent (AppSettings.requestedResolution)
            // and survives a temporarily-incapable camera unchanged; only the
            // resolved dimensions/downgrade reason reflect this camera's limits.
            self.cachedStandardDimensions = tiers.standard
            self.cachedBalancedDimensions = tiers.balanced
            self.cachedMaximumDimensions = tiers.maximum
            self.cachedOutputLimit = outputLimitPhoto
            self.cachedDeferredDeliverySupported = deferredSupported
            self.cachedCapabilityGeneration = generation
            // A camera switch or capability-generation change invalidates any
            // active PlanSession: its baseline and plans belong to the old
            // camera/capability set.
            self.coachPlans = []
            self.selectedCoachPlan = nil
            self.coachSession = nil
            self.coachPlanApplied = false
            self.recomputeResolvedResolution()
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

    // The 24 MP tier arrives only as a deferred proxy; Photos fuses the full
    // photo in the background. Save the proxy bytes verbatim — Photos expects
    // the unmodified proxy — and keep the capture pending until the change
    // observer confirms the completed asset's dimensions.
    private func saveDeferredProxy(
        _ data: Data,
        record: CaptureResolutionRecord,
        showsThumbnail: Bool
    ) {
        let location = pendingLocation
        let placeholder = PlaceholderBox()
        let performSave: @Sendable () -> Void = {
            PHPhotoLibrary.shared().performChanges {
                let creation = PHAssetCreationRequest.forAsset()
                creation.location = location
                creation.addResource(with: .photoProxy, data: data, options: nil)
                placeholder.value = creation.placeholderForCreatedAsset
            } completionHandler: { [weak self] saved, _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.publish(notice: saved ? "camera.savedDeferred" : "camera.error.save")
                    guard saved else { return }
                    if let identifier = placeholder.value?.localIdentifier {
                        self.pendingDeferredConfirmations[identifier] = record
                    }
                    if showsThumbnail, let thumbnail = UIImage(data: data)?.cgImage {
                        self.latestThumbnail = thumbnail
                    }
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

    private func handlePhotoLibraryChange(_ change: PHChange) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.pendingDeferredConfirmations.isEmpty else { return }
            let pending = self.pendingDeferredConfirmations
            for (identifier, record) in pending {
                guard let asset = PHAsset.fetchAssets(
                    withLocalIdentifiers: [identifier], options: nil
                ).firstObject
                else { continue }
                let dimensions = PhotoDimensions(
                    width: Int32(asset.pixelWidth),
                    height: Int32(asset.pixelHeight)
                )
                guard let finalized = CaptureResolutionRecord.deferredConfirmation(
                    for: record, assetDimensions: dimensions
                ) else { continue }
                self.pendingDeferredConfirmations[identifier] = nil
                self.lastCaptureResolution = finalized
            }
        }
    }

    private func finishCapture() {
        DispatchQueue.main.async { self.isCapturing = false }
    }

    private func publish(state: State) {
        #if DEBUG
            lifecycleLog.debug("session state -> \(String(describing: state), privacy: .public)")
        #endif
        DispatchQueue.main.async { self.state = state }
    }

    private func publish(notice: String) {
        DispatchQueue.main.async {
            self.notice = notice
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.notice = nil }
        }
    }
}

// Photos' placeholder is not Sendable; the box keeps the created-asset
// identifier usable across performChanges' @Sendable closures.
private final class PlaceholderBox: @unchecked Sendable {
    var value: PHObjectPlaceholder?
}

// Bridges Photos change observation into CameraSession without adding a
// MainActor-isolated protocol conformance to the camera queue class. Photos
// calls this on the main thread; handlePhotoLibraryChange hops there
// defensively anyway.
private final class DeferredCompletionObserver: NSObject, PHPhotoLibraryChangeObserver {
    var onChange: ((PHChange) -> Void)?

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        onChange?(changeInstance)
    }
}

extension CameraSession: AVCapturePhotoCaptureDelegate {
    // With automatic deferred photo delivery enabled, a 24 MP capture arrives
    // as a proxy instead of the full photo. The proxy is saved verbatim so
    // Photos can fuse the final image; final dimensions are confirmed later
    // through the change observer, never claimed here.
    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishCapturingDeferredPhotoProxy proxy: AVCapturePhoto,
        error: Error?
    ) {
        defer { finishCapture() }
        guard error == nil, let data = proxy.fileDataRepresentation() else {
            publish(notice: "camera.error.capture")
            return
        }
        let snapshot = pendingCaptureSnapshot
        let record = CaptureResolutionRecord(
            requested: snapshot.resolved.requested,
            resolvedDimensions: snapshot.resolved.dimensions,
            proxyResolvedDimensions: Self.pixelDimensions(of: data),
            savedDimensions: nil,
            downgradeReason: snapshot.resolved.downgradeReason
        )
        DispatchQueue.main.async { self.lastCaptureResolution = record }
        saveDeferredProxy(data, record: record, showsThumbnail: true)
    }

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
        let outputData =
            filterRenderer.renderedData(
                from: data,
                recipe: pendingFilter,
                intensity: pendingFilterIntensity,
                aspectRatio: pendingRatio == .fourThree ? nil : pendingRatio.value
            ) ?? data
        if pendingSaveOriginal, pendingFilter != nil {
            save(data, countsFilter: false, showsThumbnail: false)
        }
        // Built from the exact snapshot capture() used to configure the
        // output — never re-derived — plus the one thing that can only be
        // known now: what ImageIO reports the saved bytes actually contain.
        let record = CaptureResolutionRecord(
            requested: pendingCaptureSnapshot.resolved.requested,
            resolvedDimensions: pendingCaptureSnapshot.resolved.dimensions,
            savedDimensions: Self.pixelDimensions(of: outputData),
            downgradeReason: pendingCaptureSnapshot.resolved.downgradeReason
        )
        DispatchQueue.main.async { self.lastCaptureResolution = record }
        save(outputData, countsFilter: pendingFilter != nil, showsThumbnail: true)
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
        let areaRatio =
            subject.width * subject.height
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
            targetRect: plan.target.cgRect,
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
        let analysisInterval = ProcessInfo.processInfo.thermalState == .nominal ? 0.1 : 0.25
        if !analysisInFlight,
            CMTimeGetSeconds(timestamp - lastAnalysisTime) >= analysisInterval
        {
            analysisInFlight = true
            lastAnalysisTime = timestamp
            let generation = analysisGeneration
            let preferredPoint = selectedSubjectPoint
            #if DEBUG
                lifecycleLog.debug("analysis started (generation=\(generation, privacy: .public))")
            #endif
            analyzer.analyze(
                buffer,
                preferredSubjectPoint: preferredPoint,
                generation: generation
            ) { [weak self] measurement, descriptor in
                guard let self else { return }
                self.queue.async {
                    guard self.acceptAnalysisCompletion(requestGeneration: generation) else {
                        #if DEBUG
                            let current = self.analysisGeneration
                            self.lifecycleLog.debug(
                                "analysis dropped, gen \(generation, privacy: .public) != \(current, privacy: .public)"
                            )
                        #endif
                        return
                    }
                    guard var measurement else {
                        #if DEBUG
                            self.lifecycleLog.debug("analysis completed: no measurement")
                        #endif
                        return
                    }
                    if let currentPoint = self.selectedSubjectPoint {
                        if currentPoint != preferredPoint,
                            let selected = measurement.subject(near: currentPoint)
                        {
                            measurement.subjectRect = selected
                            self.analyzer.track(selected)
                        }
                        if let selected = measurement.subjectRect {
                            self.selectedSubjectPoint = CGPoint(
                                x: selected.midX,
                                y: selected.midY
                            )
                        }
                    }
                    let stable = self.stabilizer.update(measurement)
                    let stableDescriptor = descriptor.map { self.descriptorStabilizer.update($0) }
                    let guidance =
                        self.cloudPlan.map {
                            Self.cloudGuidance($0, measurement: stable)
                        } ?? self.guidanceEngine.update(stable)
                    #if DEBUG
                        let directionName = String(describing: guidance.direction)
                        self.lifecycleLog.debug(
                            "analysis ok, gen \(generation, privacy: .public) dir \(directionName, privacy: .public)"
                        )
                    #endif
                    DispatchQueue.main.async {
                        self.measurement = stable
                        self.sceneDescriptor = stableDescriptor
                        self.guidance = guidance
                    }
                }
            }
        }

        // Ahead of the preview guard below, because the strip needs thumbnails
        // whether or not a filter is currently applied.
        if !thumbnailRequests.isEmpty,
            CMTimeGetSeconds(timestamp - lastThumbnailTime) >= 2
        {
            lastThumbnailTime = timestamp
            let images = filterRenderer.thumbnails(image, requests: thumbnailRequests)
            DispatchQueue.main.async { self.filterThumbnails = images }
        }

        guard let recipe = previewRecipe else { return }
        guard CMTimeGetSeconds(timestamp - lastPreviewTime) >= 1.0 / 15.0 else { return }
        lastPreviewTime = timestamp

        guard
            let rendered = filterRenderer.previewImage(
                image,
                recipe: recipe,
                intensity: previewIntensity
            )
        else { return }
        DispatchQueue.main.async { self.filteredPreview = rendered }
    }
}
