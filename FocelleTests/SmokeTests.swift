import AVFoundation
import CoreImage
import Photos
import XCTest

@testable import Focelle

final class SmokeTests: XCTestCase {
    @MainActor
    func testCameraViewCanBeCreated() {
        XCTAssertNotNil(CameraView())
    }

    func testRestrictedCameraPermissionIsDenied() {
        XCTAssertEqual(CameraPermission(.restricted), .denied)
        XCTAssertEqual(CameraPermission(.authorized), .allowed)
    }

    func testPhotoDimensionsNeverExceedTheOutputLimit() {
        let limit = CMVideoDimensions(width: 8_064, height: 6_048)
        let standard = CMVideoDimensions(width: 5_712, height: 4_284)

        XCTAssertEqual(CameraSession.photoDimensions(standard, within: limit)?.width, 5_712)
        XCTAssertEqual(
            CameraSession.photoDimensions(
                CMVideoDimensions(width: 12_000, height: 9_000),
                within: limit
            )?.width,
            8_064
        )
        XCTAssertNil(CameraSession.photoDimensions(nil, within: limit))
        XCTAssertNil(
            CameraSession.photoDimensions(
                standard,
                within: CMVideoDimensions(width: 0, height: 0)
            )
        )
    }

    func testPhotoResolutionChoosesClosestTo24Megapixels() {
        let options = [
            PhotoDimensions(width: 4_032, height: 3_024),
            PhotoDimensions(width: 5_712, height: 4_284),
            PhotoDimensions(width: 8_064, height: 6_048),
        ]

        XCTAssertEqual(PhotoDimensions.standard(in: options), options[1])
    }

    func testResolutionLabelBucketsToKnownMegapixelCountsOrFallsBackToDimensions() {
        let twelveMP = PhotoDimensions(width: 4_000, height: 3_000)
        let twentyFourMP = PhotoDimensions(width: 6_000, height: 4_000)
        let fortyEightMP = PhotoDimensions(width: 8_000, height: 6_000)
        let offBucket = PhotoDimensions(width: 2_000, height: 1_500)

        XCTAssertEqual(ResolvedResolution.label(for: twelveMP), "12")
        XCTAssertEqual(ResolvedResolution.label(for: twentyFourMP), "24")
        XCTAssertEqual(ResolvedResolution.label(for: fortyEightMP), "48")
        XCTAssertEqual(ResolvedResolution.label(for: offBucket), "2000×1500")
        XCTAssertEqual(ResolvedResolution.label(for: nil), "—")
    }

    func testHasDistinctMaximumRequiresAGenuinelyLargerTier() {
        let standard = PhotoDimensions(width: 4_000, height: 3_000)
        let sameAsStandard = PhotoDimensions(width: 4_000, height: 3_000)
        let genuineMaximum = PhotoDimensions(width: 8_000, height: 6_000)

        XCTAssertFalse(ResolvedResolution.hasDistinctMaximum(standard: standard, maximum: sameAsStandard))
        XCTAssertTrue(ResolvedResolution.hasDistinctMaximum(standard: standard, maximum: genuineMaximum))
        XCTAssertFalse(ResolvedResolution.hasDistinctMaximum(standard: nil, maximum: genuineMaximum))
    }

    // This is the exact shape of the physical bug: a device whose "maximum"
    // tier is no bigger than "standard" must not silently claim a 48 MP
    // capability it doesn't have — resolve() has to say so, not the caller.
    func testResolveFlagsADowngradeWhenMaximumIsNoBiggerThanStandardOrOutputCapsIt() {
        let standard = PhotoDimensions(width: 4_000, height: 3_000)
        let biggerMaximum = PhotoDimensions(width: 8_000, height: 6_000)

        let normalStandard = ResolvedResolution.resolve(
            requested: .standard,
            standard: standard,
            maximum: biggerMaximum,
            outputLimit: nil
        )
        XCTAssertEqual(normalStandard.dimensions, standard)
        XCTAssertEqual(normalStandard.downgradeReason, .none)

        let normalMaximum = ResolvedResolution.resolve(
            requested: .maximum,
            standard: standard,
            maximum: biggerMaximum,
            outputLimit: nil
        )
        XCTAssertEqual(normalMaximum.dimensions, biggerMaximum)
        XCTAssertEqual(normalMaximum.downgradeReason, .none)

        let deviceCappedMaximum = ResolvedResolution.resolve(
            requested: .maximum,
            standard: standard,
            maximum: standard,
            outputLimit: nil
        )
        XCTAssertEqual(deviceCappedMaximum.dimensions, standard)
        XCTAssertEqual(deviceCappedMaximum.downgradeReason, .unsupportedByActiveFormat)
        XCTAssertTrue(deviceCappedMaximum.isDowngraded)

        let outputCappedMaximum = ResolvedResolution.resolve(
            requested: .maximum,
            standard: standard,
            maximum: biggerMaximum,
            outputLimit: standard
        )
        XCTAssertEqual(outputCappedMaximum.dimensions, standard)
        XCTAssertEqual(outputCappedMaximum.downgradeReason, .outputLimited)
    }

    func testCaptureResolutionRecordReportsSavedDimensionsEvenWhenTheyContradictTheRequest() {
        let requested = PhotoDimensions(width: 8_000, height: 6_000)
        let actuallySaved = PhotoDimensions(width: 4_032, height: 3_024)

        let record = CaptureResolutionRecord(
            requested: .maximum,
            resolvedDimensions: requested,
            savedDimensions: actuallySaved,
            downgradeReason: .none
        )

        XCTAssertEqual(record.requestedLabel, "maximum")
        XCTAssertEqual(record.resolvedDimensions, requested)
        XCTAssertEqual(record.savedDimensions, actuallySaved)
        XCTAssertNotEqual(record.resolvedDimensions, record.savedDimensions)
    }

    // MARK: - FCL-M2-R1 capture ownership and add-only privacy

    func testCaptureCoordinatorClaimsImmediateDeliveryExactlyOnce() {
        let coordinator = CaptureCoordinator<String>()
        XCTAssertTrue(coordinator.register(captureID: 101, context: "immediate"))

        guard case .success(let claim) = coordinator.claim(captureID: 101, callbackType: .immediatePhoto) else {
            return XCTFail("the immediate callback must claim its registered capture")
        }
        XCTAssertEqual(claim.context, "immediate")
        XCTAssertEqual(claim.callbackType, .immediatePhoto)
        XCTAssertEqual(coordinator.pendingCount, 1)
    }

    func testCaptureCoordinatorClaimsDeferredDeliveryWithoutPrediction() {
        let coordinator = CaptureCoordinator<String>()
        XCTAssertTrue(coordinator.register(captureID: 102, context: "deferred"))

        guard case .success(let claim) = coordinator.claim(captureID: 102, callbackType: .deferredProxy) else {
            return XCTFail("actual deferred delivery must not depend on a predicted mode")
        }
        XCTAssertEqual(claim.context, "deferred")
        XCTAssertEqual(claim.callbackType, .deferredProxy)
    }

    func testCaptureCoordinatorAcceptsEitherActualDeliveryPath() {
        let immediate = CaptureCoordinator<String>()
        let deferred = CaptureCoordinator<String>()
        XCTAssertTrue(immediate.register(captureID: 103, context: "same snapshot"))
        XCTAssertTrue(deferred.register(captureID: 104, context: "same snapshot"))

        guard case .success = immediate.claim(captureID: 103, callbackType: .immediatePhoto),
            case .success = deferred.claim(captureID: 104, callbackType: .deferredProxy)
        else { return XCTFail("both real delegate payload types must be claimable") }
    }

    func testDuplicateDeliveryCannotClaimOrCompleteASaveTwice() {
        let coordinator = CaptureCoordinator<String>()
        XCTAssertTrue(coordinator.register(captureID: 105, context: "one save"))
        guard case .success = coordinator.claim(captureID: 105, callbackType: .immediatePhoto) else {
            return XCTFail("first callback must claim")
        }
        guard case .failure(let duplicate) = coordinator.claim(captureID: 105, callbackType: .deferredProxy) else {
            return XCTFail("second callback must be rejected")
        }
        XCTAssertEqual(duplicate.currentStage, .processing)
        XCTAssertEqual(duplicate.reason, .alreadyClaimed)

        XCTAssertTrue(coordinator.beginSaving(captureID: 105))
        XCTAssertTrue(coordinator.complete(captureID: 105, expectedStage: .saving))
        XCTAssertFalse(coordinator.complete(captureID: 105, expectedStage: .saving))
        XCTAssertEqual(coordinator.pendingCount, 0)
    }

    func testUnknownCallbackProducesADiagnosticInsteadOfSuccess() {
        let coordinator = CaptureCoordinator<String>()
        guard case .failure(let diagnostic) = coordinator.claim(captureID: 404, callbackType: .immediatePhoto) else {
            return XCTFail("unknown callbacks cannot be accepted")
        }
        XCTAssertEqual(diagnostic.captureID, 404)
        XCTAssertNil(diagnostic.currentStage)
        XCTAssertEqual(diagnostic.reason, .unknownCapture)
    }

    @MainActor
    func testAnalysisResetPreservesPendingCaptures() {
        let camera = CameraSession()
        camera.debugRegisterPendingCaptureForTesting(id: 106)

        camera.resetAnalysisForResume()

        XCTAssertEqual(camera.debugPendingCaptureCount, 1)
    }

    func testCaptureTimeoutTerminatesAwaitingDeliveryAndProcessingExactlyOnce() {
        let coordinator = CaptureCoordinator<String>()
        XCTAssertTrue(coordinator.register(captureID: 107, context: "delivery"))
        XCTAssertEqual(coordinator.timeout(captureID: 107)?.stage, .awaitingDelivery)
        XCTAssertNil(coordinator.timeout(captureID: 107))
        XCTAssertEqual(CameraSession.timeoutNotice(for: .awaitingDelivery), "camera.error.captureTimeoutDelivery")

        XCTAssertTrue(coordinator.register(captureID: 108, context: "processing"))
        guard case .success = coordinator.claim(captureID: 108, callbackType: .immediatePhoto) else {
            return XCTFail("capture must enter processing")
        }
        XCTAssertEqual(coordinator.timeout(captureID: 108)?.stage, .processing)
        XCTAssertNil(coordinator.timeout(captureID: 108))
        XCTAssertEqual(CameraSession.timeoutNotice(for: .processing), "camera.error.captureTimeoutProcessing")
    }

    func testSavingOwnershipSurvivesTimeoutAndCompletesExactlyOnce() {
        let coordinator = CaptureCoordinator<String>()
        XCTAssertTrue(coordinator.register(captureID: 109, context: "saving"))
        guard case .success = coordinator.claim(captureID: 109, callbackType: .deferredProxy) else {
            return XCTFail("capture must claim deferred delivery")
        }
        XCTAssertTrue(coordinator.beginSaving(captureID: 109))
        XCTAssertNil(coordinator.timeout(captureID: 109))
        XCTAssertEqual(coordinator.pendingCount, 1)
        XCTAssertTrue(coordinator.complete(captureID: 109, expectedStage: .saving))
        XCTAssertFalse(coordinator.complete(captureID: 109, expectedStage: .saving))
        XCTAssertEqual(coordinator.pendingCount, 0)
    }

    func testFinalCaptureCancellationCannotRevokeSavingOwnership() {
        let coordinator = CaptureCoordinator<String>()
        XCTAssertTrue(coordinator.register(captureID: 110, context: "final error"))
        guard case .success = coordinator.claim(captureID: 110, callbackType: .immediatePhoto) else {
            return XCTFail("capture must enter processing")
        }
        XCTAssertTrue(coordinator.beginSaving(captureID: 110))

        // CameraSession routes a final AVFoundation error through this same
        // cancellation boundary, so it must not revoke a PhotoKit owner.
        XCTAssertNil(coordinator.timeout(captureID: 110))
        XCTAssertTrue(coordinator.complete(captureID: 110, expectedStage: .saving))
    }

    func testLifecycleCancellationTerminatesOnlyCapturesThatHaveNotReachedPhotos() {
        let coordinator = CaptureCoordinator<String>()
        XCTAssertTrue(coordinator.register(captureID: 111, context: "awaiting"))
        XCTAssertTrue(coordinator.register(captureID: 112, context: "processing"))
        XCTAssertTrue(coordinator.register(captureID: 113, context: "saving"))
        guard case .success = coordinator.claim(captureID: 112, callbackType: .immediatePhoto),
            case .success = coordinator.claim(captureID: 113, callbackType: .immediatePhoto)
        else {
            return XCTFail("captures must enter processing")
        }
        XCTAssertTrue(coordinator.beginSaving(captureID: 113))

        let cancelled = coordinator.cancelBeforeSaving()

        XCTAssertEqual(Set(cancelled.map(\.captureID)), Set([111, 112]))
        XCTAssertEqual(Set(cancelled.map(\.stage)), Set([.awaitingDelivery, .processing]))
        XCTAssertEqual(coordinator.pendingCount, 1)
        XCTAssertEqual(CameraSession.cancellationNotice, "camera.error.captureCancelled")
    }

    func testIndependentCaptureIDsDoNotInterfereAfterSavingBegins() {
        let coordinator = CaptureCoordinator<String>()
        XCTAssertTrue(coordinator.register(captureID: 114, context: "first"))
        XCTAssertTrue(coordinator.register(captureID: 115, context: "second"))
        guard case .success = coordinator.claim(captureID: 114, callbackType: .immediatePhoto),
            case .success = coordinator.claim(captureID: 115, callbackType: .deferredProxy)
        else {
            return XCTFail("both captures must claim their own delivery")
        }
        XCTAssertTrue(coordinator.beginSaving(captureID: 114))
        XCTAssertTrue(coordinator.beginSaving(captureID: 115))

        XCTAssertNil(coordinator.timeout(captureID: 114))
        XCTAssertTrue(coordinator.complete(captureID: 115, expectedStage: .saving))
        XCTAssertTrue(coordinator.complete(captureID: 114, expectedStage: .saving))
    }

    func testPhotoAuthorizationFailuresRemainDistinct() {
        XCTAssertNil(CameraSession.photoAuthorizationNotice(for: .authorized))
        XCTAssertNil(CameraSession.photoAuthorizationNotice(for: .limited))
        XCTAssertEqual(
            CameraSession.photoAuthorizationNotice(for: .denied),
            "camera.error.photosPermissionDenied"
        )
        XCTAssertEqual(
            CameraSession.photoAuthorizationNotice(for: .restricted),
            "camera.error.photosRestricted"
        )
        XCTAssertNil(CameraSession.photoWriteNotice(for: true))
        XCTAssertEqual(CameraSession.photoWriteNotice(for: false), "camera.error.photosWrite")
    }

    func testUnfilteredFallbackIsTruthfulAndDoesNotClaimFilterSuccess() {
        XCTAssertTrue(CameraSession.canSaveUnfilteredFallback(hasFilter: true, requiresAspectProcessing: false))
        XCTAssertFalse(CameraSession.canSaveUnfilteredFallback(hasFilter: false, requiresAspectProcessing: false))
        XCTAssertFalse(CameraSession.canSaveUnfilteredFallback(hasFilter: true, requiresAspectProcessing: true))
        XCTAssertEqual(CameraSession.filterFallbackNotice, "camera.warning.filterFallbackSaved")
    }

    func testPhotoLibraryConfigurationIsAddOnlyAndHasNoObserverOrReadback() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let infoData = try Data(contentsOf: repository.appending(path: "Focelle/Info.plist"))
        let info = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: infoData, format: nil) as? [String: Any]
        )
        XCTAssertNil(info["NSPhotoLibraryUsageDescription"])
        XCTAssertNotNil(info["NSPhotoLibraryAddUsageDescription"])

        let cameraSource = try String(
            contentsOf: repository.appending(path: "Focelle/Camera/CameraSession.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(cameraSource.contains("requestAuthorization(for: .addOnly)"))
        XCTAssertFalse(cameraSource.contains("requestAuthorization(for: .readWrite)"))
        XCTAssertFalse(cameraSource.contains("registerChangeObserver"))
        XCTAssertFalse(cameraSource.contains("PHPhotoLibraryChangeObserver"))
        XCTAssertFalse(cameraSource.contains("PHAsset.fetch"))
        XCTAssertTrue(cameraSource.contains("error.domain"))
        XCTAssertTrue(cameraSource.contains("error.code"))
    }

    @MainActor
    func testRequestedResolutionDefaultsToStandardAndPersistsAcrossRecreation() {
        let suite = "FocelleTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(AppSettings(defaults: defaults).requestedResolution, .standard)

        let settings = AppSettings(defaults: defaults)
        settings.requestedResolution = .maximum

        // Simulates a Settings round trip and a full relaunch: a fresh
        // AppSettings reading the same defaults must see the same selection.
        XCTAssertEqual(AppSettings(defaults: defaults).requestedResolution, .maximum)
    }

    @MainActor
    func testCameraResolutionOnlyChangesThroughSetRequestedResolution() {
        let camera = CameraSession()

        XCTAssertEqual(camera.resolution, .standard)
        camera.setRequestedResolution(.maximum)
        XCTAssertEqual(camera.resolution, .maximum)
        XCTAssertEqual(camera.resolvedResolution.requested, .maximum)
    }

    @MainActor
    func testResolutionAndGuidanceRefreshNeverTouchZoomOrExposure() async throws {
        let camera = CameraSession()
        camera.zoom = 3.4
        camera.exposure = 0.6

        camera.setRequestedResolution(.maximum)
        camera.refreshLocalGuidanceAfterSettings()
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(camera.zoom, 3.4)
        XCTAssertEqual(camera.exposure, 0.6, accuracy: 0.0001)
    }

    // MARK: - AppSettings.requestedResolution migration (Finding 2)

    @MainActor
    func testLegacyMaximumResolutionTrueMigratesToMaximum() {
        let suite = "FocelleTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "maximumResolution")

        XCTAssertEqual(AppSettings(defaults: defaults).requestedResolution, .maximum)
    }

    @MainActor
    func testLegacyMaximumResolutionFalseMigratesToStandard() {
        let suite = "FocelleTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "maximumResolution")

        XCTAssertEqual(AppSettings(defaults: defaults).requestedResolution, .standard)
    }

    @MainActor
    func testNewFormatResolutionValueTakesPrecedenceOverLegacyBool() {
        let suite = "FocelleTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "maximumResolution")
        defaults.set(CameraResolution.standard.rawValue, forKey: "requestedResolution")

        XCTAssertEqual(AppSettings(defaults: defaults).requestedResolution, .standard)
    }

    @MainActor
    func testMigratedResolutionPersistsAndDropsTheLegacyKey() {
        let suite = "FocelleTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "maximumResolution")

        _ = AppSettings(defaults: defaults)

        XCTAssertEqual(defaults.string(forKey: "requestedResolution"), CameraResolution.maximum.rawValue)
        XCTAssertNil(defaults.object(forKey: "maximumResolution"))
        // Idempotent: a second instantiation reads the already-migrated value.
        XCTAssertEqual(AppSettings(defaults: defaults).requestedResolution, .maximum)
    }

    // MARK: - Requested tier survives camera-capability changes (Finding 3)

    @MainActor
    func testRequestedMaximumSurvivesACapableToUnsupportedToCapableCameraSwitch() {
        let camera = CameraSession()
        let standard = PhotoDimensions(width: 4_000, height: 3_000)
        let genuineMaximum = PhotoDimensions(width: 8_000, height: 6_000)

        // Start on a capable camera and request maximum.
        camera.cachedStandardDimensions = standard
        camera.cachedMaximumDimensions = genuineMaximum
        camera.cachedOutputLimit = genuineMaximum
        camera.recomputeResolvedResolution()
        camera.setRequestedResolution(.maximum)
        XCTAssertEqual(camera.resolvedResolution.dimensions, genuineMaximum)
        XCTAssertFalse(camera.resolvedResolution.isDowngraded)

        // Switch to a camera whose only tier is "standard" — no distinct maximum.
        camera.cachedStandardDimensions = standard
        camera.cachedMaximumDimensions = standard
        camera.cachedOutputLimit = standard
        camera.recomputeResolvedResolution()

        XCTAssertEqual(camera.resolution, .maximum, "the requested tier must survive an incapable camera")
        XCTAssertEqual(camera.resolvedResolution.dimensions, standard)
        XCTAssertEqual(camera.resolvedResolution.downgradeReason, .unsupportedByActiveFormat)

        // Switch back to a capable camera: resolves to maximum again with no
        // further Settings/toolbar action required.
        camera.cachedStandardDimensions = standard
        camera.cachedMaximumDimensions = genuineMaximum
        camera.cachedOutputLimit = genuineMaximum
        camera.recomputeResolvedResolution()

        XCTAssertEqual(camera.resolution, .maximum)
        XCTAssertEqual(camera.resolvedResolution.dimensions, genuineMaximum)
        XCTAssertFalse(camera.resolvedResolution.isDowngraded)
    }

    @MainActor
    func testCapabilityRecomputeNeverTouchesZoomOrExposure() {
        let camera = CameraSession()
        camera.zoom = 2.5
        camera.exposure = -0.3
        camera.setRequestedResolution(.maximum)

        camera.cachedStandardDimensions = PhotoDimensions(width: 4_000, height: 3_000)
        camera.cachedMaximumDimensions = PhotoDimensions(width: 4_000, height: 3_000)
        camera.cachedOutputLimit = PhotoDimensions(width: 4_000, height: 3_000)
        camera.recomputeResolvedResolution()

        XCTAssertEqual(camera.zoom, 2.5)
        XCTAssertEqual(camera.exposure, -0.3, accuracy: 0.0001)
    }

    // MARK: - One immutable capture snapshot (Finding 4)

    @MainActor
    func testCaptureSnapshotReflectsCapabilitiesAsOfCaptureTimeNotAnOlderGeneration() {
        let camera = CameraSession()
        let oldStandard = PhotoDimensions(width: 3_000, height: 2_250)
        let oldMaximum = PhotoDimensions(width: 6_000, height: 4_500)
        camera.standardDimensions = oldStandard
        camera.maximumDimensions = oldMaximum
        camera.outputLimitDimensions = oldMaximum
        camera.capabilityGeneration = 1

        let oldSnapshot = camera.currentCaptureSnapshot(for: .maximum)
        XCTAssertEqual(oldSnapshot.resolved.dimensions, oldMaximum)
        XCTAssertEqual(oldSnapshot.capabilityGeneration, 1)

        // A camera switch replaces the queue-owned capability state and bumps
        // the generation before the next capture is taken.
        let newStandard = PhotoDimensions(width: 4_000, height: 3_000)
        let newMaximum = PhotoDimensions(width: 8_000, height: 6_000)
        camera.standardDimensions = newStandard
        camera.maximumDimensions = newMaximum
        camera.outputLimitDimensions = newMaximum
        camera.capabilityGeneration = 2

        let newSnapshot = camera.currentCaptureSnapshot(for: .maximum)
        XCTAssertEqual(newSnapshot.resolved.dimensions, newMaximum)
        XCTAssertEqual(newSnapshot.capabilityGeneration, 2)
        XCTAssertNotEqual(
            newSnapshot,
            oldSnapshot,
            "a later capture must not resolve against the previous camera's dimensions"
        )
    }

    @MainActor
    func testCaptureSettingsAndSavedRecordShareTheExactResolvedDimensions() {
        let camera = CameraSession()
        let resolved = PhotoDimensions(width: 8_000, height: 6_000)
        camera.standardDimensions = PhotoDimensions(width: 4_000, height: 3_000)
        camera.maximumDimensions = resolved
        camera.outputLimitDimensions = resolved
        camera.capabilityGeneration = 5
        camera.setRequestedResolution(.maximum)

        let snapshot = camera.currentCaptureSnapshot(for: camera.resolution)

        // Mirrors exactly what capture() does with the snapshot.
        let configuredDimensions = snapshot.resolved.dimensions.map {
            CMVideoDimensions(width: $0.width, height: $0.height)
        }
        // Mirrors exactly what photoOutput(_:didFinishProcessingPhoto:) does with it.
        let record = CaptureResolutionRecord(
            requested: snapshot.resolved.requested,
            resolvedDimensions: snapshot.resolved.dimensions,
            savedDimensions: nil,
            downgradeReason: snapshot.resolved.downgradeReason
        )

        XCTAssertEqual(configuredDimensions?.width, resolved.width)
        XCTAssertEqual(configuredDimensions?.height, resolved.height)
        XCTAssertEqual(record.resolvedDimensions, resolved)
        XCTAssertEqual(snapshot.capabilityGeneration, 5)
    }

    func testCameraRotationMatchesInterfaceOrientation() {
        XCTAssertEqual(CameraRotation.angle(for: .portrait), 90)
        XCTAssertEqual(CameraRotation.angle(for: .landscapeLeft), 0)
        XCTAssertEqual(CameraRotation.angle(for: .landscapeRight), 180)
    }

    func testCameraRestartsOnlyAfterMediaServicesReset() {
        XCTAssertTrue(CameraSession.canRestart(after: AVError(.mediaServicesWereReset)))
        XCTAssertFalse(CameraSession.canRestart(after: AVError(.unknown)))
    }

    func testOriginalFiltersAreOwnedUniqueRecipes() {
        XCTAssertEqual(FocelleOriginals.all.count, 12)
        XCTAssertEqual(Set(FocelleOriginals.all.map(\.id)).count, 12)
    }

    func testEveryOriginalFilterRendersSyntheticImage() {
        let renderer = FilterRenderer()
        let input = CIImage(color: .init(red: 0.4, green: 0.5, blue: 0.6))
            .cropped(to: CGRect(x: 0, y: 0, width: 32, height: 24))

        for recipe in FocelleOriginals.all {
            XCTAssertEqual(renderer.render(input, recipe: recipe).extent, input.extent)
        }
    }

    // FCL-004: the saved-output pipeline must not be a hidden source of a
    // resolution downgrade. A filter changes pixel values, not pixel count.
    func testFilterRenderingPreservesPixelDimensionsWithoutAnAspectCrop() throws {
        let renderer = FilterRenderer()
        let width = 320
        let height = 240
        let input = CIImage(color: .init(red: 0.4, green: 0.5, blue: 0.6))
            .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let sourceData = try XCTUnwrap(CIContext().jpegRepresentation(of: input, colorSpace: colorSpace))
        let sourceDimensions = try XCTUnwrap(CameraSession.pixelDimensions(of: sourceData))
        XCTAssertEqual(sourceDimensions, PhotoDimensions(width: Int32(width), height: Int32(height)))

        let filteredData = try XCTUnwrap(
            renderer.renderedData(
                from: sourceData,
                recipe: FocelleOriginals.all[0],
                intensity: 1,
                aspectRatio: nil
            )
        )
        let filteredDimensions = try XCTUnwrap(CameraSession.pixelDimensions(of: filteredData))

        XCTAssertEqual(
            filteredDimensions,
            sourceDimensions,
            "a filter must not silently shrink the saved output"
        )
    }

    func testFilterThumbnailsRenderOnePerRequestAtOneSize() {
        let renderer = FilterRenderer()
        let input = CIImage(color: .init(red: 0.4, green: 0.5, blue: 0.6))
            .cropped(to: CGRect(x: 0, y: 0, width: 320, height: 240))
        let requests =
            [FilterThumbnailRequest(key: "none", recipe: nil)]
            + FocelleOriginals.all.map { FilterThumbnailRequest(key: $0.id, recipe: $0) }

        let images = renderer.thumbnails(input, requests: requests, side: 48)

        XCTAssertEqual(images.count, requests.count)
        for request in requests {
            XCTAssertEqual(images[request.key]?.width, 48, request.key)
            XCTAssertEqual(images[request.key]?.height, 48, request.key)
        }
    }

    func testPresetDraftClampsToneColorAndResets() throws {
        let base = FocelleOriginals.all[0]
        var draft = PresetDraft(base: base)
        draft.setToneColor(tone: 2, color: -2)
        XCTAssertEqual(draft.recipe.exposure, 0.35)
        XCTAssertEqual(draft.recipe.warmth, -0.5)

        draft.reset()
        XCTAssertEqual(draft.recipe, base)
        XCTAssertNoThrow(try JSONEncoder().encode(draft))
    }

    @MainActor
    func testPresetStorePersistsAndLatestEditWinsMerge() throws {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let file = folder.appending(path: "presets.json")
        let store = PresetStore(fileURL: file)
        let oldDate = Date(timeIntervalSince1970: 10)
        let preset = store.create(
            name: "My Look",
            recipe: FocelleOriginals.all[0],
            intensity: 2,
            now: oldDate
        )
        XCTAssertEqual(PresetStore(fileURL: file).presets.first?.intensity, 1)

        var remote = preset
        remote.name = "Newer Name"
        remote.updatedAt = Date(timeIntervalSince1970: 20)
        XCTAssertEqual(UserPreset.merged(store.records, [remote]).first?.name, "Newer Name")
    }

    func testCloudKitStaysOffWhenNoContainerIsConfigured() {
        XCTAssertNil(PresetSync.containerIdentifier(nil))
        XCTAssertNil(PresetSync.containerIdentifier(""))
        XCTAssertNil(PresetSync.containerIdentifier("   "))
        XCTAssertEqual(
            PresetSync.containerIdentifier(" iCloud.com.pnhd.focelle "),
            "iCloud.com.pnhd.focelle"
        )
    }

    @MainActor
    func testSyncWithoutICloudKeepsPresetsAndStaysSilent() async {
        let file = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
            .appending(path: "presets.json")
        let store = PresetStore(fileURL: file)
        store.create(name: "Local", recipe: FocelleOriginals.all[0], intensity: 0.5)

        await store.sync()

        XCTAssertNil(store.syncError)
        XCTAssertEqual(store.presets.count, 1)
    }

    func testPresetMigratesMissingVersionAndFlags() throws {
        let preset = UserPreset(
            id: UUID(),
            name: "Legacy",
            recipe: FocelleOriginals.all[0],
            intensity: 0.7,
            updatedAt: .now
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(preset)) as? [String: Any]
        )
        object["schemaVersion"] = nil
        object["isFavorite"] = nil
        object["isDeleted"] = nil

        let migrated = try JSONDecoder().decode(
            UserPreset.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertEqual(migrated.schemaVersion, 1)
        XCTAssertFalse(migrated.isFavorite)
        XCTAssertFalse(migrated.isDeleted)
    }

    func testPresetDecodeClampsUntrustedCloudValues() throws {
        var recipe = FocelleOriginals.all[0]
        recipe.exposure = 99
        recipe.fade = -4
        let preset = UserPreset(
            id: UUID(),
            name: " ".padding(toLength: 80, withPad: "A", startingAt: 0),
            recipe: recipe,
            intensity: 4,
            updatedAt: .now
        )

        let decoded = try JSONDecoder().decode(
            UserPreset.self,
            from: JSONEncoder().encode(preset)
        )

        XCTAssertEqual(decoded.recipe.exposure, 1)
        XCTAssertEqual(decoded.recipe.fade, 0)
        XCTAssertEqual(decoded.intensity, 1)
        XCTAssertLessThanOrEqual(decoded.name.count, 40)
    }

    @MainActor
    func testPhotoEditorKeepsOriginalWhilePreviewChanges() throws {
        let input = CIImage(color: .init(red: 0.3, green: 0.4, blue: 0.5))
            .cropped(to: CGRect(x: 0, y: 0, width: 24, height: 18))
        let data = try XCTUnwrap(
            CIContext().jpegRepresentation(
                of: input,
                colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!
            )
        )
        let model = PhotoEditorModel(data: data)
        let original = model.originalData

        model.apply(FocelleOriginals.all[1], intensity: 0.5)

        XCTAssertEqual(model.originalData, original)
        XCTAssertNotNil(model.preview)
    }

    func testMeasurementStabilizerDampensMovement() {
        var stabilizer = MeasurementStabilizer()
        let first = SceneMeasurement(
            subjectRect: CGRect(x: 0, y: 0, width: 0.2, height: 0.3),
            faceRects: [],
            salientRect: nil,
            horizonAngle: 0,
            exposure: 0.2,
            timestamp: 1
        )
        _ = stabilizer.update(first)
        let result = stabilizer.update(
            SceneMeasurement(
                subjectRect: CGRect(x: 1, y: 1, width: 0.2, height: 0.3),
                faceRects: [],
                salientRect: nil,
                horizonAngle: 1,
                exposure: 1,
                timestamp: 2
            )
        )

        XCTAssertEqual(result.subjectRect?.origin.x, 0.35)
        XCTAssertEqual(result.horizonAngle, 0.35)
        XCTAssertEqual(result.exposure, 0.48, accuracy: 0.001)
    }

    func testGuidanceTargetsRuleOfThirdsAndDebouncesChanges() {
        let left = SceneMeasurement(
            subjectRect: CGRect(x: 0.05, y: 0.3, width: 0.2, height: 0.4),
            faceRects: [],
            salientRect: nil,
            horizonAngle: 0,
            exposure: 0.5,
            timestamp: 1
        )
        XCTAssertEqual(GuidanceEngine.propose(left).direction, .left)

        var engine = GuidanceEngine()
        XCTAssertEqual(engine.update(left)?.direction, .left)

        // Drifting inside the exit band must not rewrite the instruction while
        // the user is still carrying out the previous one.
        var drifting = left
        drifting.subjectRect = CGRect(x: 0.10, y: 0.3, width: 0.2, height: 0.4)
        drifting.timestamp = 2
        XCTAssertEqual(engine.update(drifting)?.direction, .left)

        // Overshooting to the far side clears it at once; holding an
        // instruction that is now wrong is worse than switching.
        var overshot = left
        overshot.subjectRect = CGRect(x: 0.75, y: 0.3, width: 0.2, height: 0.4)
        overshot.timestamp = 3
        XCTAssertEqual(engine.update(overshot)?.direction, .right)
    }

    func testTargetSlidesToCentreInsteadOfJumping() {
        let side = 1.0 / 3
        let small = GuidanceEngine.targetX(side: side, width: 0.28)
        let mid = GuidanceEngine.targetX(side: side, width: 0.40)
        let large = GuidanceEngine.targetX(side: side, width: 0.55)

        XCTAssertEqual(small, side, accuracy: 0.001)
        XCTAssertEqual(large, 0.5, accuracy: 0.001)
        XCTAssertGreaterThan(mid, small)
        XCTAssertLessThan(mid, large)
        // The previous rule moved the target a sixth of the frame in one step
        // as soon as width crossed 0.42, which read as "move closer" becoming
        // "move left" while the user was still walking in.
        XCTAssertLessThan(
            abs(mid - GuidanceEngine.targetX(side: side, width: 0.41)),
            0.02
        )
    }

    func testChosenThirdSurvivesASubjectHoveringNearTheMiddle() {
        let left = 1.0 / 3
        let hovering = CGRect(x: 0.42, y: 0.3, width: 0.16, height: 0.4)

        XCTAssertEqual(GuidanceEngine.side(for: hovering, latched: left), left)
        XCTAssertEqual(
            GuidanceEngine.side(
                for: CGRect(x: 0.60, y: 0.3, width: 0.16, height: 0.4),
                latched: left
            ),
            2.0 / 3
        )
    }

    func testGroupBoundsAndSelectedSubject() {
        let left = CGRect(x: 0.05, y: 0.2, width: 0.25, height: 0.6)
        let right = CGRect(x: 0.6, y: 0.2, width: 0.25, height: 0.6)
        let group = left.union(right)

        XCTAssertEqual(OnDeviceAnalyzer.combinedRect([left, right]), group)

        let measurement = SceneMeasurement(
            subjectRect: group,
            humanRects: [left, right],
            faceRects: [],
            salientRect: nil,
            horizonAngle: 0,
            exposure: 0.5,
            timestamp: 1
        )
        XCTAssertEqual(
            measurement.subject(near: CGPoint(x: 0.75, y: 0.5)),
            right
        )
    }

    // MARK: - FCL-M2-R2-S1 local geometry and Blueprint guidance kernel

    func testPersonTracksKeepIdentityAcrossSmallMovement() {
        var stabilizer = MeasurementStabilizer()
        let first = stabilizer.update(
            peopleMeasurement([person(x: 0.20, y: 0.20)]),
            generation: 8
        )
        let second = stabilizer.update(
            peopleMeasurement([person(x: 0.23, y: 0.21)]),
            generation: 8
        )

        XCTAssertEqual(first.people.first?.id, second.people.first?.id)
        XCTAssertEqual(first.people.first?.continuityID, second.people.first?.continuityID)
    }

    func testExpiredTrackDoesNotBecomeANewPersonsIdentity() {
        var stabilizer = MeasurementStabilizer()
        let first = stabilizer.update(peopleMeasurement([person(x: 0.2, y: 0.2)]), generation: 3)
        for timestamp in 2...5 {
            _ = stabilizer.update(peopleMeasurement([], timestamp: TimeInterval(timestamp)), generation: 3)
        }
        let replacement = stabilizer.update(
            peopleMeasurement([person(x: 0.2, y: 0.2, timestamp: 6)], timestamp: 6),
            generation: 3
        )
        let newGeneration = stabilizer.update(
            peopleMeasurement([person(x: 0.2, y: 0.2, timestamp: 7)], timestamp: 7),
            generation: 4
        )

        XCTAssertNotEqual(first.people.first?.id, replacement.people.first?.id)
        XCTAssertNotEqual(replacement.people.first?.id, newGeneration.people.first?.id)
    }

    func testSelectedSubjectIdentitySurvivesRefreshWhenItsTrackMatches() {
        var stabilizer = MeasurementStabilizer()
        let first = stabilizer.update(
            peopleMeasurement([person(x: 0.12, y: 0.2), person(x: 0.58, y: 0.2)]),
            generation: 2
        )
        let selected = try! XCTUnwrap(first.people.last?.id)
        var next = peopleMeasurement(
            [person(x: 0.15, y: 0.2), person(x: 0.61, y: 0.2)],
            timestamp: 2
        )
        next.selectedSubjectID = selected
        let refreshed = stabilizer.update(next, generation: 2)

        XCTAssertEqual(refreshed.selectedSubjectID, selected)
        XCTAssertEqual(refreshed.selectedPerson?.id, selected)
    }

    func testAmbiguousTrackMatchCreatesNoArbitraryMatch() {
        var stabilizer = MeasurementStabilizer()
        let first = stabilizer.update(
            peopleMeasurement([person(x: 0.20, y: 0.2), person(x: 0.40, y: 0.2)]),
            generation: 12
        )
        let ambiguous = stabilizer.update(
            peopleMeasurement([person(x: 0.30, y: 0.2, timestamp: 2)], timestamp: 2),
            generation: 12
        )

        XCTAssertFalse(first.people.contains { $0.id == ambiguous.people.first?.id })
    }

    func testTrackMatchingDoesNotUseUUIDLexicalOrderToBreakTies() {
        var stabilizer = MeasurementStabilizer()
        let left = PersonGeometry(
            id: SubjectTrackID(generation: 0, value: UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!),
            humanRect: CGRect(x: 0.20, y: 0.2, width: 0.20, height: 0.45)
        )
        let right = PersonGeometry(
            id: SubjectTrackID(generation: 0, value: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!),
            humanRect: CGRect(x: 0.40, y: 0.2, width: 0.20, height: 0.45)
        )
        let first = stabilizer.update(peopleMeasurement([left, right]), generation: 13)
        let ambiguous = stabilizer.update(
            peopleMeasurement([person(x: 0.30, y: 0.2)], timestamp: 2),
            generation: 13
        )

        XCTAssertFalse(first.people.contains { $0.id == ambiguous.people.first?.id })
    }

    func testMissingSelectedSubjectRemainsMissingRatherThanRebindingToANeighbor() {
        let selected = SubjectTrackID(generation: 14)
        let neighbor = person(x: 0.58, y: 0.2)
        let measurement = peopleMeasurement([neighbor])
        var engine = GuidanceEngine()

        let presentation = engine.update(
            measurement,
            intent: .people,
            generation: 14,
            selectedSubjectID: selected
        )

        XCTAssertEqual(presentation?.sessionState, .selectingSubject)
        XCTAssertNil(presentation?.subjectRect)
        XCTAssertEqual(engine.state, .selectingSubject)
    }

    func testAutomaticSinglePersonReplacementInvalidatesReducerContext() {
        var engine = GuidanceEngine()
        let first = peopleMeasurement([person(x: 0.05, y: 0.2)])
        let second = peopleMeasurement([person(x: 0.70, y: 0.2)], timestamp: 2)

        XCTAssertEqual(engine.update(first, intent: .people, generation: 15)?.step, .move(.left))
        XCTAssertEqual(engine.update(second, intent: .people, generation: 15)?.step, .move(.right))
    }

    func testCoupleAndGroupMembershipChangesInvalidateReducerContext() {
        var engine = GuidanceEngine()
        let couple = peopleMeasurement([person(x: 0.20, y: 0.2), person(x: 0.55, y: 0.2)])
        let changedCouple = peopleMeasurement([person(x: 0.20, y: 0.2), person(x: 0.65, y: 0.2)], timestamp: 2)
        let group = peopleMeasurement([person(x: 0.20, y: 0.2), person(x: 0.42, y: 0.2), person(x: 0.65, y: 0.2)], timestamp: 3)

        _ = engine.update(couple, intent: .people, generation: 16)
        XCTAssertEqual(engine.update(changedCouple, intent: .people, generation: 16)?.subjectKind, .couple)
        XCTAssertEqual(engine.update(group, intent: .people, generation: 16)?.subjectKind, .smallGroup)
    }

    func testSemanticTargetIsRejectedAfterGenerationChanges() {
        var engine = GuidanceEngine()
        let measurement = peopleMeasurement([person(x: 0.2, y: 0.2)])
        let semantic = SemanticGuidanceTarget(
            targetFrame: CGRect(x: 0.60, y: 0.2, width: 0.2, height: 0.4),
            instruction: "Unrelated cloud copy",
            generation: 17,
            intent: .people,
            subjectIDs: measurement.people.map(\.id)
        )

        XCTAssertEqual(
            engine.update(measurement, intent: .people, generation: 17, semanticTarget: semantic)?.targetRect,
            semantic.targetFrame
        )
        XCTAssertNil(engine.update(measurement, intent: .people, generation: 18, semanticTarget: semantic)?.targetRect)
    }

    func testSemanticTargetCannotResurrectAfterAnIncompatibleSubjectContext() {
        var engine = GuidanceEngine()
        let subjectA = peopleMeasurement([person(x: 0.20, y: 0.2)])
        let subjectB = peopleMeasurement([person(x: 0.68, y: 0.2)], timestamp: 2)
        let targetForA = SemanticGuidanceTarget(
            targetFrame: CGRect(x: 0.60, y: 0.2, width: 0.2, height: 0.4),
            generation: 17,
            intent: .people,
            subjectIDs: subjectA.people.map(\.id)
        )

        XCTAssertEqual(
            engine.update(subjectA, intent: .people, generation: 17, semanticTarget: targetForA)?.targetRect,
            targetForA.targetFrame
        )
        XCTAssertNil(engine.update(subjectB, intent: .people, generation: 17, semanticTarget: targetForA)?.targetRect)
        XCTAssertNil(engine.update(subjectA, intent: .people, generation: 17, semanticTarget: targetForA)?.targetRect)
    }

    func testAutomaticReplacementAfterDetectorGapStartsAFreshReducerContext() {
        var stabilizer = MeasurementStabilizer()
        var engine = GuidanceEngine()
        let first = stabilizer.update(
            peopleMeasurement([person(x: 0.04, y: 0.2)]),
            generation: 18
        )
        let semantic = SemanticGuidanceTarget(
            targetFrame: CGRect(x: 0.60, y: 0.2, width: 0.2, height: 0.4),
            generation: 18,
            intent: .people,
            subjectIDs: first.people.map(\.id)
        )
        XCTAssertEqual(
            engine.update(first, intent: .people, generation: 18, semanticTarget: semantic)?.targetRect,
            semantic.targetFrame
        )

        _ = stabilizer.update(peopleMeasurement([], timestamp: 2), generation: 18)
        let replacement = stabilizer.update(
            peopleMeasurement([person(x: 0.08, y: 0.2)], timestamp: 3),
            generation: 18
        )

        XCTAssertEqual(first.people.first?.id, replacement.people.first?.id)
        XCTAssertNotEqual(first.people.first?.continuityID, replacement.people.first?.continuityID)
        let presentation = engine.update(replacement, intent: .people, generation: 18, semanticTarget: semantic)
        XCTAssertEqual(presentation?.step, .move(.left))
        XCTAssertNil(presentation?.targetRect)
    }

    func testGroupSemanticIdentityIgnoresInputAndUUIDOrdering() {
        let left = PersonGeometry(
            id: SubjectTrackID(generation: 19, value: UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!),
            humanRect: CGRect(x: 0.30, y: 0.20, width: 0.20, height: 0.40)
        )
        let right = PersonGeometry(
            id: SubjectTrackID(generation: 19, value: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!),
            humanRect: CGRect(x: 0.30, y: 0.20, width: 0.20, height: 0.40)
        )
        let forward = peopleMeasurement([left, right])
        let reversed = peopleMeasurement([right, left], timestamp: 2)
        let target = SemanticGuidanceTarget(
            targetFrame: CGRect(x: 0.60, y: 0.2, width: 0.2, height: 0.4),
            generation: 19,
            intent: .people,
            subjectIDs: [left.id, right.id]
        )
        var engine = GuidanceEngine()

        XCTAssertEqual(forward.group?.semanticMemberIDs, reversed.group?.semanticMemberIDs)
        XCTAssertEqual(
            target,
            SemanticGuidanceTarget(
                targetFrame: target.targetFrame,
                generation: 19,
                intent: .people,
                subjectIDs: [right.id, left.id]
            )
        )
        XCTAssertEqual(engine.update(forward, intent: .people, generation: 19, semanticTarget: target)?.targetRect, target.targetFrame)
        XCTAssertEqual(engine.update(reversed, intent: .people, generation: 19, semanticTarget: target)?.targetRect, target.targetFrame)
    }

    func testGroupMembershipChangeInvalidatesSemanticTargetContext() {
        let first = peopleMeasurement([person(x: 0.20, y: 0.2), person(x: 0.55, y: 0.2)])
        let changed = peopleMeasurement([first.people[0], person(x: 0.55, y: 0.2)], timestamp: 2)
        let target = SemanticGuidanceTarget(
            targetFrame: CGRect(x: 0.60, y: 0.2, width: 0.2, height: 0.4),
            generation: 20,
            intent: .people,
            subjectIDs: first.people.map(\.id)
        )
        var engine = GuidanceEngine()

        XCTAssertEqual(engine.update(first, intent: .people, generation: 20, semanticTarget: target)?.targetRect, target.targetFrame)
        XCTAssertNil(engine.update(changed, intent: .people, generation: 20, semanticTarget: target)?.targetRect)
        XCTAssertNil(engine.update(first, intent: .people, generation: 20, semanticTarget: target)?.targetRect)
    }

    func testFaceAndPoseAssociationAreOneToOneAndRejectWeakMatches() {
        let people = [
            CGRect(x: 0.10, y: 0.10, width: 0.30, height: 0.60),
            CGRect(x: 0.32, y: 0.10, width: 0.30, height: 0.60),
        ]
        let faces = [CGRect(x: 0.30, y: 0.18, width: 0.12, height: 0.16)]
        let poses = [[
            PoseJoint(kind: .leftShoulder, point: CGPoint(x: 0.18, y: 0.50), confidence: 0.9),
            PoseJoint(kind: .rightShoulder, point: CGPoint(x: 0.22, y: 0.50), confidence: 0.9),
        ]]

        XCTAssertEqual(OnDeviceAnalyzer.associateFaces(faces, to: people).count, 0)
        XCTAssertEqual(OnDeviceAnalyzer.associatePoses(poses, to: people).count, 1)
        XCTAssertTrue(OnDeviceAnalyzer.associateFaces([CGRect(x: 0.90, y: 0.90, width: 0.05, height: 0.05)], to: people).isEmpty)
        XCTAssertTrue(OnDeviceAnalyzer.associatePoses([[PoseJoint(kind: .leftHip, point: CGPoint(x: 0.95, y: 0.95), confidence: 0.9)]], to: people).isEmpty)
    }

    func testAssociationRequiresAbsoluteEvidenceAndNeverReusesAnOwner() {
        let people = [
            CGRect(x: 0.10, y: 0.10, width: 0.30, height: 0.60),
            CGRect(x: 0.55, y: 0.10, width: 0.30, height: 0.60),
        ]
        let containedFace = CGRect(x: 0.17, y: 0.18, width: 0.10, height: 0.14)
        let tinyOverlap = CGRect(x: 0.395, y: 0.20, width: 0.04, height: 0.08)
        let distantFace = CGRect(x: 0.90, y: 0.90, width: 0.04, height: 0.04)
        let twoFacesForOnePerson = [
            CGRect(x: 0.17, y: 0.18, width: 0.10, height: 0.14),
            CGRect(x: 0.22, y: 0.22, width: 0.10, height: 0.14),
        ]
        let lowConfidencePose = [[
            PoseJoint(kind: .leftShoulder, point: CGPoint(x: 0.18, y: 0.50), confidence: 0.10),
            PoseJoint(kind: .rightShoulder, point: CGPoint(x: 0.22, y: 0.50), confidence: 0.10),
        ]]

        XCTAssertEqual(OnDeviceAnalyzer.associateFaces([containedFace], to: people), [0: 0])
        XCTAssertTrue(OnDeviceAnalyzer.associateFaces([tinyOverlap], to: people).isEmpty)
        XCTAssertTrue(OnDeviceAnalyzer.associateFaces([distantFace], to: people).isEmpty)
        XCTAssertTrue(OnDeviceAnalyzer.associatePoses(lowConfidencePose, to: people).isEmpty)
        XCTAssertLessThanOrEqual(OnDeviceAnalyzer.associateFaces(twoFacesForOnePerson, to: people).count, 1)
    }

    func testGroupEnvelopeIncludesEveryMemberWhenInputIsReversed() throws {
        let left = person(x: 0.05, y: 0.2, width: 0.20, height: 0.40)
        let right = person(x: 0.65, y: 0.25, width: 0.20, height: 0.40)
        let group = try XCTUnwrap(GroupGeometry(people: [right, left]))

        XCTAssertEqual(group.envelope, left.humanRect.union(right.humanRect))
        XCTAssertEqual(group.memberIDs.count, 2)
    }

    func testLocalFallbackUsesDistinctOnePersonCoupleAndSmallGroupPaths() {
        var engine = GuidanceEngine()
        let one = peopleMeasurement([person(x: 0.4, y: 0.2, width: 0.1, height: 0.2)])
        XCTAssertEqual(
            engine.update(one, intent: .people, generation: 1)?.step,
            .scale(.closer)
        )

        engine.reset()
        let couple = peopleMeasurement([
            person(x: 0.30, y: 0.2, width: 0.22, height: 0.45),
            person(x: 0.44, y: 0.2, width: 0.22, height: 0.45),
        ])
        XCTAssertEqual(engine.update(couple, intent: .people, generation: 1)?.step, .spacing)
        XCTAssertEqual(engine.currentPresentation?.subjectKind, .couple)

        engine.reset()
        let group = peopleMeasurement([
            person(x: 0.22, y: 0.2, width: 0.18, height: 0.40),
            person(x: 0.34, y: 0.2, width: 0.18, height: 0.40),
            person(x: 0.46, y: 0.2, width: 0.18, height: 0.40),
        ])
        XCTAssertEqual(engine.update(group, intent: .people, generation: 1)?.step, .spacing)
        XCTAssertEqual(engine.currentPresentation?.subjectKind, .smallGroup)
    }

    func testCoupleAndSmallGroupUseDistinctMeasuredReasoning() {
        var engine = GuidanceEngine()
        var secondPerson = person(x: 0.52, y: 0.2, width: 0.20, height: 0.45)
        secondPerson.faceRect = nil
        secondPerson.faceVisible = false
        let couple = peopleMeasurement([
            person(x: 0.26, y: 0.2, width: 0.20, height: 0.45),
            secondPerson,
        ])
        let group = peopleMeasurement([
            person(x: 0.10, y: 0.2, width: 0.14, height: 0.30),
            person(x: 0.42, y: 0.2, width: 0.14, height: 0.30),
            person(x: 0.74, y: 0.2, width: 0.14, height: 0.30),
        ], timestamp: 2)

        XCTAssertEqual(engine.update(couple, intent: .people, generation: 19)?.step, .gaze)
        engine.reset()
        XCTAssertEqual(engine.update(group, intent: .people, generation: 19)?.step, .spacing)
    }

    func testSceneFallbackPrefersHorizonWithoutPeople() {
        var engine = GuidanceEngine()
        let scene = SceneMeasurement(
            salientRect: CGRect(x: 0.25, y: 0.2, width: 0.3, height: 0.4),
            horizonAngle: 0.12,
            exposure: 0.5,
            timestamp: 1
        )

        XCTAssertEqual(engine.update(scene, intent: .scene, generation: 1)?.step, .horizon)
    }

    func testIntentAndGenerationChangesInvalidateStaleGuidanceProgress() {
        var engine = GuidanceEngine()
        let people = peopleMeasurement([person(x: 0.05, y: 0.2, width: 0.2, height: 0.45)])
        XCTAssertEqual(engine.update(people, intent: .people, generation: 1)?.step, .move(.left))

        let scene = SceneMeasurement(
            salientRect: CGRect(x: 0.4, y: 0.2, width: 0.2, height: 0.3),
            exposure: 0.5,
            timestamp: 2
        )
        let changedIntent = engine.update(scene, intent: .scene, generation: 1)
        XCTAssertEqual(changedIntent?.intent, .scene)
        XCTAssertNotEqual(changedIntent?.step, .move(.left))

        let changedGeneration = engine.update(people, intent: .people, generation: 2)
        XCTAssertEqual(changedGeneration?.generation, 2)
        XCTAssertEqual(changedGeneration?.step, .move(.left))
    }

    func testReducerPublishesOnePresentationSkipsSatisfiedStepsAndLocks() {
        var engine = GuidanceEngine()
        let aligned = peopleMeasurement([person(x: 0.225, y: 0.25, width: 0.55, height: 0.45)])
        let presentation = engine.update(aligned, intent: .people, generation: 1)

        XCTAssertEqual(presentation?.step, .hold)
        XCTAssertEqual(engine.state, .locked)
        XCTAssertEqual(engine.currentPresentation, presentation)
    }

    func testSemanticCopyCannotOverrideTheReducerOwnedActiveStep() {
        var engine = GuidanceEngine()
        let horizon = SceneMeasurement(
            salientRect: CGRect(x: 0.25, y: 0.2, width: 0.3, height: 0.4),
            horizonAngle: 0.12,
            exposure: 0.5,
            timestamp: 1
        )
        let semantic = SemanticGuidanceTarget(
            instruction: "Move left",
            generation: 20,
            intent: .scene
        )

        let presentation = engine.update(horizon, intent: .scene, generation: 20, semanticTarget: semantic)

        XCTAssertEqual(presentation?.step, .horizon)
        XCTAssertNotEqual(presentation?.instruction, "Move left")
        XCTAssertEqual(presentation?.instructionKey, "guidance.level")
    }

    func testGuidanceSessionStateTransitionsRemainObservableAndRecoverExplicitly() {
        var engine = GuidanceEngine()
        let left = peopleMeasurement([person(x: 0.04, y: 0.2, width: 0.2, height: 0.45)])
        let aligned = peopleMeasurement([person(x: 0.225, y: 0.2, width: 0.55, height: 0.45)], timestamp: 2)

        engine.beginAnalysis()
        XCTAssertEqual(engine.state, .analyzing)
        XCTAssertNil(engine.currentPresentation)
        XCTAssertEqual(engine.update(left, intent: .people, generation: 21)?.step, .move(.left))
        XCTAssertEqual(engine.state, .guiding(.move(.left)))
        XCTAssertEqual(engine.update(aligned, intent: .people, generation: 21)?.step, .hold)
        XCTAssertEqual(engine.state, .locked)
        engine.beginCapture()
        XCTAssertEqual(engine.state, .capturing)
        engine.completeCapture()
        XCTAssertEqual(engine.state, .ready)
        engine.beginCapture()
        engine.completeCapture(recoverableFailure: true)
        XCTAssertEqual(engine.state, .failedRecoverable)
        XCTAssertNil(engine.update(left, intent: .people, generation: 21))
        XCTAssertEqual(engine.state, .failedRecoverable)
        engine.recover()
        XCTAssertEqual(engine.state, .ready)
    }

    @MainActor
    func testCameraSessionPublishesGuidanceLifecycleAndExplicitRecovery() async throws {
        let camera = CameraSession()
        let left = peopleMeasurement([person(x: 0.04, y: 0.2)], timestamp: 1)

        camera.beginGuidanceAnalysis()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(camera.guidanceSessionState, .analyzing)

        camera.debugAnalyzeGuidanceForTesting(left)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(camera.guidanceSessionState, .guiding(.move(.left)))

        for timestamp in 2...8 {
            camera.debugAnalyzeGuidanceForTesting(
                peopleMeasurement([person(x: 0.225, y: 0.2, width: 0.55, height: 0.45)], timestamp: TimeInterval(timestamp))
            )
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(camera.guidanceSessionState, .locked)

        camera.debugBeginGuidanceCaptureForTesting()
        camera.debugRegisterPendingCaptureForTesting(id: 801)
        camera.debugClaimPendingCaptureForTesting(id: 801)
        camera.debugBeginSavingForTesting(id: 801)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(camera.guidanceSessionState, .capturing)

        camera.debugCompletePhotoKitSaveForTesting(id: 801, saved: true)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(camera.guidanceSessionState, .ready)

        camera.debugBeginGuidanceCaptureForTesting()
        camera.debugRegisterPendingCaptureForTesting(id: 802)
        camera.debugClaimPendingCaptureForTesting(id: 802)
        camera.debugBeginSavingForTesting(id: 802)
        camera.debugCompletePhotoKitSaveForTesting(id: 802, saved: false)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(camera.guidanceSessionState, .failedRecoverable)

        camera.recoverGuidance()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(camera.guidanceSessionState, .analyzing)
    }

    @MainActor
    func testCameraViewConsumesGuidanceLifecycleState() {
        XCTAssertEqual(CameraView.guidanceControlState(for: .analyzing), .analyzing)
        XCTAssertEqual(CameraView.guidanceControlState(for: .capturing), .capturing)
        XCTAssertEqual(CameraView.guidanceControlState(for: .failedRecoverable), .recovery)
        XCTAssertEqual(CameraView.guidanceControlState(for: .guiding(.move(.left))), .hidden)
    }

    @MainActor
    func testNoticeClearOwnsOnlyTheVersionThatScheduledIt() async throws {
        let camera = CameraSession()

        camera.debugPublishNoticeForTesting("notice.A")
        try await Task.sleep(for: .milliseconds(25))
        let noticeA = camera.debugActiveNoticeTokenForTesting
        XCTAssertNotNil(noticeA)

        camera.debugPublishNoticeForTesting("notice.B")
        try await Task.sleep(for: .milliseconds(25))
        XCTAssertEqual(camera.notice, "notice.B")

        camera.debugClearNoticeForTesting(noticeA)
        try await Task.sleep(for: .milliseconds(25))
        XCTAssertEqual(camera.notice, "notice.B")
    }

    @MainActor
    func testRecoveryRetiresItsActiveCaptureFailureNoticeBeforeAnalysis() async throws {
        let camera = CameraSession()
        camera.debugBeginGuidanceCaptureForTesting()
        camera.debugRegisterPendingCaptureForTesting(id: 1_001)
        camera.debugClaimPendingCaptureForTesting(id: 1_001)
        camera.debugBeginSavingForTesting(id: 1_001)
        camera.debugCompletePhotoKitSaveForTesting(id: 1_001, saved: false)
        try await Task.sleep(for: .milliseconds(50))

        camera.debugPublishNoticeForTesting("camera.error.capture", recoverableFailure: true)
        try await Task.sleep(for: .milliseconds(25))
        XCTAssertEqual(camera.guidanceSessionState, .failedRecoverable)
        XCTAssertEqual(camera.notice, "camera.error.capture")

        camera.recoverGuidance()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(camera.guidanceSessionState, .analyzing)
        XCTAssertNil(camera.notice)
    }

    @MainActor
    func testMissingDeferredProxyPublishesOneTerminalNotice() async throws {
        let camera = CameraSession()
        camera.debugRegisterPendingCaptureForTesting(id: 1_002)

        camera.debugHandleMissingDeferredProxyForTesting()
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(camera.notice, "camera.error.capture")
        XCTAssertEqual(camera.debugNoticePublicationCount, 1)
    }

    func testTerminalEffectClaimRejectsASecondClaimForTheSameCapture() {
        let camera = CameraSession()

        XCTAssertTrue(camera.debugClaimTerminalEffectForTesting(id: 1_003))
        XCTAssertFalse(camera.debugClaimTerminalEffectForTesting(id: 1_003))
    }

    @MainActor
    func testCaptureNStaleNoticeClearAndTerminalEffectCannotMutateCaptureNPlusOne() async throws {
        let camera = CameraSession()
        camera.debugBeginGuidanceCaptureForTesting()
        camera.debugRegisterPendingCaptureForTesting(id: 1_004)
        camera.debugClaimPendingCaptureForTesting(id: 1_004)
        camera.debugBeginSavingForTesting(id: 1_004)
        camera.debugCompletePhotoKitSaveForTesting(id: 1_004, saved: false)
        try await Task.sleep(for: .milliseconds(50))

        camera.debugPublishNoticeForTesting("capture.N", recoverableFailure: true)
        try await Task.sleep(for: .milliseconds(25))
        let captureNNotice = camera.debugActiveNoticeTokenForTesting

        camera.debugBeginGuidanceCaptureForTesting()
        camera.debugRegisterPendingCaptureForTesting(id: 1_005)
        camera.debugPublishNoticeForTesting("capture.N+1")
        camera.debugClearNoticeForTesting(captureNNotice)
        camera.debugFinishCaptureForTesting(id: 1_004, recoverableFailure: true)
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(camera.guidanceSessionState, .capturing)
        XCTAssertTrue(camera.isCapturing)
        XCTAssertEqual(camera.notice, "capture.N+1")
        XCTAssertEqual(camera.debugCaptureTerminalEffectCount, 1)
    }

    @MainActor
    func testCameraAssistPresentationSuppressesStaleAIForLifecycleStates() {
        let response = makeAIResponse()
        let guidance = Guidance(
            subjectRect: CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.4),
            target: CGPoint(x: 0.5, y: 0.5),
            direction: .left,
            instructionKey: "guidance.left",
            aligned: false
        )

        XCTAssertEqual(
            CameraView.assistPresentation(
                for: .failedRecoverable,
                guidance: guidance,
                aiState: .ready(response, selected: 0)
            ),
            .recovery
        )
        XCTAssertEqual(
            CameraView.assistPresentation(for: .analyzing, guidance: guidance, aiState: .failed(.offline)),
            .analyzing
        )
        XCTAssertEqual(
            CameraView.assistPresentation(for: .capturing, guidance: guidance, aiState: .loading),
            .capturing
        )
        XCTAssertEqual(
            CameraView.assistPresentation(
                for: .guiding(.move(.left)),
                guidance: guidance,
                aiState: .ready(response, selected: 0)
            ),
            .guidance
        )
        XCTAssertEqual(
            CameraView.assistPresentation(for: .locked, guidance: guidance, aiState: .failed(.server)),
            .guidance
        )
    }

    @MainActor
    func testRecoverableCaptureNoticeUsesOnlyTheAssistRecoverySurface() {
        let response = makeAIResponse()

        XCTAssertEqual(
            CameraView.assistPresentation(
                for: .failedRecoverable,
                guidance: nil,
                aiState: .ready(response, selected: 0)
            ),
            .recovery
        )
        XCTAssertEqual(
            CameraView.assistPresentation(
                for: .failedRecoverable,
                guidance: nil,
                aiState: .failed(.offline)
            ),
            .recovery
        )
        XCTAssertEqual(
            CameraView.assistPresentation(
                for: .failedRecoverable,
                guidance: nil,
                aiState: .loading
            ),
            .recovery
        )
        XCTAssertFalse(
            CameraView.showsStandaloneNotice(
                for: .failedRecoverable,
                isRecoverableFailureNotice: true
            )
        )
        XCTAssertTrue(
            CameraView.showsStandaloneNotice(
                for: .failedRecoverable,
                isRecoverableFailureNotice: false
            )
        )
    }

    @MainActor
    func testRecoveryRetiresCloudPlanBeforeFreshGuidanceUpdate() async throws {
        let camera = CameraSession()
        let stalePlan = SemanticGuidanceTarget(
            targetFrame: CGRect(x: 0.60, y: 0.2, width: 0.2, height: 0.4),
            instruction: "Stale cloud instruction",
            generation: camera.analysisGeneration,
            intent: .people,
            subjectIDs: []
        )
        let freshMeasurement = peopleMeasurement([person(x: 0.04, y: 0.2)], timestamp: 1)

        camera.debugBeginGuidanceCaptureForTesting()
        camera.debugRegisterPendingCaptureForTesting(id: 2_001)
        camera.debugClaimPendingCaptureForTesting(id: 2_001)
        camera.debugBeginSavingForTesting(id: 2_001)
        camera.debugCompletePhotoKitSaveForTesting(id: 2_001, saved: false)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(camera.guidanceSessionState, .failedRecoverable)

        camera.debugSeedCloudPlanForTesting(stalePlan)
        try await Task.sleep(for: .milliseconds(25))
        XCTAssertEqual(camera.debugCloudPlanForTesting, stalePlan)

        camera.recoverGuidance()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(camera.guidanceSessionState, .analyzing)
        XCTAssertNil(camera.debugCloudPlanForTesting)

        // A late response from the retired cloud cycle has no authority to
        // reinstall semantic guidance before a new explicit analysis request.
        camera.debugSeedGuidanceForTesting(measurement: freshMeasurement, guidance: nil)
        camera.applyAIPlan(makeAIResponse().plans[0])
        try await Task.sleep(for: .milliseconds(25))
        XCTAssertNil(camera.debugCloudPlanForTesting)

        camera.debugAnalyzeGuidanceForTesting(freshMeasurement)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(camera.debugSemanticTargetUsedForLatestGuidanceUpdate)
    }

    @MainActor
    func testUnknownCaptureCallbackCannotPublishOverCurrentCaptureNotice() async throws {
        let camera = CameraSession()
        camera.debugBeginGuidanceCaptureForTesting()
        camera.debugRegisterPendingCaptureForTesting(id: 2_002)
        try await Task.sleep(for: .milliseconds(25))
        camera.debugPublishNoticeForTesting("capture.N+1")
        try await Task.sleep(for: .milliseconds(25))

        let currentGuidanceState = camera.guidanceSessionState
        XCTAssertFalse(camera.debugHandleCaptureCallbackForTesting(id: 2_001))
        try await Task.sleep(for: .milliseconds(25))

        XCTAssertEqual(camera.guidanceSessionState, currentGuidanceState)
        XCTAssertTrue(camera.isCapturing)
        XCTAssertEqual(camera.notice, "capture.N+1")
        XCTAssertEqual(camera.debugNoticePublicationCount, 1)
    }

    @MainActor
    func testStaleCaptureNCallbackCannotOverwriteCaptureNPlusOne() async throws {
        let camera = CameraSession()

        camera.debugBeginGuidanceCaptureForTesting()
        camera.debugRegisterPendingCaptureForTesting(id: 2_003)
        camera.debugClaimPendingCaptureForTesting(id: 2_003)
        camera.debugBeginSavingForTesting(id: 2_003)
        camera.debugCompletePhotoKitSaveForTesting(id: 2_003, saved: false)
        try await Task.sleep(for: .milliseconds(50))

        camera.debugBeginGuidanceCaptureForTesting()
        camera.debugRegisterPendingCaptureForTesting(id: 2_004)
        camera.debugPublishNoticeForTesting("capture.N+1")
        try await Task.sleep(for: .milliseconds(25))

        XCTAssertFalse(camera.debugHandleCaptureCallbackForTesting(id: 2_003))
        try await Task.sleep(for: .milliseconds(25))

        XCTAssertEqual(camera.guidanceSessionState, .capturing)
        XCTAssertTrue(camera.isCapturing)
        XCTAssertEqual(camera.notice, "capture.N+1")
        XCTAssertEqual(camera.debugNoticePublicationCount, 1)
    }

    @MainActor
    func testProcessingInterruptionMakesStaleSaveContinuationHarmless() async throws {
        let camera = CameraSession()
        camera.debugBeginGuidanceCaptureForTesting()
        camera.debugRegisterPendingCaptureForTesting(id: 901)
        camera.debugClaimPendingCaptureForTesting(id: 901)
        try await Task.sleep(for: .milliseconds(50))

        NotificationCenter.default.post(
            name: AVCaptureSession.wasInterruptedNotification,
            object: camera.session
        )
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(camera.guidanceSessionState, .failedRecoverable)
        XCTAssertEqual(camera.debugCaptureTerminalEffectCount, 1)
        XCTAssertFalse(camera.debugAttemptBeginSavingForTesting(id: 901))
        XCTAssertEqual(camera.debugCaptureTerminalEffectCount, 1)

        camera.debugBeginGuidanceCaptureForTesting()
        camera.debugRegisterPendingCaptureForTesting(id: 902)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(camera.guidanceSessionState, .capturing)
        XCTAssertTrue(camera.isCapturing)
        camera.debugPublishNoticeForTesting("camera.saved")
        XCTAssertFalse(camera.debugAttemptBeginSavingForTesting(id: 901))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(camera.guidanceSessionState, .capturing)
        XCTAssertTrue(camera.isCapturing)
        XCTAssertEqual(camera.notice, "camera.saved")
        XCTAssertEqual(camera.debugCaptureTerminalEffectCount, 1)
    }

    @MainActor
    func testCameraSessionInvalidatesSelectionAndCancelsOnlyPreSaveOnInterruption() async throws {
        let camera = CameraSession()
        let personA = peopleMeasurement([person(x: 0.20, y: 0.2)], timestamp: 1)
        let personB = peopleMeasurement([person(x: 0.22, y: 0.2)], timestamp: 3)

        camera.debugAnalyzeGuidanceForTesting(personA)
        try await Task.sleep(for: .milliseconds(50))
        camera.selectSubject(at: CGPoint(x: 0.30, y: 0.50))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNotNil(camera.measurement?.selectedSubjectID)
        let firstSelection = camera.measurement?.selectedPerson?.continuityID

        camera.debugAnalyzeGuidanceForTesting(peopleMeasurement([], timestamp: 2))
        camera.debugAnalyzeGuidanceForTesting(personB)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertNil(camera.measurement?.selectedSubjectID)

        camera.selectSubject(at: CGPoint(x: 0.32, y: 0.50))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNotNil(camera.measurement?.selectedSubjectID)
        XCTAssertNotEqual(firstSelection, camera.measurement?.selectedPerson?.continuityID)

        camera.debugBeginGuidanceCaptureForTesting()
        camera.debugRegisterPendingCaptureForTesting(id: 811)
        camera.debugRegisterPendingCaptureForTesting(id: 812)
        camera.debugClaimPendingCaptureForTesting(id: 812)
        camera.debugRegisterPendingCaptureForTesting(id: 813)
        camera.debugClaimPendingCaptureForTesting(id: 813)
        camera.debugBeginSavingForTesting(id: 813)

        NotificationCenter.default.post(
            name: AVCaptureSession.wasInterruptedNotification,
            object: camera.session
        )
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(camera.debugPendingCaptureCount, 1)
        XCTAssertEqual(camera.guidanceSessionState, .capturing)
        camera.debugCompletePhotoKitSaveForTesting(id: 813, saved: true)
    }

    @MainActor
    func testSelectedSubjectDoesNotReturnAfterDetectorGapWithoutReselection() async throws {
        let camera = CameraSession()
        let personA = peopleMeasurement([person(x: 0.20, y: 0.2)], timestamp: 1)

        camera.debugAnalyzeGuidanceForTesting(personA)
        try await Task.sleep(for: .milliseconds(50))
        camera.selectSubject(at: CGPoint(x: 0.30, y: 0.50))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNotNil(camera.measurement?.selectedSubjectID)

        camera.debugAnalyzeGuidanceForTesting(peopleMeasurement([], timestamp: 2))
        camera.debugAnalyzeGuidanceForTesting(peopleMeasurement([person(x: 0.20, y: 0.2)], timestamp: 3))
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertNil(camera.measurement?.selectedSubjectID)
    }

    func testGuidanceHysteresisDoesNotFlapAndCanRelapseAfterLock() {
        var engine = GuidanceEngine()
        let left = peopleMeasurement([person(x: 0.04, y: 0.2, width: 0.2, height: 0.45)])
        XCTAssertEqual(engine.update(left, intent: .people, generation: 1)?.step, .move(.left))

        let noisy = peopleMeasurement([person(x: 0.10, y: 0.2, width: 0.2, height: 0.45)], timestamp: 2)
        XCTAssertEqual(engine.update(noisy, intent: .people, generation: 1)?.step, .move(.left))

        let aligned = peopleMeasurement([person(x: 0.225, y: 0.2, width: 0.55, height: 0.45)], timestamp: 3)
        XCTAssertEqual(engine.update(aligned, intent: .people, generation: 1)?.step, .hold)
        XCTAssertEqual(engine.state, .locked)

        let relapsed = peopleMeasurement([person(x: 0.70, y: 0.2, width: 0.2, height: 0.45)], timestamp: 4)
        XCTAssertEqual(engine.update(relapsed, intent: .people, generation: 1)?.step, .move(.right))
        XCTAssertEqual(engine.state, .guiding(.move(.right)))
    }

    func testManualShutterRemainsEligibleWhenFilterQuotaIsExhausted() {
        XCTAssertTrue(
            CameraSession.manualCaptureAllowed(
                state: .running,
                isCapturing: false,
                countdownActive: false,
                filterQuotaExhausted: true
            )
        )
        XCTAssertFalse(
            CameraSession.manualCaptureAllowed(
                state: .running,
                isCapturing: true,
                countdownActive: false,
                filterQuotaExhausted: true
            )
        )
    }

    func testAnalyzerDefersFullDetectionBetweenTrackedFrames() {
        XCTAssertTrue(
            OnDeviceAnalyzer.shouldDeferFullDetection(
                elapsed: 0.69,
                hasMeasurement: true,
                thermallyConstrained: false
            )
        )
        XCTAssertFalse(
            OnDeviceAnalyzer.shouldDeferFullDetection(
                elapsed: 0.7,
                hasMeasurement: true,
                thermallyConstrained: false
            )
        )
    }

    func testInstructionMovesBelowASubjectThatReachesTheTop() {
        let lowerGuidance = Guidance(
            subjectRect: CGRect(x: 0.3, y: 0.35, width: 0.3, height: 0.4),
            target: CGPoint(x: 0.5, y: 0.5),
            direction: .left,
            instructionKey: "guidance.left",
            aligned: false
        )
        XCTAssertTrue(GuidanceOverlay.instructionSitsHigh(lowerGuidance))

        let upperGuidance = Guidance(
            subjectRect: CGRect(x: 0.3, y: 0.02, width: 0.3, height: 0.6),
            target: CGPoint(x: 0.5, y: 0.5),
            direction: .left,
            instructionKey: "guidance.left",
            aligned: false
        )
        XCTAssertFalse(GuidanceOverlay.instructionSitsHigh(upperGuidance))

        let noSubjectGuidance = Guidance(
            subjectRect: nil,
            target: CGPoint(x: 0.5, y: 0.5),
            direction: .left,
            instructionKey: "guidance.left",
            aligned: false
        )
        XCTAssertTrue(GuidanceOverlay.instructionSitsHigh(noSubjectGuidance))
    }

    func testAimRingOnlyRepresentsTwoDimensionalMovement() {
        XCTAssertTrue(GuidanceDirection.up.usesAimRing)
        XCTAssertTrue(GuidanceDirection.none.usesAimRing)
        XCTAssertFalse(GuidanceDirection.closer.usesAimRing)
        XCTAssertFalse(GuidanceDirection.level.usesAimRing)
        XCTAssertTrue(GuidanceDirection.closer.usesTargetFrame)
        XCTAssertFalse(GuidanceDirection.up.usesTargetFrame)
    }

    @MainActor
    func testAIAnalysisKeepsThreePlansFromOneRequest() async {
        let response = makeAIResponse()
        let model = AIAnalysisModel { _, _ in response }

        model.analyze(Data([1]), measurement: nil)
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(model.state, .ready(response, selected: 0))
        XCTAssertEqual(model.select(2)?.id, "creative")
        XCTAssertEqual(model.state, .ready(response, selected: 2))
    }

    @MainActor
    func testAIAnalysisCancellationIgnoresLateFailure() async {
        let model = AIAnalysisModel { _, _ in
            try? await Task.sleep(for: .seconds(1))
            throw AIClientError.offline
        }

        model.analyze(Data([1]), measurement: nil)
        model.cancel()
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(model.state, .idle)
    }

    func testAIResponseRejectsOutOfRangeCameraChanges() {
        var response = makeAIResponse()
        response = AICompositionResponse(
            schemaVersion: response.schemaVersion,
            primary: makeAIPlan(id: "primary", zoom: 20),
            alternatives: response.alternatives
        )

        XCTAssertFalse(response.isValid)
        XCTAssertTrue(makeAIResponse().isValid)
    }

    func testAnalyticsUsesOnlyCoarseLatencyBuckets() {
        XCTAssertEqual(Analytics.latencyBucket(2.99), "under_3s")
        XCTAssertEqual(Analytics.latencyBucket(3), "3_to_8s")
        XCTAssertEqual(Analytics.latencyBucket(8), "over_8s")
    }

    func testAutoCaptureRequiresStableReadySubjectAndCancels() {
        var auto = AutoCapture()
        let subject = CGRect(x: 0.3, y: 0.2, width: 0.3, height: 0.5)

        XCTAssertFalse(
            auto.update(
                aligned: true,
                subject: subject,
                faceReady: true,
                timestamp: 1
            ))
        XCTAssertFalse(
            auto.update(
                aligned: true,
                subject: subject.offsetBy(dx: 0.04, dy: 0),
                faceReady: true,
                timestamp: 2
            ))
        XCTAssertTrue(
            auto.update(
                aligned: true,
                subject: subject.offsetBy(dx: 0.04, dy: 0),
                faceReady: true,
                timestamp: 3.3
            ))

        auto.cancel(now: 4)
        XCTAssertFalse(
            auto.update(
                aligned: true,
                subject: subject,
                faceReady: true,
                timestamp: 5
            ))
    }

    func testCloudPlanRemainsAlignedAgainstLiveMeasurements() {
        let guidance = CameraSession.cloudGuidance(
            makeAIPlan(id: "primary"),
            measurement: SceneMeasurement(
                subjectRect: CGRect(x: 0.2, y: 0.3, width: 0.3, height: 0.5),
                faceRects: [],
                salientRect: nil,
                horizonAngle: 0,
                exposure: 0.5,
                timestamp: 1
            )
        )

        XCTAssertTrue(guidance.aligned)
        XCTAssertEqual(guidance.target.x, 0.35, accuracy: 0.001)
        XCTAssertEqual(guidance.targetRect, CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.5))
    }

    @MainActor
    func testVoiceGuidanceThrottlesRepeatedAdvice() {
        let voice = VoiceGuidance()
        XCTAssertTrue(voice.shouldSpeak("Move left", now: 1))
        XCTAssertFalse(voice.shouldSpeak("Move left", now: 2))
        XCTAssertTrue(voice.shouldSpeak("Move left", now: 5))
    }

    @MainActor
    func testGuidanceEnabledDefaultsTrueAndPersistsExplicitFalse() {
        let suite = "FocelleTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertTrue(AppSettings(defaults: defaults).guidanceEnabled)

        let settings = AppSettings(defaults: defaults)
        settings.guidanceEnabled = false
        XCTAssertFalse(AppSettings(defaults: defaults).guidanceEnabled)
    }

    @MainActor
    func testTogglingUnrelatedSettingsDoesNotAffectGuidancePreference() {
        let suite = "FocelleTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)

        XCTAssertTrue(settings.guidanceEnabled)
        settings.onDeviceOnly = true
        settings.saveOriginal = true
        settings.saveLocation = true
        settings.analyticsEnabled = false
        settings.voiceGuidance = true
        settings.autoCapture = true
        settings.requestedResolution = .maximum
        XCTAssertTrue(settings.guidanceEnabled)

        // Simulates a Settings sheet round trip: a fresh AppSettings read from
        // the same defaults must still see the untouched guidance preference.
        XCTAssertTrue(AppSettings(defaults: defaults).guidanceEnabled)
    }

    func testStaleAnalysisGenerationIsRejectedCurrentIsAccepted() {
        XCTAssertFalse(
            CameraSession.shouldAcceptAnalysis(requestGeneration: 1, currentGeneration: 2)
        )
        XCTAssertTrue(
            CameraSession.shouldAcceptAnalysis(requestGeneration: 2, currentGeneration: 2)
        )
    }

    // Exercises the exact method CameraView's Settings sheet `onDismiss` calls,
    // not just the internal reset it forwards to.
    @MainActor
    func testSettingsDismissalRefreshClearsStaleStateAndAllowsNewAnalysis() async throws {
        let camera = CameraSession()
        let stale = SceneMeasurement(
            subjectRect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.3),
            faceRects: [],
            salientRect: nil,
            horizonAngle: 0,
            exposure: 0.5,
            timestamp: 1
        )
        camera.debugSeedGuidanceForTesting(
            measurement: stale,
            guidance: GuidanceEngine.propose(stale)
        )
        camera.analysisInFlight = true
        let priorGeneration = camera.analysisGeneration

        camera.refreshLocalGuidanceAfterSettings()
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertFalse(camera.analysisInFlight)
        XCTAssertGreaterThan(camera.analysisGeneration, priorGeneration)
        XCTAssertNil(camera.measurement)
        XCTAssertNil(camera.guidance)

        // A result carrying the now-current generation is still accepted, so
        // the very next frame's analysis can publish fresh guidance.
        XCTAssertTrue(camera.acceptAnalysisCompletion(requestGeneration: camera.analysisGeneration))
    }

    @MainActor
    func testRefreshLocalGuidanceAfterSettingsIsIdempotentAcrossRepeatedDismissals() async throws {
        let camera = CameraSession()
        let startGeneration = camera.analysisGeneration

        camera.refreshLocalGuidanceAfterSettings()
        camera.refreshLocalGuidanceAfterSettings()
        camera.refreshLocalGuidanceAfterSettings()
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertFalse(camera.analysisInFlight)
        XCTAssertGreaterThan(camera.analysisGeneration, startGeneration)
        XCTAssertNil(camera.measurement)
        XCTAssertNil(camera.guidance)
    }

    // A reset (e.g. a Settings dismissal) can land while an older request is
    // still processing off-queue. Its eventual stale completion must not
    // clear the in-flight flag a newer request now owns.
    func testStaleCompletionLeavesNewerInFlightRequestUntouched() {
        let camera = CameraSession()
        let requestAGeneration = camera.analysisGeneration
        camera.analysisInFlight = true

        camera.analysisGeneration += 1
        camera.analysisInFlight = false
        camera.analysisInFlight = true
        let requestBGeneration = camera.analysisGeneration

        XCTAssertFalse(camera.acceptAnalysisCompletion(requestGeneration: requestAGeneration))
        XCTAssertTrue(camera.analysisInFlight)

        XCTAssertTrue(camera.acceptAnalysisCompletion(requestGeneration: requestBGeneration))
        XCTAssertFalse(camera.analysisInFlight)
    }

    @MainActor
    func testSettingsPersistPrivacyAndCameraChoices() {
        let suite = "FocelleTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)

        settings.onDeviceOnly = true
        settings.analyticsEnabled = false
        settings.saveOriginal = true

        let restored = AppSettings(defaults: defaults)
        XCTAssertTrue(restored.onDeviceOnly)
        XCTAssertFalse(restored.analyticsEnabled)
        XCTAssertTrue(restored.saveOriginal)
    }

    @MainActor
    func testBetaAccessUsesOfflineCache() throws {
        let suite = "FocelleTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let cached = BetaAccess.Snapshot(
            enabled: false,
            activated: true,
            successfulAnalyses: 3,
            endsAt: Date(timeIntervalSince1970: 100),
            activatedUsers: 500
        )
        defaults.set(try JSONEncoder().encode(cached), forKey: "betaAccess")

        XCTAssertEqual(BetaAccess(defaults: defaults).snapshot, cached)
    }

    @MainActor
    func testQuotaUsesOfflineCache() throws {
        let suite = "FocelleTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let cached = Quota.Snapshot(
            unlimited: false,
            aiRemaining: 2,
            filterRemaining: 4,
            adsRemaining: 3,
            localDay: "2026-07-26"
        )
        defaults.set(try JSONEncoder().encode(cached), forKey: "quota")

        XCTAssertEqual(Quota(defaults: defaults).snapshot, cached)
    }

    @MainActor
    func testStoreEntitlementCacheExpiresWithoutKeepingPro() throws {
        let suite = "FocelleTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let active = Store.Entitlement(
            productID: Store.productIDs[0],
            expirationDate: Date(timeIntervalSince1970: 4_102_444_800)
        )
        defaults.set(try JSONEncoder().encode(active), forKey: "storeEntitlement")
        XCTAssertTrue(Store(defaults: defaults).isPro)

        let expired = Store.Entitlement(
            productID: Store.productIDs[0],
            expirationDate: Date(timeIntervalSince1970: 100)
        )
        defaults.set(try JSONEncoder().encode(expired), forKey: "storeEntitlement")
        XCTAssertFalse(Store(defaults: defaults).isPro)
    }

    func testEveryLocalizationHasVietnameseAndEnglish() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Focelle/App/Localizable.xcstrings")
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: source)) as? [String: Any]
        )
        let strings = try XCTUnwrap(object["strings"] as? [String: Any])

        for (key, value) in strings {
            let entry = try XCTUnwrap(value as? [String: Any], key)
            let localizations = try XCTUnwrap(
                entry["localizations"] as? [String: Any],
                key
            )
            XCTAssertNotNil(localizations["vi"], key)
            XCTAssertNotNil(localizations["en"], key)
        }
    }

    func testLanguageTagMatchesWhatTheBackendAccepts() {
        // Mirrors localePattern in backend/src/analyze.ts; a tag the worker
        // rejects would fail the whole request on arrival.
        let accepted = try? NSRegularExpression(pattern: "^[a-z]{2,3}(-[A-Za-z]{2,8})?$")
        for identifier in [
            "en_US", "vi_VN", "ja_JP", "ko_KR", "zh_Hans_CN", "zh_Hant_TW", "th_TH", "",
        ] {
            let tag = AIClient.languageTag(for: Locale(identifier: identifier))
            let range = NSRange(tag.startIndex..., in: tag)
            XCTAssertEqual(
                accepted?.numberOfMatches(in: tag, range: range),
                1,
                "\(identifier) produced \(tag)"
            )
        }

        XCTAssertEqual(AIClient.languageTag(for: Locale(identifier: "vi_VN")), "vi")
        XCTAssertEqual(AIClient.languageTag(for: Locale(identifier: "zh_Hans_CN")), "zh-Hans")
        XCTAssertEqual(AIClient.languageTag(for: Locale(identifier: "zh_Hant_TW")), "zh-Hant")
    }

    private func person(
        x: CGFloat,
        y: CGFloat,
        width: CGFloat = 0.20,
        height: CGFloat = 0.45,
        timestamp _: TimeInterval = 1
    ) -> PersonGeometry {
        PersonGeometry(
            id: SubjectTrackID(generation: 0),
            humanRect: CGRect(x: x, y: y, width: width, height: height),
            faceRect: CGRect(x: x + width * 0.25, y: y + height * 0.04, width: width * 0.5, height: height * 0.2),
            faceReady: true
        )
    }

    private func peopleMeasurement(
        _ people: [PersonGeometry],
        timestamp: TimeInterval = 1
    ) -> SceneMeasurement {
        SceneMeasurement(
            people: people,
            salientRect: nil,
            horizonAngle: 0,
            exposure: 0.5,
            timestamp: timestamp
        )
    }

    private func makeAIResponse() -> AICompositionResponse {
        AICompositionResponse(
            schemaVersion: 2,
            primary: makeAIPlan(id: "primary"),
            alternatives: [
                makeAIPlan(id: "safe"),
                makeAIPlan(id: "creative"),
            ]
        )
    }

    private func makeAIPlan(id: String, zoom: Double = 1.4) -> AICompositionPlan {
        AICompositionPlan(
            id: id,
            instruction: "Move left",
            target: NormalizedRect(CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.5)),
            movement: .left,
            angle: .eyeLevel,
            zoom: zoom,
            exposureBias: 0.2,
            flash: .off,
            presetIDs: ["neutral-skin"],
            pose: "Relax shoulders"
        )
    }
}
