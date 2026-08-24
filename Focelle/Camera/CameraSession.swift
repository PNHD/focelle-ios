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

// The requested tier. `.maximum` means "the highest this active camera and
// format can deliver" — never a promise of a specific pixel count, since
// that varies by device and format. See ResolvedResolution for the
// truthful, dimension-based value this resolves to.
enum CameraResolution: String, CaseIterable, Sendable {
    case standard
    case maximum
}

struct PhotoDimensions: Equatable, Sendable {
    let width: Int32
    let height: Int32

    var pixels: Int64 { Int64(width) * Int64(height) }

    static func standard(in options: [PhotoDimensions]) -> PhotoDimensions? {
        options.min { abs($0.pixels - 24_000_000) < abs($1.pixels - 24_000_000) }
    }
}

// Why a requested resolution did not resolve to a distinctly higher tier.
enum ResolutionDowngradeReason: String, Equatable, Sendable {
    case none
    // The active device/format offers nothing distinctly larger than standard.
    case unsupportedByActiveFormat
    // AVCapturePhotoOutput's own ceiling capped the request further.
    case outputLimited
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
    // the standard tier; maximum maps to the distinct larger tier when one
    // exists, else falls back to standard rather than silently claiming a
    // capability that isn't there. The output's own ceiling is applied last.
    static func resolve(
        requested: CameraResolution,
        standard: PhotoDimensions?,
        maximum: PhotoDimensions?,
        outputLimit: PhotoDimensions?
    ) -> ResolvedResolution {
        guard let standard else {
            return ResolvedResolution(requested: requested, dimensions: nil, downgradeReason: .none)
        }
        let distinctMaximum = hasDistinctMaximum(standard: standard, maximum: maximum)
        var ideal = requested == .maximum ? (maximum ?? standard) : standard
        var reason = ResolutionDowngradeReason.none
        if requested == .maximum, !distinctMaximum {
            reason = .unsupportedByActiveFormat
        }
        if let outputLimit, outputLimit.pixels > 0, ideal.pixels > outputLimit.pixels {
            ideal = outputLimit
            reason = .outputLimited
        }
        return ResolvedResolution(requested: requested, dimensions: ideal, downgradeReason: reason)
    }
}

// Privacy-safe record of what actually happened at capture: the requested
// tier, what was resolved ahead of the shot, and what the saved photo turned
// out to contain. Dimensions and enum labels only — never image bytes,
// scene content, or identifiers.
struct CaptureResolutionRecord: Equatable, Sendable {
    let requested: CameraResolution
    let resolvedDimensions: PhotoDimensions?
    let savedDimensions: PhotoDimensions?
    let downgradeReason: ResolutionDowngradeReason

    var isDowngraded: Bool { downgradeReason != .none }
    var requestedLabel: String { requested.rawValue }
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

enum CaptureCallbackType: String, Equatable, Sendable {
    case immediatePhoto
    case deferredProxy
}

enum CaptureLifecycleStage: String, Equatable, Sendable {
    case awaitingDelivery
    case processing
    case saving
    case terminal
}

enum CaptureClaimFailure: String, Equatable, Sendable {
    case unknownCapture
    case alreadyClaimed
    case alreadyTerminal
}

struct CaptureDiagnostic: Error, Equatable, Sendable {
    let captureID: Int64
    let callbackType: CaptureCallbackType
    let currentStage: CaptureLifecycleStage?
    let reason: CaptureClaimFailure
}

struct CaptureClaim<Context> {
    let captureID: Int64
    let callbackType: CaptureCallbackType
    let context: Context
}

struct CaptureTimeout<Context> {
    let captureID: Int64
    let stage: CaptureLifecycleStage
    let context: Context
}

// UI notices are short-lived, but their delayed clear must be scoped to the
// exact publication that created it. This is deliberately presentation
// ownership only; capture lifecycle ownership remains in CaptureCoordinator.
struct CameraNoticeToken: Equatable, Sendable {
    let value: UInt64
}

// This small lock-backed state machine is the capture ownership boundary. Its
// context is opaque so the protocol can be exercised with synthetic values in
// tests while CameraSession keeps the immutable AVFoundation snapshot locally.
final class CaptureCoordinator<Context>: @unchecked Sendable {
    private struct Entry {
        let context: Context
        var stage: CaptureLifecycleStage
    }

    private let lock = NSLock()
    private var entries: [Int64: Entry] = [:]
    private var terminalIDs: [Int64] = []
    private var terminalEffectIDs: [Int64] = []
    private let terminalHistoryLimit = 64

    func register(captureID: Int64, context: Context) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard entries[captureID] == nil, !terminalIDs.contains(captureID) else { return false }
        entries[captureID] = Entry(context: context, stage: .awaitingDelivery)
        return true
    }

    func claim(
        captureID: Int64,
        callbackType: CaptureCallbackType
    ) -> Result<CaptureClaim<Context>, CaptureDiagnostic> {
        lock.lock()
        defer { lock.unlock() }
        guard var entry = entries[captureID] else {
            return .failure(
                CaptureDiagnostic(
                    captureID: captureID,
                    callbackType: callbackType,
                    currentStage: terminalIDs.contains(captureID) ? .terminal : nil,
                    reason: terminalIDs.contains(captureID) ? .alreadyTerminal : .unknownCapture
                )
            )
        }
        guard entry.stage == .awaitingDelivery else {
            return .failure(
                CaptureDiagnostic(
                    captureID: captureID,
                    callbackType: callbackType,
                    currentStage: entry.stage,
                    reason: .alreadyClaimed
                )
            )
        }
        entry.stage = .processing
        entries[captureID] = entry
        return .success(CaptureClaim(captureID: captureID, callbackType: callbackType, context: entry.context))
    }

    func beginSaving(captureID: Int64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard var entry = entries[captureID], entry.stage == .processing else { return false }
        entry.stage = .saving
        entries[captureID] = entry
        return true
    }

    func complete(captureID: Int64, expectedStage: CaptureLifecycleStage) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[captureID], entry.stage == expectedStage else { return false }
        entries[captureID] = nil
        rememberTerminal(captureID)
        return true
    }

    func timeout(captureID: Int64) -> CaptureTimeout<Context>? {
        lock.lock()
        defer { lock.unlock() }
        // Photos authorization and writes own completion once saving begins.
        // A dequeued delivery timeout or late AVFoundation error must not
        // revoke that owner after the original timer has been retired.
        guard let entry = entries[captureID], entry.stage != .saving else { return nil }
        entries[captureID] = nil
        rememberTerminal(captureID)
        return CaptureTimeout(captureID: captureID, stage: entry.stage, context: entry.context)
    }

    func cancelBeforeSaving() -> [CaptureTimeout<Context>] {
        lock.lock()
        defer { lock.unlock() }
        return cancelEntries { $0 != .saving }
    }

    private func cancelEntries(
        matching shouldCancel: (CaptureLifecycleStage) -> Bool
    ) -> [CaptureTimeout<Context>] {
        let captureIDs = entries.compactMap { shouldCancel($0.value.stage) ? $0.key : nil }
        let cancelled = captureIDs.compactMap { captureID -> CaptureTimeout<Context>? in
            guard let entry = entries.removeValue(forKey: captureID) else { return nil }
            rememberTerminal(captureID)
            return CaptureTimeout(captureID: captureID, stage: entry.stage, context: entry.context)
        }
        return cancelled
    }

    var pendingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    var hasSavingCapture: Bool {
        lock.lock()
        defer { lock.unlock() }
        return entries.values.contains { $0.stage == .saving }
    }

    // Ownership transitions and UI/reducer terminal effects are related but
    // distinct: a transition to terminal can happen before a late delegate
    // continuation returns. Keep this idempotence claim in the same locked
    // coordinator rather than creating a second capture state machine.
    func claimTerminalEffect(captureID: Int64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !terminalEffectIDs.contains(captureID) else { return false }
        terminalEffectIDs.append(captureID)
        if terminalEffectIDs.count > terminalHistoryLimit {
            terminalEffectIDs.removeFirst(terminalEffectIDs.count - terminalHistoryLimit)
        }
        return true
    }

    var terminalEffectCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return terminalEffectIDs.count
    }

    private func rememberTerminal(_ captureID: Int64) {
        terminalIDs.removeAll { $0 == captureID }
        terminalIDs.append(captureID)
        if terminalIDs.count > terminalHistoryLimit {
            terminalIDs.removeFirst(terminalIDs.count - terminalHistoryLimit)
        }
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

    private struct PendingCapture {
        let snapshot: CaptureResolutionSnapshot
        let ratio: CameraRatio
        let filter: FilterRecipe?
        let filterIntensity: Double
        let saveOriginal: Bool
        let location: CLLocation?
    }

    private struct SaveRequest {
        let primaryData: Data
        let originalData: Data?
        let location: CLLocation?
        let record: CaptureResolutionRecord
        let countsFilter: Bool
        let filterFallback: Bool
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
    @Published private(set) var resolution: CameraResolution = .standard {
        didSet {
            guard resolution != oldValue else { return }
            recomputeResolvedResolution()
        }
    }
    @Published private(set) var resolvedResolution = ResolvedResolution(
        requested: .standard,
        dimensions: nil,
        downgradeReason: .none
    )
    @Published private(set) var standardModeLabel = "—"
    @Published private(set) var maximumModeLabel = "—"
    @Published private(set) var lastCaptureResolution: CaptureResolutionRecord?
    @Published var showsGrid = true
    @Published var savesOriginal = false
    var photoLocation: CLLocation?
    @Published private(set) var activeFilter: FilterRecipe?
    @Published private(set) var filterIntensity = 1.0
    @Published private(set) var filteredPreview: CGImage?
    @Published private(set) var filterThumbnails: [String: CGImage] = [:]
    @Published private(set) var measurement: SceneMeasurement?
    @Published private(set) var guidance: Guidance?
    @Published private(set) var guidanceSessionState: GuidanceSessionState = .ready
    @Published private(set) var captureIntent: CaptureIntent = .auto
    @Published private(set) var filterSaveSequence = 0
    @Published private(set) var latestThumbnail: CGImage?
    @Published private(set) var notice: String?
    @Published private(set) var isRecoverableFailureNotice = false

    let session = AVCaptureSession()

    private let queue = DispatchQueue(label: "com.pnhd.focelle.camera")
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let filterRenderer = FilterRenderer()
    private let analyzer = OnDeviceAnalyzer()
    private var input: AVCaptureDeviceInput?
    private let captureCoordinator = CaptureCoordinator<PendingCapture>()
    private var captureTimeouts: [Int64: DispatchWorkItem] = [:]
    // Main-queue-owned notice presentation identity. A delayed clear receives
    // its token by value and cannot clear a newer capture or recovery notice.
    private var nextNoticeVersion: UInt64 = 0
    private var activeNoticeToken: CameraNoticeToken?
    private var recoverableFailureNoticeToken: CameraNoticeToken?
    #if DEBUG
        private var noticePublicationCount = 0
    #endif
    private var configured = false
    private var rotationAngle: CGFloat = 90
    // Queue-owned canonical capability state — currentCaptureSnapshot(for:)
    // reads these directly so a capture is never configured from stale or
    // independently-drifted dimensions. Not `private`: regression tests
    // simulate a capability change without a real device.
    var standardDimensions: PhotoDimensions?
    var maximumDimensions: PhotoDimensions?
    var outputLimitDimensions: PhotoDimensions?
    // Bumped every time configureCapabilities(for:) runs (initial configure,
    // camera switch); ties a snapshot to the exact capability set it came from.
    var capabilityGeneration = 0
    // Main-thread mirrors of the three dimensions above, so resolution's
    // didSet can recompute the UI-facing resolvedResolution without reaching
    // across queue-owned state. Never used to configure an actual capture.
    // Not `private`: regression tests simulate a capability change.
    var cachedStandardDimensions: PhotoDimensions?
    var cachedMaximumDimensions: PhotoDimensions?
    var cachedOutputLimit: PhotoDimensions?
    private var previewRecipe: FilterRecipe?
    private var previewIntensity = 1.0
    private var lastPreviewTime = CMTime.zero
    private var thumbnailRequests: [FilterThumbnailRequest] = []
    private var lastThumbnailTime = CMTime.zero
    private var lastAnalysisTime = CMTime.zero
    private var stabilizer = MeasurementStabilizer()
    private var guidanceEngine = GuidanceEngine()
    private var pendingAIPreview: (@Sendable (Data?) -> Void)?
    private var cloudPlan: SemanticGuidanceTarget?
    // Queue-owned acceptance tombstone. A recovery can reject an old cloud
    // response even if its UI cancellation callback arrives later.
    private var acceptsCloudPlan = false
    private var selectedSubjectPoint: CGPoint?
    private var selectedSubjectID: SubjectTrackID?
    private var selectedSubjectContinuity: SubjectContinuityID?
    // Not `private`: regression tests confirm a resume can't leave this wedged.
    var analysisInFlight = false
    var analysisGeneration = 0

    #if DEBUG
        private let lifecycleLog = Logger(subsystem: "com.pnhd.focelle", category: "camera.lifecycle")
    #endif

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
            guard let self else { return }
            self.cancelPendingCaptures(cause: "camera session stopped")
            guard self.session.isRunning else { return }
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
            self.cancelPendingCaptures(cause: "camera switch")
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
        resolvedResolution = ResolvedResolution.resolve(
            requested: resolution,
            standard: cachedStandardDimensions,
            maximum: cachedMaximumDimensions,
            outputLimit: cachedOutputLimit
        )
        standardModeLabel =
            ResolvedResolution.resolve(
                requested: .standard,
                standard: cachedStandardDimensions,
                maximum: cachedMaximumDimensions,
                outputLimit: cachedOutputLimit
            ).label
        maximumModeLabel =
            ResolvedResolution.resolve(
                requested: .maximum,
                standard: cachedStandardDimensions,
                maximum: cachedMaximumDimensions,
                outputLimit: cachedOutputLimit
            ).label
    }

    // Runs on `queue`. The one place a resolved snapshot is built for an
    // actual capture, from the queue-owned capability state current at this
    // exact moment — never the main-thread cache used for UI, and never
    // reconstructed a second time for the saved record (see capture()).
    // Not `private` so regression tests can drive it directly.
    func currentCaptureSnapshot(for requested: CameraResolution) -> CaptureResolutionSnapshot {
        let resolved = ResolvedResolution.resolve(
            requested: requested,
            standard: standardDimensions,
            maximum: maximumDimensions,
            outputLimit: outputLimitDimensions
        )
        return CaptureResolutionSnapshot(resolved: resolved, capabilityGeneration: capabilityGeneration)
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
        let selectedSaveOriginal = savesOriginal
        let selectedLocation = photoLocation
        isCapturing = true

        queue.async { [weak self] in
            guard let self else { return }
            self.beginGuidanceCapture()
            let settings = AVCapturePhotoSettings()
            guard self.session.isRunning else {
                self.publish(notice: "camera.error.capture", recoverableFailure: true)
                self.finishCapture(captureID: settings.uniqueID, recoverableFailure: true)
                return
            }
            // Taken on `queue` right now, from queue-owned capability state —
            // not a main-thread cache — so this exact snapshot is what both
            // configures the output below and becomes the saved record; a
            // concurrent camera switch can't leave the two disagreeing.
            let snapshot = self.currentCaptureSnapshot(for: selectedResolution)
            // capturePhoto raises NSInvalidArgumentException for any setting the output
            // does not allow, and an ObjC exception cannot be caught in Swift, so every
            // value below is taken from what the output itself reports.
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
            let context = PendingCapture(
                snapshot: snapshot,
                ratio: selectedRatio,
                filter: selectedFilter,
                filterIntensity: selectedFilterIntensity,
                saveOriginal: selectedSaveOriginal,
                location: selectedLocation
            )
            guard self.registerPendingCapture(id: settings.uniqueID, context: context) else {
                self.publish(notice: Self.cancellationNotice, recoverableFailure: true)
                self.finishCapture(captureID: settings.uniqueID, recoverableFailure: true)
                return
            }
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    func showNotice(_ notice: String) {
        publish(notice: notice)
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

    // User-initiated analysis is also the explicit recovery path from a
    // recoverable guidance/capture failure.
    func beginGuidanceAnalysis() {
        queue.async { [weak self] in
            guard let self else { return }
            self.acceptsCloudPlan = true
            self.beginGuidanceAnalysisOnQueue(recoveringFailure: true)
        }
    }

    // This explicit path is the user-visible recovery action for a failed
    // capture/guidance cycle. It clears the reducer failure before starting a
    // fresh local analysis pass.
    func recoverGuidance() {
        queue.async { [weak self] in
            guard let self, self.guidanceEngine.state == .failedRecoverable else { return }
            self.retireRecoverableFailureNotice()
            // Recovery begins a new local cycle. Retire the queue-owned cloud
            // target before its ANALYZING transition can accept another frame.
            self.cloudPlan = nil
            self.acceptsCloudPlan = false
            self.analysisInFlight = false
            self.analysisGeneration += 1
            self.guidanceEngine.recover()
            self.beginGuidanceAnalysisOnQueue()
            DispatchQueue.main.async {
                self.measurement = nil
                self.guidance = nil
            }
        }
    }

    func setCaptureIntent(_ intent: CaptureIntent) {
        guard captureIntent != intent else { return }
        captureIntent = intent
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
        guidanceEngine.reset()
        cloudPlan = nil
        acceptsCloudPlan = false
        selectedSubjectID = nil
        selectedSubjectContinuity = nil
        selectedSubjectPoint = nil
        #if DEBUG
            lifecycleLog.debug("analyzer reset for resume (generation=\(self.analysisGeneration, privacy: .public))")
        #endif
        let guidanceState = guidanceEngine.state
        DispatchQueue.main.async {
            self.measurement = nil
            self.guidance = nil
            self.guidanceSessionState = guidanceState
        }
    }

    #if DEBUG
        // Lets regression tests dirty published state before asserting that a
        // resume clears it; production code never needs to set these directly.
        func debugSeedGuidanceForTesting(measurement: SceneMeasurement?, guidance: Guidance?) {
            self.measurement = measurement
            self.guidance = guidance
        }

        func debugRegisterPendingCaptureForTesting(id: Int64) {
            let context = PendingCapture(
                snapshot: CaptureResolutionSnapshot(
                    resolved: ResolvedResolution(requested: .standard, dimensions: nil, downgradeReason: .none),
                    capabilityGeneration: 0
                ),
                ratio: .fourThree,
                filter: nil,
                filterIntensity: 1,
                saveOriginal: false,
                location: nil
            )
            _ = captureCoordinator.register(captureID: id, context: context)
        }

        func debugClaimPendingCaptureForTesting(id: Int64) {
            _ = captureCoordinator.claim(captureID: id, callbackType: .immediatePhoto)
        }

        func debugBeginSavingForTesting(id: Int64) {
            _ = captureCoordinator.beginSaving(captureID: id)
        }

        func debugAttemptBeginSavingForTesting(id: Int64) -> Bool {
            captureCoordinator.beginSaving(captureID: id)
        }

        func debugAnalyzeGuidanceForTesting(_ measurement: SceneMeasurement) {
            queue.async { [weak self] in
                guard let self else { return }
                self.beginGuidanceAnalysisOnQueue()
                let stable = self.stabilizer.update(measurement, generation: self.analysisGeneration)
                self.updateGuidance(with: stable, generation: self.analysisGeneration)
            }
        }

        func debugBeginGuidanceCaptureForTesting() {
            isCapturing = true
            queue.async { [weak self] in self?.beginGuidanceCapture() }
        }

        func debugCompletePhotoKitSaveForTesting(id: Int64, saved: Bool) {
            guard captureCoordinator.complete(captureID: id, expectedStage: .saving) else { return }
            finishCapture(captureID: id, recoverableFailure: !saved)
        }

        func debugPublishNoticeForTesting(_ notice: String, recoverableFailure: Bool = false) {
            publish(notice: notice, recoverableFailure: recoverableFailure)
        }

        func debugSeedCloudPlanForTesting(_ plan: SemanticGuidanceTarget) {
            queue.async { [weak self] in self?.cloudPlan = plan }
        }

        var debugCloudPlanForTesting: SemanticGuidanceTarget? { cloudPlan }

        func debugHandleCaptureCallbackForTesting(id: Int64) -> Bool {
            claimCapture(id: id, callbackType: .immediatePhoto) != nil
        }

        var debugActiveNoticeTokenForTesting: CameraNoticeToken? { activeNoticeToken }

        func debugClearNoticeForTesting(_ token: CameraNoticeToken?) {
            guard let token else { return }
            DispatchQueue.main.async { [weak self] in self?.clearNotice(token: token) }
        }

        func debugHandleMissingDeferredProxyForTesting() {
            handleMissingDeferredPhotoProxy()
        }

        func debugClaimTerminalEffectForTesting(id: Int64) -> Bool {
            captureCoordinator.claimTerminalEffect(captureID: id)
        }

        func debugFinishCaptureForTesting(id: Int64, recoverableFailure: Bool) {
            finishCapture(captureID: id, recoverableFailure: recoverableFailure)
        }

        var debugPendingCaptureCount: Int { captureCoordinator.pendingCount }
        var debugCaptureTerminalEffectCount: Int { captureCoordinator.terminalEffectCount }
        var debugNoticePublicationCount: Int { noticePublicationCount }
        private(set) var debugSemanticTargetUsedForLatestGuidanceUpdate: SemanticGuidanceTarget?
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
        handleSessionInterruption()
    }

    // The notification adapter delegates to the same stage-aware coordinator
    // boundary used by all other lifecycle cancellation paths.
    func handleSessionInterruption() {
        cancelPendingCaptures(cause: "AVFoundation session interrupted")
        publish(state: .interrupted)
    }

    @objc private func sessionInterruptionEnded(_ notification: Notification) {
        configureAndStart()
    }

    @objc private func sessionRuntimeError(_ notification: Notification) {
        let error = notification.userInfo?[AVCaptureSessionErrorKey] as? AVError
        let cancellationCause =
            Self.canRestart(after: error)
            ? "media services reset"
            : "fatal session runtime error"
        cancelPendingCaptures(cause: cancellationCause)
        if Self.canRestart(after: error) {
            configureAndStart()
        } else {
            publish(state: .unavailable)
        }
    }

    static func canRestart(after error: AVError?) -> Bool {
        error?.code == .mediaServicesWereReset
    }

    // Manual capture depends solely on live camera/capture state. Quota and
    // filter-credit accounting run after a save attempt and cannot veto the
    // user's shutter request.
    static func manualCaptureAllowed(
        state: State,
        isCapturing: Bool,
        countdownActive: Bool,
        filterQuotaExhausted: Bool
    ) -> Bool {
        // Deliberately read and discard this accounting signal: no entitlement
        // or exhausted filter credit is allowed to become a shutter lock.
        _ = filterQuotaExhausted
        state == .running && !isCapturing && !countdownActive
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
        queue.async { [weak self] in
            guard let self, self.acceptsCloudPlan, let measurement = self.measurement else { return }
            let semanticTarget = Self.semanticTarget(
                for: plan,
                measurement: measurement,
                intent: self.captureIntent,
                selectedSubjectID: self.selectedSubjectID,
                generation: self.analysisGeneration
            )
            self.cloudPlan = semanticTarget
            self.setZoom(CGFloat(plan.zoom))
            self.setExposure(Float(plan.exposureBias))
            self.updateGuidance(with: measurement, generation: self.analysisGeneration)
        }
    }

    func clearAIPlan() {
        queue.async {
            self.cloudPlan = nil
            self.acceptsCloudPlan = false
            guard let measurement = self.measurement else { return }
            self.updateGuidance(with: measurement, generation: self.analysisGeneration)
        }
    }

    func selectSubject(at point: CGPoint) {
        queue.async { [weak self] in
            guard let self else { return }
            let visionPoint = CGPoint(x: point.x, y: 1 - point.y)
            self.selectedSubjectPoint = visionPoint
            guard var measurement = self.measurement,
                let selected = measurement.person(near: visionPoint)
            else { return }
            self.selectedSubjectID = selected.id
            self.selectedSubjectContinuity = selected.continuityID
            self.cloudPlan = nil
            measurement.selectedSubjectID = selected.id
            measurement.subjectRect = selected.humanRect
            self.selectedSubjectPoint = CGPoint(x: selected.humanRect.midX, y: selected.humanRect.midY)
            self.analyzer.track(selected.humanRect)
            let guidance = self.guidanceEngine.update(
                measurement,
                intent: self.captureIntent,
                generation: self.analysisGeneration,
                selectedSubjectID: selected.id,
                semanticTarget: self.cloudPlan
            )
            let guidanceState = self.guidanceEngine.state
            DispatchQueue.main.async {
                self.measurement = measurement
                self.guidance = guidance
                self.guidanceSessionState = guidanceState
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
        let standardPhoto = PhotoDimensions.standard(in: mapped)
        let maximumPhoto = mapped.last
        if let maximumCMDimensions = sorted.last {
            photoOutput.maxPhotoDimensions = maximumCMDimensions
        }
        // Raise the ceiling here rather than per capture: the output defaults to
        // .balanced and rejects a higher value on the settings object.
        photoOutput.maxPhotoQualityPrioritization = .quality
        let outputLimitPhoto = PhotoDimensions(
            width: photoOutput.maxPhotoDimensions.width,
            height: photoOutput.maxPhotoDimensions.height
        )

        // The queue-owned truth a capture snapshot is built from. Bumping the
        // generation here — rather than only replacing the values — is what
        // lets a snapshot be tied to (and a stale one told apart from) the
        // exact capability set it was resolved against.
        standardDimensions = standardPhoto
        maximumDimensions = maximumPhoto
        outputLimitDimensions = outputLimitPhoto
        capabilityGeneration += 1

        let deviceMaxZoom = min(device.activeFormat.videoMaxZoomFactor, 10)
        // Whether the device/format genuinely has more to offer than standard —
        // not an arbitrary pixel-count threshold, so a modest-but-real jump
        // (or a hardware ceiling below any "48 MP" claim) is represented truthfully.
        let supportsMaximum = ResolvedResolution.hasDistinctMaximum(standard: standardPhoto, maximum: maximumPhoto)
        DispatchQueue.main.async {
            self.maxZoom = max(deviceMaxZoom, 1)
            self.zoom = 1
            self.exposure = 0
            self.supportsMaximumResolution = supportsMaximum
            // The requested tier is the user's intent (AppSettings.requestedResolution)
            // and survives a temporarily-incapable camera unchanged; only the
            // resolved dimensions/downgrade reason reflect this camera's limits.
            self.cachedStandardDimensions = standardPhoto
            self.cachedMaximumDimensions = maximumPhoto
            self.cachedOutputLimit = outputLimitPhoto
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

    private func registerPendingCapture(id: Int64, context: PendingCapture) -> Bool {
        guard captureCoordinator.register(captureID: id, context: context) else { return false }
        let timeout = DispatchWorkItem { [weak self] in
            self?.handleCaptureTimeout(id: id)
        }
        captureTimeouts[id]?.cancel()
        captureTimeouts[id] = timeout
        queue.asyncAfter(deadline: .now() + 15, execute: timeout)
        return true
    }

    private func claimCapture(
        id: Int64,
        callbackType: CaptureCallbackType
    ) -> CaptureClaim<PendingCapture>? {
        switch captureCoordinator.claim(captureID: id, callbackType: callbackType) {
        case .success(let claim):
            return claim
        case .failure(let diagnostic):
            recordCaptureDiagnostic(diagnostic)
            return nil
        }
    }

    private func cancelCapture(id: Int64, notice: String) {
        guard captureCoordinator.timeout(captureID: id) != nil else { return }
        retireCaptureTimeout(id: id)
        publish(notice: notice, recoverableFailure: true)
        finishCapture(captureID: id, recoverableFailure: true)
    }

    private func cancelPendingCaptures(
        cause: String,
        notice: String? = Self.cancellationNotice
    ) {
        let cancelled = captureCoordinator.cancelBeforeSaving()
        guard !cancelled.isEmpty else { return }
        for cancelledCapture in cancelled {
            #if DEBUG
                lifecycleLog.debug(
                    "capture cancelled id=\(cancelledCapture.captureID, privacy: .public) stage=\(cancelledCapture.stage.rawValue, privacy: .public) cause=\(cause, privacy: .public)"
                )
            #endif
            retireCaptureTimeout(id: cancelledCapture.captureID)
        }
        if let notice { publish(notice: notice, recoverableFailure: true) }
        // A separate PhotoKit-owned save remains the active capture lifecycle
        // even if an earlier delivery/processing entry was interrupted.
        if !captureCoordinator.hasSavingCapture {
            for cancelledCapture in cancelled {
                finishCapture(captureID: cancelledCapture.captureID, recoverableFailure: true)
            }
        }
    }

    private func handleCaptureTimeout(id: Int64) {
        guard let timeout = captureCoordinator.timeout(captureID: id) else { return }
        captureTimeouts[id] = nil
        publish(notice: Self.timeoutNotice(for: timeout.stage), recoverableFailure: true)
        finishCapture(captureID: id, recoverableFailure: true)
    }

    private func retireCaptureTimeout(id: Int64) {
        queue.async { [weak self] in
            self?.captureTimeouts.removeValue(forKey: id)?.cancel()
        }
    }

    private func recordCaptureDiagnostic(_ diagnostic: CaptureDiagnostic) {
        #if DEBUG
            lifecycleLog.debug(
                "capture callback rejected id=\(diagnostic.captureID, privacy: .public) callback=\(diagnostic.callbackType.rawValue, privacy: .public) state=\(diagnostic.currentStage?.rawValue ?? "unknown", privacy: .public) reason=\(diagnostic.reason.rawValue, privacy: .public)"
            )
        #endif
    }

    static func timeoutNotice(for stage: CaptureLifecycleStage) -> String {
        switch stage {
        case .awaitingDelivery: "camera.error.captureTimeoutDelivery"
        case .processing: "camera.error.captureTimeoutProcessing"
        case .saving: "camera.error.captureTimeoutSaving"
        case .terminal: "camera.error.captureTimeoutDelivery"
        }
    }

    static let cancellationNotice = "camera.error.captureCancelled"
    static let filterFallbackNotice = "camera.warning.filterFallbackSaved"

    static func canSaveUnfilteredFallback(hasFilter: Bool, requiresAspectProcessing: Bool) -> Bool {
        hasFilter && !requiresAspectProcessing
    }

    static func photoAuthorizationNotice(for status: PHAuthorizationStatus) -> String? {
        switch status {
        case .authorized, .limited: nil
        case .denied: "camera.error.photosPermissionDenied"
        case .restricted: "camera.error.photosRestricted"
        case .notDetermined: "camera.error.photosPermissionDenied"
        @unknown default: "camera.error.photosPermissionDenied"
        }
    }

    static func photoWriteNotice(for success: Bool) -> String? {
        success ? nil : "camera.error.photosWrite"
    }

    private func save(captureID: Int64, request: SaveRequest) {
        guard captureCoordinator.beginSaving(captureID: captureID) else {
            // An interruption can terminalize a processing capture while its
            // delegate is still rendering. That continuation is stale, not a
            // new terminal event, so it must not touch UI or guidance state.
            return
        }
        retireCaptureTimeout(id: captureID)

        let primaryData = request.primaryData
        let originalData = request.originalData
        let location = request.location
        let record = request.record
        let countsFilter = request.countsFilter
        let filterFallback = request.filterFallback
        let performSave: @Sendable () -> Void = { [weak self] in
            PHPhotoLibrary.shared().performChanges {
                if let originalData {
                    let original = PHAssetCreationRequest.forAsset()
                    original.location = location
                    original.addResource(with: .photo, data: originalData, options: nil)
                }
                let creation = PHAssetCreationRequest.forAsset()
                creation.location = location
                creation.addResource(with: .photo, data: primaryData, options: nil)
            } completionHandler: { [weak self] saved, error in
                guard let self, self.captureCoordinator.complete(captureID: captureID, expectedStage: .saving) else {
                    return
                }
                self.retireCaptureTimeout(id: captureID)
                if saved {
                    self.publish(notice: filterFallback ? Self.filterFallbackNotice : "camera.saved")
                    if let thumbnail = UIImage(data: primaryData)?.cgImage {
                        DispatchQueue.main.async {
                            self.latestThumbnail = thumbnail
                            self.lastCaptureResolution = record
                        }
                    } else {
                        DispatchQueue.main.async { self.lastCaptureResolution = record }
                    }
                    if countsFilter {
                        DispatchQueue.main.async { self.filterSaveSequence += 1 }
                    }
                } else {
                    if let error = error as NSError? {
                        #if DEBUG
                            self.lifecycleLog.error(
                                "Photos save failed domain=\(error.domain, privacy: .public) code=\(error.code, privacy: .public) message=\(error.localizedDescription, privacy: .public)"
                            )
                        #endif
                    }
                    if let notice = Self.photoWriteNotice(for: saved) {
                        self.publish(notice: notice, recoverableFailure: true)
                    }
                }
                self.finishCapture(captureID: captureID, recoverableFailure: !saved)
            }
        }

        switch PHPhotoLibrary.authorizationStatus(for: .addOnly) {
        case .authorized, .limited:
            performSave()
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] status in
                guard let self else { return }
                if let notice = Self.photoAuthorizationNotice(for: status) {
                    guard self.captureCoordinator.complete(captureID: captureID, expectedStage: .saving) else { return }
                    self.retireCaptureTimeout(id: captureID)
                    self.publish(notice: notice, recoverableFailure: true)
                    self.finishCapture(captureID: captureID, recoverableFailure: true)
                } else {
                    performSave()
                }
            }
        default:
            let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
            guard let notice = Self.photoAuthorizationNotice(for: status),
                captureCoordinator.complete(captureID: captureID, expectedStage: .saving)
            else { return }
            retireCaptureTimeout(id: captureID)
            publish(notice: notice, recoverableFailure: true)
            finishCapture(captureID: captureID, recoverableFailure: true)
        }
    }

    private func finishCapture(captureID: Int64, recoverableFailure: Bool = false) {
        queue.async { [weak self] in
            guard let self else { return }
            guard self.captureCoordinator.claimTerminalEffect(captureID: captureID) else { return }
            self.guidanceEngine.completeCapture(recoverableFailure: recoverableFailure)
            let guidanceState = self.guidanceEngine.state
            DispatchQueue.main.async {
                self.guidanceSessionState = guidanceState
                self.isCapturing = false
            }
        }
    }

    private func beginGuidanceAnalysisOnQueue(recoveringFailure: Bool = false) {
        guidanceEngine.beginAnalysis(recoveringFailure: recoveringFailure)
        publishGuidanceState(guidanceEngine.state)
    }

    private func beginGuidanceCapture() {
        guidanceEngine.beginCapture()
        DispatchQueue.main.async { self.guidance = nil }
        publishGuidanceState(guidanceEngine.state)
    }

    private func publishGuidanceState(_ guidanceState: GuidanceSessionState) {
        DispatchQueue.main.async { self.guidanceSessionState = guidanceState }
    }

    // Runs on `queue` after every analyzer result. Explicit selection is bound
    // to continuity identity, not just the reusable geometric track slot.
    private func updateGuidance(with measurement: SceneMeasurement, generation: Int) {
        var stable = measurement
        if let selectedContinuity = selectedSubjectContinuity,
            let selected = stable.people.first(where: { $0.continuityID == selectedContinuity })
        {
            selectedSubjectID = selected.id
            stable.selectedSubjectID = selected.id
            stable.subjectRect = selected.humanRect
        } else if selectedSubjectID != nil || selectedSubjectContinuity != nil {
            // Once an explicitly selected person is observed missing, a nearby
            // person cannot reactivate that selection by geometry alone.
            selectedSubjectID = nil
            selectedSubjectContinuity = nil
            selectedSubjectPoint = nil
            cloudPlan = nil
            stable.selectedSubjectID = nil
            stable.subjectRect = nil
        } else {
            stable.selectedSubjectID = nil
        }

        #if DEBUG
            debugSemanticTargetUsedForLatestGuidanceUpdate = cloudPlan
        #endif
        let guidance = guidanceEngine.update(
            stable,
            intent: captureIntent,
            generation: generation,
            selectedSubjectID: selectedSubjectID,
            semanticTarget: cloudPlan
        )
        if guidanceEngine.isSemanticTargetInvalidated(cloudPlan) {
            cloudPlan = nil
        }
        #if DEBUG
            let directionName = String(describing: guidance?.direction ?? .none)
            lifecycleLog.debug(
                "analysis ok, gen \(generation, privacy: .public) dir \(directionName, privacy: .public)"
            )
        #endif
        let guidanceState = guidanceEngine.state
        DispatchQueue.main.async {
            self.measurement = stable
            self.guidance = guidance
            self.guidanceSessionState = guidanceState
        }
    }

    private func publish(state: State) {
        #if DEBUG
            lifecycleLog.debug("session state -> \(String(describing: state), privacy: .public)")
        #endif
        DispatchQueue.main.async { self.state = state }
    }

    private func publish(notice: String, recoverableFailure: Bool = false) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.nextNoticeVersion &+= 1
            let token = CameraNoticeToken(value: self.nextNoticeVersion)
            self.activeNoticeToken = token
            self.recoverableFailureNoticeToken = recoverableFailure ? token : nil
            self.isRecoverableFailureNotice = recoverableFailure
            self.notice = notice
            #if DEBUG
                self.noticePublicationCount += 1
            #endif
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self, token] in
                self?.clearNotice(token: token)
            }
        }
    }

    private func clearNotice(token: CameraNoticeToken) {
        guard activeNoticeToken == token else { return }
        notice = nil
        activeNoticeToken = nil
        isRecoverableFailureNotice = false
        if recoverableFailureNoticeToken == token {
            recoverableFailureNoticeToken = nil
        }
    }

    private func retireRecoverableFailureNotice() {
        DispatchQueue.main.async { [weak self] in
            guard let self,
                let token = self.recoverableFailureNoticeToken,
                self.activeNoticeToken == token
            else { return }
            self.clearNotice(token: token)
        }
    }

    private func handleMissingDeferredPhotoProxy() {
        cancelPendingCaptures(
            cause: "deferred proxy callback omitted its payload",
            notice: "camera.error.capture"
        )
    }
}

extension CameraSession: AVCapturePhotoCaptureDelegate {
    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishCapturingDeferredPhotoProxy proxy: AVCaptureDeferredPhotoProxy?,
        error: Error?
    ) {
        guard let proxy else {
            handleMissingDeferredPhotoProxy()
            return
        }
        let captureID = proxy.resolvedSettings.uniqueID
        guard error == nil, let data = proxy.fileDataRepresentation() else {
            cancelCapture(id: captureID, notice: "camera.error.capture")
            return
        }
        guard let claim = claimCapture(id: captureID, callbackType: .deferredProxy) else { return }

        let record = CaptureResolutionRecord(
            requested: claim.context.snapshot.resolved.requested,
            resolvedDimensions: claim.context.snapshot.resolved.dimensions,
            savedDimensions: nil,
            downgradeReason: claim.context.snapshot.resolved.downgradeReason
        )
        save(
            captureID: captureID,
            request: SaveRequest(
                primaryData: data,
                originalData: nil,
                location: claim.context.location,
                record: record,
                countsFilter: false,
                filterFallback: false
            )
        )
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        let captureID = photo.resolvedSettings.uniqueID
        guard error == nil, let data = photo.fileDataRepresentation() else {
            cancelCapture(id: captureID, notice: "camera.error.capture")
            return
        }
        guard let claim = claimCapture(id: captureID, callbackType: .immediatePhoto) else { return }
        let requiresAspectProcessing = claim.context.ratio != .fourThree
        let renderedData = filterRenderer.renderedData(
            from: data,
            recipe: claim.context.filter,
            intensity: claim.context.filterIntensity,
            aspectRatio: requiresAspectProcessing ? claim.context.ratio.value : nil
        )
        let canSaveUnfilteredFallback = Self.canSaveUnfilteredFallback(
            hasFilter: claim.context.filter != nil,
            requiresAspectProcessing: requiresAspectProcessing
        )
        guard let outputData = renderedData ?? (canSaveUnfilteredFallback ? data : nil) else {
            guard captureCoordinator.complete(captureID: captureID, expectedStage: .processing) else { return }
            retireCaptureTimeout(id: captureID)
            publish(notice: "camera.error.processing", recoverableFailure: true)
            finishCapture(captureID: captureID, recoverableFailure: true)
            return
        }
        let filterFallback = renderedData == nil && canSaveUnfilteredFallback
        // Built from the exact snapshot capture() used to configure the
        // output — never re-derived — plus the one thing that can only be
        // known now: what ImageIO reports the saved bytes actually contain.
        let record = CaptureResolutionRecord(
            requested: claim.context.snapshot.resolved.requested,
            resolvedDimensions: claim.context.snapshot.resolved.dimensions,
            savedDimensions: Self.pixelDimensions(of: outputData),
            downgradeReason: claim.context.snapshot.resolved.downgradeReason
        )
        save(
            captureID: captureID,
            request: SaveRequest(
                primaryData: outputData,
                originalData: claim.context.saveOriginal && claim.context.filter != nil && !filterFallback ? data : nil,
                location: claim.context.location,
                record: record,
                countsFilter: claim.context.filter != nil && !filterFallback,
                filterFallback: filterFallback
            )
        )
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
        error: Error?
    ) {
        guard error != nil else { return }
        cancelCapture(id: resolvedSettings.uniqueID, notice: "camera.error.capture")
    }

    static func semanticTarget(
        for plan: AICompositionPlan,
        measurement: SceneMeasurement? = nil,
        intent: CaptureIntent = .auto,
        selectedSubjectID: SubjectTrackID? = nil,
        generation: Int = 0
    ) -> SemanticGuidanceTarget {
        let subjectIDs: [SubjectTrackID]
        if let selectedSubjectID {
            subjectIDs = [selectedSubjectID]
        } else if let measurement, intent != .scene {
            switch measurement.people.count {
            case 1:
                subjectIDs = [measurement.people[0].id]
            case 2...5:
                subjectIDs = measurement.group?.memberIDs ?? []
            default:
                subjectIDs = []
            }
        } else {
            subjectIDs = []
        }
        SemanticGuidanceTarget(
            targetFrame: plan.target.cgRect,
            instruction: plan.instruction,
            generation: generation,
            intent: intent,
            subjectIDs: subjectIDs
        )
    }

    // Compatibility entry point for the existing cloud-plan regression. The
    // plan is only an immutable target input; it never bypasses the reducer.
    static func cloudGuidance(_ plan: AICompositionPlan, measurement: SceneMeasurement) -> Guidance {
        var engine = GuidanceEngine()
        return engine.update(
            measurement,
            intent: .auto,
            semanticTarget: semanticTarget(for: plan, measurement: measurement)
        )!
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
            beginGuidanceAnalysisOnQueue()
            lastAnalysisTime = timestamp
            let generation = analysisGeneration
            let preferredPoint = selectedSubjectPoint
            #if DEBUG
                lifecycleLog.debug("analysis started (generation=\(generation, privacy: .public))")
            #endif
            analyzer.analyze(
                buffer,
                preferredSubjectPoint: preferredPoint
            ) { [weak self] measurement in
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
                    let stable = self.stabilizer.update(measurement, generation: generation)
                    self.updateGuidance(with: stable, generation: generation)
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
