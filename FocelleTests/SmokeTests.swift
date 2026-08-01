import AVFoundation
import CoreImage
import XCTest
import simd

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

    func testPhotoCapabilityTiersMapTwelveTwentyFourAndFortyEightWithoutOmittingTheMiddle() {
        let twelve = PhotoDimensions(width: 4_032, height: 3_024)
        let twentyFour = PhotoDimensions(width: 5_712, height: 4_284)
        let fortyEight = PhotoDimensions(width: 8_064, height: 6_048)

        let tiers = PhotoCapabilityTiers.resolve(from: [twelve, fortyEight, twentyFour])

        XCTAssertEqual(tiers.supported, [twelve, twentyFour, fortyEight])
        XCTAssertEqual(tiers.standard, twelve)
        XCTAssertEqual(tiers.balanced, twentyFour, "24 MP must not be silently omitted as a middle tier")
        XCTAssertEqual(tiers.maximum, fortyEight)
    }

    func testCapabilityTiersNeverInventABalancedOrMaximumTier() {
        let twelve = PhotoDimensions(width: 4_032, height: 3_024)
        let fortyEight = PhotoDimensions(width: 8_064, height: 6_048)

        let noMiddle = PhotoCapabilityTiers.resolve(from: [twelve, fortyEight])
        XCTAssertNil(noMiddle.balanced)
        XCTAssertEqual(noMiddle.supported, [twelve, fortyEight])

        let onlyStandard = PhotoCapabilityTiers.resolve(from: [twelve])
        XCTAssertNil(onlyStandard.balanced)
        XCTAssertEqual(onlyStandard.maximum, twelve)
        XCTAssertEqual(onlyStandard.supported, [twelve])
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
            balanced: nil,
            maximum: biggerMaximum,
            outputLimit: nil,
            deferredSupported: true
        )
        XCTAssertEqual(normalStandard.dimensions, standard)
        XCTAssertEqual(normalStandard.downgradeReason, .none)

        let normalMaximum = ResolvedResolution.resolve(
            requested: .maximum,
            standard: standard,
            balanced: nil,
            maximum: biggerMaximum,
            outputLimit: nil,
            deferredSupported: true
        )
        XCTAssertEqual(normalMaximum.dimensions, biggerMaximum)
        XCTAssertEqual(normalMaximum.downgradeReason, .none)

        let deviceCappedMaximum = ResolvedResolution.resolve(
            requested: .maximum,
            standard: standard,
            balanced: nil,
            maximum: standard,
            outputLimit: nil,
            deferredSupported: true
        )
        XCTAssertEqual(deviceCappedMaximum.dimensions, standard)
        XCTAssertEqual(deviceCappedMaximum.downgradeReason, .unsupportedByActiveFormat)
        XCTAssertTrue(deviceCappedMaximum.isDowngraded)

        let outputCappedMaximum = ResolvedResolution.resolve(
            requested: .maximum,
            standard: standard,
            balanced: nil,
            maximum: biggerMaximum,
            outputLimit: standard,
            deferredSupported: true
        )
        XCTAssertEqual(outputCappedMaximum.dimensions, standard)
        XCTAssertEqual(outputCappedMaximum.downgradeReason, .outputLimited)
    }

    func testBalancedResolvesToTwentyFourMegapixelsOnlyWhenDeferredDeliveryIsSupported() {
        let twelve = PhotoDimensions(width: 4_032, height: 3_024)
        let twentyFour = PhotoDimensions(width: 5_712, height: 4_284)
        let fortyEight = PhotoDimensions(width: 8_064, height: 6_048)

        let deferred = ResolvedResolution.resolve(
            requested: .balanced,
            standard: twelve,
            balanced: twentyFour,
            maximum: fortyEight,
            outputLimit: nil,
            deferredSupported: true
        )
        XCTAssertEqual(deferred.dimensions, twentyFour)
        XCTAssertFalse(deferred.isDowngraded)

        let noDeferred = ResolvedResolution.resolve(
            requested: .balanced,
            standard: twelve,
            balanced: twentyFour,
            maximum: fortyEight,
            outputLimit: nil,
            deferredSupported: false
        )
        XCTAssertEqual(
            noDeferred.dimensions,
            twelve,
            "deferred unavailable must fall back to 12 MP truthfully"
        )
        XCTAssertEqual(noDeferred.downgradeReason, .deferredUnavailable)
        XCTAssertTrue(noDeferred.isDowngraded)

        let noTwentyFourFormat = ResolvedResolution.resolve(
            requested: .balanced,
            standard: twelve,
            balanced: nil,
            maximum: fortyEight,
            outputLimit: nil,
            deferredSupported: true
        )
        XCTAssertEqual(noTwentyFourFormat.dimensions, twelve)
        XCTAssertEqual(noTwentyFourFormat.downgradeReason, .unsupportedByActiveFormat)
    }

    func testDeferredProxyRecordStaysPendingUntilPhotosConfirmsFinishedDimensions() {
        let twelve = PhotoDimensions(width: 4_032, height: 3_024)
        let twentyFour = PhotoDimensions(width: 5_712, height: 4_284)
        let pending = CaptureResolutionRecord(
            requested: .balanced,
            resolvedDimensions: twentyFour,
            proxyResolvedDimensions: twelve,
            savedDimensions: nil,
            downgradeReason: .none
        )
        XCTAssertTrue(pending.isDeferredProxy)
        XCTAssertFalse(pending.isFinalized)

        // The asset still holds only the proxy → not final.
        XCTAssertNil(
            CaptureResolutionRecord.deferredConfirmation(for: pending, assetDimensions: twelve)
        )
        // Photos completed the fused 24 MP photo → final, with requested,
        // capture-resolved, proxy-resolved and final dimensions kept distinct.
        let finalized = CaptureResolutionRecord.deferredConfirmation(
            for: pending,
            assetDimensions: twentyFour
        )
        XCTAssertEqual(finalized?.requested, .balanced)
        XCTAssertEqual(finalized?.resolvedDimensions, twentyFour)
        XCTAssertEqual(finalized?.proxyResolvedDimensions, twelve)
        XCTAssertEqual(finalized?.savedDimensions, twentyFour)
        XCTAssertTrue(finalized?.isFinalized ?? false)
        // Photos finished at an unexpected size → recorded truthfully, never
        // claimed as 24 MP.
        let offSpec = PhotoDimensions(width: 4_000, height: 3_000)
        XCTAssertEqual(
            CaptureResolutionRecord.deferredConfirmation(for: pending, assetDimensions: offSpec)?
                .savedDimensions,
            offSpec
        )
        // A normal immediate capture has no proxy and is never finalized
        // through this path.
        let normal = CaptureResolutionRecord(
            requested: .maximum,
            resolvedDimensions: PhotoDimensions(width: 8_064, height: 6_048),
            savedDimensions: PhotoDimensions(width: 8_064, height: 6_048),
            downgradeReason: .none
        )
        XCTAssertFalse(normal.isDeferredProxy)
        XCTAssertTrue(normal.isFinalized)
        XCTAssertNil(
            CaptureResolutionRecord.deferredConfirmation(
                for: normal,
                assetDimensions: PhotoDimensions(width: 8_064, height: 6_048)
            )
        )
    }

    func testDeferredConfirmationOwnershipCleansSuccessCancelAndTimeout() {
        let proxy = PhotoDimensions(width: 4_032, height: 3_024)
        let final = PhotoDimensions(width: 5_712, height: 4_284)
        let record = CaptureResolutionRecord(
            requested: .balanced,
            resolvedDimensions: final,
            proxyResolvedDimensions: proxy,
            savedDimensions: nil
        )
        var pending = DeferredConfirmationTracker()
        pending.insert(identifier: "first", record: record, deadline: 10)
        pending.insert(identifier: "second", record: record, deadline: 10)

        XCTAssertEqual(pending.confirm(identifier: "first", dimensions: final)?.savedDimensions, final)
        XCTAssertNil(pending.entries["first"])
        XCTAssertNotNil(pending.entries["second"])

        pending.cancel(identifier: "second")
        XCTAssertTrue(pending.entries.isEmpty)

        pending.insert(identifier: "timeout", record: record, deadline: 10)
        pending.expire(now: 10)
        XCTAssertTrue(pending.entries.isEmpty)
    }

    func testFilteredOrCroppedBalancedCaptureFallsBackToStandardTruthfully() {
        let twelve = PhotoDimensions(width: 4_032, height: 3_024)
        let twentyFour = PhotoDimensions(width: 5_712, height: 4_284)
        let fortyEight = PhotoDimensions(width: 8_064, height: 6_048)

        let unfiltered = CameraSession.captureSnapshot(
            requested: .balanced,
            requiresImmediateProcessing: false,
            standard: twelve,
            balanced: twentyFour,
            maximum: fortyEight,
            outputLimit: fortyEight,
            deferredSupported: true,
            capabilityGeneration: 4
        )
        XCTAssertEqual(unfiltered.resolved.dimensions, twentyFour)
        XCTAssertFalse(unfiltered.resolved.isDowngraded)

        let filtered = CameraSession.captureSnapshot(
            requested: .balanced,
            requiresImmediateProcessing: true,
            standard: twelve,
            balanced: twentyFour,
            maximum: fortyEight,
            outputLimit: fortyEight,
            deferredSupported: true,
            capabilityGeneration: 4
        )
        XCTAssertEqual(filtered.resolved.requested, .balanced)
        XCTAssertEqual(filtered.resolved.dimensions, twelve)
        XCTAssertEqual(filtered.resolved.downgradeReason, .immediateProcessingRequired)

        // The verified 48 MP path is untouched by the same constraint.
        let filteredMaximum = CameraSession.captureSnapshot(
            requested: .maximum,
            requiresImmediateProcessing: true,
            standard: twelve,
            balanced: twentyFour,
            maximum: fortyEight,
            outputLimit: fortyEight,
            deferredSupported: true,
            capabilityGeneration: 4
        )
        XCTAssertEqual(filteredMaximum.resolved.dimensions, fortyEight)
        XCTAssertFalse(filteredMaximum.resolved.isDowngraded)
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

    @MainActor
    func testRequestedResolutionDefaultsToBalancedAndPersistsAcrossRecreation() {
        let suite = "FocelleTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(
            AppSettings(defaults: defaults).requestedResolution,
            .balanced,
            "clean installs default to the balanced 24 MP tier"
        )

        let settings = AppSettings(defaults: defaults)
        settings.requestedResolution = .maximum

        // Simulates a Settings round trip and a full relaunch: a fresh
        // AppSettings reading the same defaults must see the same selection.
        XCTAssertEqual(AppSettings(defaults: defaults).requestedResolution, .maximum)
    }

    @MainActor
    func testCameraResolutionOnlyChangesThroughSetRequestedResolution() {
        let camera = CameraSession()

        XCTAssertEqual(camera.resolution, .balanced)
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
    func testCameraSwitchRecomputesTwelveTwentyFourFortyEightAvailability() {
        let camera = CameraSession()
        let twelve = PhotoDimensions(width: 4_032, height: 3_024)
        let twentyFour = PhotoDimensions(width: 5_712, height: 4_284)
        let fortyEight = PhotoDimensions(width: 8_064, height: 6_048)
        camera.setRequestedResolution(.balanced)

        // Rear camera: 12/24/48 with deferred delivery.
        camera.cachedStandardDimensions = twelve
        camera.cachedBalancedDimensions = twentyFour
        camera.cachedMaximumDimensions = fortyEight
        camera.cachedOutputLimit = fortyEight
        camera.cachedDeferredDeliverySupported = true
        camera.recomputeResolvedResolution()

        XCTAssertTrue(camera.supportsBalancedResolution)
        XCTAssertEqual(camera.balancedModeLabel, "24")
        XCTAssertTrue(camera.supportsMaximumResolution)
        XCTAssertEqual(camera.resolvedResolution.dimensions, twentyFour)

        // Front camera: only 12 MP and no deferred delivery.
        camera.cachedStandardDimensions = twelve
        camera.cachedBalancedDimensions = nil
        camera.cachedMaximumDimensions = twelve
        camera.cachedOutputLimit = twelve
        camera.cachedDeferredDeliverySupported = false
        camera.recomputeResolvedResolution()

        XCTAssertFalse(camera.supportsBalancedResolution)
        XCTAssertFalse(camera.supportsMaximumResolution)
        XCTAssertEqual(camera.resolution, .balanced, "the requested tier must survive the switch")
        XCTAssertEqual(camera.resolvedResolution.dimensions, twelve)
        XCTAssertEqual(camera.resolvedResolution.downgradeReason, .unsupportedByActiveFormat)

        // Back to the rear camera: 24 MP resolves again without user action.
        camera.cachedBalancedDimensions = twentyFour
        camera.cachedMaximumDimensions = fortyEight
        camera.cachedOutputLimit = fortyEight
        camera.cachedDeferredDeliverySupported = true
        camera.recomputeResolvedResolution()

        XCTAssertTrue(camera.supportsBalancedResolution)
        XCTAssertEqual(camera.resolvedResolution.dimensions, twentyFour)
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
        XCTAssertEqual(engine.update(left).direction, .left)

        // Drifting inside the exit band must not rewrite the instruction while
        // the user is still carrying out the previous one.
        var drifting = left
        drifting.subjectRect = CGRect(x: 0.10, y: 0.3, width: 0.2, height: 0.4)
        drifting.timestamp = 2
        XCTAssertEqual(engine.update(drifting).direction, .left)

        // Overshooting to the far side clears it at once; holding an
        // instruction that is now wrong is worse than switching.
        var overshot = left
        overshot.subjectRect = CGRect(x: 0.75, y: 0.3, width: 0.2, height: 0.4)
        overshot.timestamp = 3
        XCTAssertEqual(engine.update(overshot).direction, .right)
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
        var guidance = Guidance(
            subjectRect: CGRect(x: 0.3, y: 0.35, width: 0.3, height: 0.4),
            target: CGPoint(x: 0.5, y: 0.5),
            direction: .left,
            instructionKey: "guidance.left",
            aligned: false
        )
        XCTAssertTrue(GuidanceOverlay.instructionSitsHigh(guidance))

        guidance.subjectRect = CGRect(x: 0.3, y: 0.02, width: 0.3, height: 0.6)
        XCTAssertFalse(GuidanceOverlay.instructionSitsHigh(guidance))

        guidance.subjectRect = nil
        XCTAssertTrue(GuidanceOverlay.instructionSitsHigh(guidance))
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

    // MARK: - FCL-M2 Batch A: PlanSession zoom/exposure contract

    func testAnalyzeSnapshotsBaselineAndNeverMutatesCameraValues() {
        let session = PlanSession(
            baselineZoom: 1.5,
            baselineExposureBias: 0.2,
            capabilityGeneration: 3
        )

        XCTAssertEqual(session.baselineZoom, 1.5)
        XCTAssertEqual(session.baselineExposureBias, 0.2)
        XCTAssertNil(session.appliedZoom)
        XCTAssertNil(session.appliedExposureBias)
    }

    @MainActor
    func testCoachAnalyzeWithNoSceneLeavesZoomAndExposureUntouched() async {
        let camera = CameraSession()
        camera.zoom = 3.4
        camera.exposure = 0.6

        camera.analyzeSceneV2()
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(camera.zoom, 3.4)
        XCTAssertEqual(camera.exposure, 0.6, accuracy: 0.0001)
        XCTAssertEqual(camera.notice, "coach.error.noScene")
        XCTAssertTrue(camera.coachPlans.isEmpty)
        XCTAssertNil(camera.coachSession)
    }

    func testApplyUsesAbsoluteValuesNeverCompounding() {
        let session = PlanSession(
            baselineZoom: 1.5,
            baselineExposureBias: 0.2,
            capabilityGeneration: 3
        )

        let applied = session.applying(zoom: 2.0, exposureBias: -0.4)

        XCTAssertEqual(applied.appliedZoom, 2.0, "absolute value, not baseline + delta")
        XCTAssertEqual(applied.appliedExposureBias, -0.4)
        XCTAssertEqual(session.baselineZoom, 1.5, "baseline is immutable")
    }

    func testUndoRestoresExactBaseline() {
        let session = PlanSession(
            baselineZoom: 1.5,
            baselineExposureBias: 0.2,
            capabilityGeneration: 3
        )
        let applied = session.applying(zoom: 2.0, exposureBias: -0.4)

        XCTAssertEqual(applied.undo.zoom, 1.5)
        XCTAssertEqual(applied.undo.exposureBias, 0.2)
        XCTAssertEqual(applied.undoing().appliedZoom, nil)
    }

    func testRepeatedApplyUndoCyclesDoNotDrift() {
        var session = PlanSession(
            baselineZoom: 1.5,
            baselineExposureBias: 0.2,
            capabilityGeneration: 3
        )
        for _ in 0..<10 {
            session = session.applying(zoom: 2.0, exposureBias: -0.4)
            session = session.undoing()
        }

        XCTAssertEqual(session.undo.zoom, 1.5)
        XCTAssertEqual(session.undo.exposureBias, 0.2)
        XCTAssertNil(session.appliedZoom)
    }

    func testCapabilityGenerationChangeInvalidatesPlanSession() {
        let session = PlanSession(
            baselineZoom: 1,
            baselineExposureBias: 0,
            capabilityGeneration: 7
        )

        XCTAssertTrue(session.isValid(for: 7))
        XCTAssertFalse(session.isValid(for: 8), "a camera switch invalidates the session")
    }

    func testSceneDescriptorRejectsStaleGeneration() {
        XCTAssertTrue(SceneDescriptor.isCurrent(generation: 2, currentGeneration: 2))
        XCTAssertFalse(SceneDescriptor.isCurrent(generation: 1, currentGeneration: 2))
    }

    // MARK: - FCL-M2 Batch A: stabilization and identity

    func testLandmarkStabilizationIsDeterministicAndSmoothsScalars() {
        var stabilizer = DescriptorStabilizer()
        let first = makeDescriptor(luma: 0.4, quality: 0.5)
        let second = makeDescriptor(luma: 0.6, quality: 0.9)

        _ = stabilizer.update(first)
        let result = stabilizer.update(second)

        var repeatStabilizer = DescriptorStabilizer()
        _ = repeatStabilizer.update(first)
        let repeatResult = repeatStabilizer.update(second)

        XCTAssertEqual(result, repeatResult, "same input sequence must give the same output")
        XCTAssertEqual(result.luma, 0.5, accuracy: 0.0001)
        XCTAssertEqual(result.faceCaptureQuality ?? 0, 0.7, accuracy: 0.0001)
    }

    func testSelectedSubjectOwnershipCrossingAndLossNeverFallBackToFirstCandidate() {
        var tracker = SubjectIdentityTracker()
        let subject = CGRect(x: 0.3, y: 0.2, width: 0.3, height: 0.5)
        let unrelated = CGRect(x: 0.7, y: 0.6, width: 0.15, height: 0.15)

        // Detector ordering is deliberately hostile: selection, not index 0,
        // establishes the first identity.
        let adopted = tracker.update(
            candidates: [unrelated, subject],
            selectedCandidate: subject,
            featurePrints: [],
            now: 1
        )
        XCTAssertEqual(adopted?.id, 1)
        XCTAssertEqual(adopted?.rect, subject)

        let crossedSubject = CGRect(x: 0.34, y: 0.2, width: 0.3, height: 0.5)
        let crossing = tracker.update(
            candidates: [unrelated, crossedSubject],
            selectedCandidate: nil,
            featurePrints: [],
            now: 1.2
        )
        XCTAssertEqual(crossing?.id, 1)
        XCTAssertEqual(crossing?.rect, crossedSubject)

        let preserved = tracker.update(
            candidates: [unrelated],
            selectedCandidate: nil,
            featurePrints: [],
            now: 1.4
        )
        XCTAssertEqual(preserved?.id, 1)
        XCTAssertEqual(preserved?.rect, crossedSubject)

        let lost = tracker.update(
            candidates: [unrelated],
            selectedCandidate: nil,
            featurePrints: [],
            now: 2.5
        )
        XCTAssertNil(lost)
    }

    func testPendingTapRejectsNearbyReplacementBeforeInitialIdentityConfirmation() {
        let selected = CGRect(x: 0.2, y: 0.2, width: 0.25, height: 0.55)
        let nearbyReplacement = CGRect(x: 0.48, y: 0.2, width: 0.25, height: 0.55)
        var pending = PendingSubjectSelection(rect: selected, generation: 4, timestamp: 10)

        XCTAssertNil(
            pending.confirm(
                candidates: [nearbyReplacement],
                featureDistances: [],
                generation: 4,
                now: 10.1
            )
        )
        XCTAssertEqual(pending.state, .lost)

        // A lost tap cannot later adopt an unrelated detector result.
        XCTAssertNil(
            pending.confirm(
                candidates: [selected],
                featureDistances: [],
                generation: 4,
                now: 10.2
            )
        )
    }

    func testPendingTapRequiresSameGenerationAndExpiresBeforeLateConfirmation() {
        let selected = CGRect(x: 0.2, y: 0.2, width: 0.25, height: 0.55)
        var invalidated = PendingSubjectSelection(rect: selected, generation: 4, timestamp: 10)
        XCTAssertNil(
            invalidated.confirm(
                candidates: [selected],
                featureDistances: [],
                generation: 5,
                now: 10.1
            )
        )
        XCTAssertEqual(invalidated.state, .lost)

        var expired = PendingSubjectSelection(rect: selected, generation: 4, timestamp: 10)
        XCTAssertNil(
            expired.confirm(
                candidates: [selected],
                featureDistances: [],
                generation: 4,
                now: 10.9
            )
        )
        XCTAssertEqual(expired.state, .lost)
    }

    func testPendingTapConfirmsOnlyTheTappedCandidateByGeometry() {
        let selected = CGRect(x: 0.2, y: 0.2, width: 0.25, height: 0.55)
        let unrelated = CGRect(x: 0.65, y: 0.2, width: 0.2, height: 0.5)
        var pending = PendingSubjectSelection(rect: selected, generation: 4, timestamp: 10)

        let confirmed = pending.confirm(
            candidates: [unrelated, selected],
            featureDistances: [],
            generation: 4,
            now: 10.1
        )

        XCTAssertEqual(confirmed, selected)
        XCTAssertEqual(pending.state, .confirmed)
    }

    func testFeaturePrintDistanceUsesLowerValuesForAdoption() {
        XCTAssertTrue(SubjectFeaturePrint.canAdopt(distance: 0.1))
        XCTAssertFalse(SubjectFeaturePrint.canAdopt(distance: 0.5))
    }

    func testFaceLandmarkPointConvertsFromFaceRelativeToWholeImage() {
        let converted = OnDeviceAnalyzer.fullImagePoint(
            CGPoint(x: 0.25, y: 0.75),
            faceBounds: CGRect(x: 0.2, y: 0.3, width: 0.4, height: 0.2)
        )

        XCTAssertEqual(converted.x, 0.3, accuracy: 0.0001)
        XCTAssertEqual(converted.y, 0.45, accuracy: 0.0001)
    }

    func testPose3DHelperProjectsImageCoordinatesAndReadsTransformDepth() {
        var transform = matrix_identity_float4x4
        transform.columns.3 = SIMD4<Float>(0.4, 0.5, 1.25, 1)

        let landmark = OnDeviceAnalyzer.pose3DLandmark(
            name: "root",
            projected: CGPoint(x: 0.2, y: 0.8),
            transform: transform,
            confidence: 0.75
        )

        XCTAssertEqual(landmark.point, NormalizedPoint(x: 0.2, y: 0.8))
        XCTAssertEqual(landmark.depth, 1.25)
        XCTAssertEqual(landmark.confidence, 0.75)
    }

    // MARK: - FCL-M2 Batch A: pose templates

    func testTemplateSchemaValidatesGeneratedBundle() throws {
        let bundle = try makeBundle()

        XCTAssertEqual(bundle.schemaVersion, 1)
        XCTAssertEqual(bundle.seedCount, 14)
        XCTAssertGreaterThanOrEqual(bundle.generatedCount, 72)
        XCTAssertLessThanOrEqual(bundle.generatedCount, 96)
        XCTAssertEqual(bundle.templates.count, bundle.generatedCount)
        XCTAssertEqual(Set(bundle.templates.map(\.id)).count, bundle.templates.count)
        for template in bundle.templates {
            XCTAssertTrue(PoseTemplateValidation.validate(template), template.id)
            XCTAssertEqual(template.source, "owned-synthetic")
        }
    }

    func testGeneratorOutputIsCanonicalAndMirrorDeduplicated() throws {
        let bundle = try makeBundle()

        let keys = bundle.templates.map(PoseTemplateDedup.canonicalKey)
        XCTAssertEqual(
            Set(keys).count,
            keys.count,
            "mirror-equivalent templates must not both survive"
        )
        XCTAssertEqual(
            PoseTemplateDedup.deduplicated(bundle.templates).count,
            bundle.templates.count,
            "the bundle must already be deduplicated"
        )
        let template = try XCTUnwrap(
            bundle.templates.first { $0.category == "onePerson" && !$0.landmarks.isEmpty }
        )
        XCTAssertEqual(
            PoseTemplateDedup.canonicalKey(template),
            PoseTemplateDedup.canonicalKey(template.mirrored),
            "canonicalization must treat a template and its mirror as equal"
        )
    }

    func testImplausibleAndCropUnsafeTemplatesAreRejected() {
        var foldedLegs = makeTemplate(
            landmarks: [
                "left_shoulder": NormalizedPoint(x: 0.39, y: 0.72),
                "right_shoulder": NormalizedPoint(x: 0.61, y: 0.72),
                "left_elbow": NormalizedPoint(x: 0.32, y: 0.67),
                "right_elbow": NormalizedPoint(x: 0.68, y: 0.67),
                "left_hand": NormalizedPoint(x: 0.35, y: 0.62),
                "right_hand": NormalizedPoint(x: 0.65, y: 0.62),
                "left_hip": NormalizedPoint(x: 0.42, y: 0.55),
                "right_hip": NormalizedPoint(x: 0.58, y: 0.55),
                "left_knee": NormalizedPoint(x: 0.5, y: 0.4),
                "right_knee": NormalizedPoint(x: 0.5, y: 0.4),
                "left_ankle": NormalizedPoint(x: 0.484, y: 0.43),
                "right_ankle": NormalizedPoint(x: 0.516, y: 0.43),
                "left_foot": NormalizedPoint(x: 0.49, y: 0.39),
                "right_foot": NormalizedPoint(x: 0.51, y: 0.39),
            ]
        )
        XCTAssertFalse(
            PoseTemplateValidation.validate(foldedLegs),
            "a hyperflexed knee must be rejected"
        )

        let cropUnsafe = makeTemplate(
            faceZone: Frame(x: 0.1, y: 0.95, width: 0.2, height: 0.1)
        )
        XCTAssertFalse(
            PoseTemplateValidation.validate(cropUnsafe),
            "a face zone without crop safety margin must be rejected"
        )
    }

    func testMirrorEquivalentTemplatesAreRemoved() throws {
        let bundle = try makeBundle()
        let template = try XCTUnwrap(
            bundle.templates.first { $0.category == "onePerson" && !$0.landmarks.isEmpty }
        )

        let deduplicated = PoseTemplateDedup.deduplicated([template, template.mirrored])

        XCTAssertEqual(deduplicated.count, 1)
    }

    // MARK: - FCL-M2 Batch A: local planner

    func testHardCropConstraintsRunBeforeScoring() {
        let scene = makeDescriptor(nose: NormalizedPoint(x: 0.9, y: 0.8))
        let templates = [
            makeTemplate(
                id: "crop-unsafe",
                faceZone: Frame(x: 0.2, y: 0.5, width: 0.3, height: 0.2)
            )
        ]

        let plans = LocalPlanner.plan(
            scene: scene,
            intent: .portrait,
            templates: templates,
            capabilities: LocalPlanner.Capabilities(maxZoom: 3, aspectRatio: 4.0 / 3.0),
            selectedSubject: nil
        )

        XCTAssertTrue(
            plans.isEmpty,
            "a template that crops the face must be rejected before scoring"
        )
    }

    func testZoomBeyondCapabilityIsHardRejected() {
        let scene = makeDescriptor()
        let templates = [makeTemplate(id: "too-zoomed", zoom: 5)]

        let plans = LocalPlanner.plan(
            scene: scene,
            intent: .portrait,
            templates: templates,
            capabilities: LocalPlanner.Capabilities(maxZoom: 3, aspectRatio: 4.0 / 3.0),
            selectedSubject: nil
        )

        XCTAssertTrue(plans.isEmpty)
    }

    func testPlannerReturnsFeasibleAndDiversePrimarySafeCreativePlans() {
        let scene = makeDescriptor()
        let templates = [
            makeTemplate(id: "t1", zoom: 1.0),
            makeTemplate(
                id: "t2",
                centerX: 0.35,
                subjectWidth: 0.44,
                faceZone: Frame(x: 0.25, y: 0.6, width: 0.3, height: 0.22),
                zoom: 1.4
            ),
            makeTemplate(
                id: "t3",
                centerX: 0.65,
                subjectWidth: 0.30,
                subjectHeight: 0.70,
                faceZone: Frame(x: 0.5, y: 0.6, width: 0.3, height: 0.22),
                zoom: 1.8
            ),
        ]

        let plans = LocalPlanner.plan(
            scene: scene,
            intent: .portrait,
            templates: templates,
            capabilities: LocalPlanner.Capabilities(maxZoom: 3, aspectRatio: 4.0 / 3.0),
            selectedSubject: nil
        )

        XCTAssertEqual(plans.count, 3)
        let planIDs = Set(plans.map { $0.id })
        let templateIDs = Set(plans.map { $0.templateID })
        XCTAssertEqual(planIDs, Set(["primary", "safe", "creative"]))
        XCTAssertEqual(templateIDs.count, 3, "plans must be meaningfully diverse")
        XCTAssertTrue(plans.allSatisfy { $0.recommendedZoom <= 3 })
        XCTAssertEqual(plans.first(where: { $0.id == "safe" })?.motion, 0, "safe needs the least motion")
    }

    func testPlannerRejectsAspectCropUnsafeTemplatesBeforeScoring() {
        let scene = makeDescriptor()
        let sideEdge = makeTemplate(id: "side", centerX: 0.16, subjectWidth: 0.2)
        let topEdge = makeTemplate(id: "top", centerY: 0.84, subjectHeight: 0.25)

        XCTAssertFalse(
            LocalPlanner.isHardRejected(
                sideEdge,
                scene: scene,
                intent: .portrait,
                capabilities: LocalPlanner.Capabilities(maxZoom: 3, aspectRatio: 4.0 / 3.0),
                selectedSubject: nil
            )
        )
        XCTAssertTrue(
            LocalPlanner.isHardRejected(
                sideEdge,
                scene: scene,
                intent: .portrait,
                capabilities: LocalPlanner.Capabilities(maxZoom: 3, aspectRatio: 1),
                selectedSubject: nil
            )
        )
        XCTAssertTrue(
            LocalPlanner.isHardRejected(
                topEdge,
                scene: scene,
                intent: .portrait,
                capabilities: LocalPlanner.Capabilities(maxZoom: 3, aspectRatio: 16.0 / 9.0),
                selectedSubject: nil
            )
        )
    }

    func testPlannerRejectsEdgePeopleAndFacesForTheActiveCrop() {
        let edgePerson = makeDescriptor(
            humanRects: [CGRect(x: 0.02, y: 0.2, width: 0.2, height: 0.6)],
            nose: nil
        )
        let normal = makeTemplate(id: "normal")
        XCTAssertTrue(
            LocalPlanner.isHardRejected(
                normal,
                scene: edgePerson,
                intent: .portrait,
                capabilities: LocalPlanner.Capabilities(maxZoom: 3, aspectRatio: 1),
                selectedSubject: edgePerson.subjectRect
            )
        )

        let edgeFace = makeDescriptor(nose: NormalizedPoint(x: 0.5, y: 0.9))
        let faceSafeInFourThree = makeTemplate(
            id: "face-edge",
            faceZone: Frame(x: 0.3, y: 0.8, width: 0.4, height: 0.15)
        )
        XCTAssertTrue(
            LocalPlanner.isHardRejected(
                faceSafeInFourThree,
                scene: edgeFace,
                intent: .portrait,
                capabilities: LocalPlanner.Capabilities(maxZoom: 3, aspectRatio: 16.0 / 9.0),
                selectedSubject: nil
            )
        )
    }

    func testPlannerReturnsOnlyAvailableDistinctTemplatePlans() {
        let scene = makeDescriptor()
        let one = LocalPlanner.plan(
            scene: scene,
            intent: .portrait,
            templates: [makeTemplate(id: "one")],
            capabilities: LocalPlanner.Capabilities(maxZoom: 3, aspectRatio: 4.0 / 3.0),
            selectedSubject: nil
        )
        XCTAssertEqual(one.map(\.templateID), ["one"])

        let two = LocalPlanner.plan(
            scene: scene,
            intent: .portrait,
            templates: [makeTemplate(id: "one"), makeTemplate(id: "two", zoom: 1.2)],
            capabilities: LocalPlanner.Capabilities(maxZoom: 3, aspectRatio: 4.0 / 3.0),
            selectedSubject: nil
        )
        XCTAssertEqual(two.count, 2)
        XCTAssertEqual(Set(two.map(\.templateID)).count, 2)
    }

    // MARK: - FCL-M2 Batch A: feature flags

    @MainActor
    func testCoachFeatureFlagsDefaultOffPersistAndKeepFallbackStateClean() {
        let suite = "FocelleTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)

        XCTAssertFalse(settings.coachV2Enabled, "Coach V2 must default OFF")
        XCTAssertFalse(settings.aestheticsEnabled)

        settings.coachV2Enabled = true
        settings.aestheticsEnabled = true
        XCTAssertTrue(AppSettings(defaults: defaults).coachV2Enabled)
        XCTAssertTrue(AppSettings(defaults: defaults).aestheticsEnabled)

        let camera = CameraSession()
        XCTAssertTrue(camera.coachPlans.isEmpty)
        XCTAssertNil(camera.coachSession)
        XCTAssertFalse(camera.coachPlanApplied)
    }

    @MainActor
    func testCoachDisableClearsAppliedV2StateAndInvalidatesAnalysis() async {
        let camera = CameraSession()
        let plan = makeCoachPlan()
        let session = PlanSession(
            baselineZoom: 1,
            baselineExposureBias: 0,
            capabilityGeneration: 0
        ).applying(zoom: plan.recommendedZoom, exposureBias: plan.recommendedExposureBias)
        camera.debugSeedCoachForTesting(plan: plan, session: session, applied: true)

        camera.coachV2DidChange(from: true, to: false)
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertTrue(camera.coachPlans.isEmpty)
        XCTAssertNil(camera.selectedCoachPlan)
        XCTAssertNil(camera.coachSession)
        XCTAssertFalse(camera.coachPlanApplied)
        XCTAssertNil(camera.guidance)
    }

    @MainActor
    func testCameraSwitchInvalidatesVisiblePlanBeforeImmediateApply() {
        let camera = CameraSession()
        let plan = makeCoachPlan()
        camera.debugSeedCoachForTesting(
            plan: plan,
            session: PlanSession(
                baselineZoom: 1,
                baselineExposureBias: 0,
                capabilityGeneration: 0
            ),
            applied: false
        )

        camera.switchCamera()
        camera.applyCoachPlan(plan.id)

        XCTAssertNil(camera.coachSession)
        XCTAssertTrue(camera.coachPlans.isEmpty)
        XCTAssertFalse(camera.coachPlanApplied)
    }

    private func makeBundle() throws -> PoseTemplateBundle {
        let resourceURL = try XCTUnwrap(
            Bundle.main.url(
                forResource: PoseTemplateStore.resourceName,
                withExtension: PoseTemplateStore.resourceExtension
            )
        )
        XCTAssertEqual(resourceURL.lastPathComponent, "PoseTemplates.json")
        let bundle = PoseTemplateStore.load(in: .main)
        XCTAssertNotEqual(bundle.generation, "missing")
        return bundle
    }

    private func makeTemplate(
        id: String = "t1",
        category: String = "onePerson",
        subjectCount: Int = 1,
        centerX: Double = 0.5,
        centerY: Double = 0.5,
        subjectWidth: Double = 0.34,
        subjectHeight: Double = 0.82,
        faceZone: Frame = Frame(x: 0.35, y: 0.6, width: 0.3, height: 0.22),
        landmarks: [String: NormalizedPoint]? = nil,
        zoom: Double = 1.0
    ) -> PoseTemplate {
        PoseTemplate(
            schemaVersion: 1,
            id: id,
            category: category,
            framing: "full",
            orientation: "front",
            subjectCount: subjectCount,
            cameraHints: [],
            landmarks: landmarks ?? standingLandmarks(),
            targetFraming: TargetFraming(
                subjectWidth: subjectWidth,
                subjectHeight: subjectHeight,
                centerX: centerX,
                centerY: centerY
            ),
            headroom: 0.12,
            faceZone: faceZone,
            recommendedZoom: zoom,
            contextTags: [],
            lightingConstraints: LightingConstraints(
                minLuma: 0.2,
                maxLuma: 0.9,
                avoidBacklit: false
            ),
            instructionVI: "Giữ khung.",
            instructionEN: "Hold the frame.",
            source: "owned-synthetic"
        )
    }

    private func standingLandmarks(centerX: Double = 0.5) -> [String: NormalizedPoint] {
        [
            "head_top": NormalizedPoint(x: centerX, y: 0.95),
            "nose": NormalizedPoint(x: centerX, y: 0.85),
            "left_shoulder": NormalizedPoint(x: centerX - 0.11, y: 0.72),
            "right_shoulder": NormalizedPoint(x: centerX + 0.11, y: 0.72),
            "left_elbow": NormalizedPoint(x: centerX - 0.18, y: 0.67),
            "right_elbow": NormalizedPoint(x: centerX + 0.18, y: 0.67),
            "left_hand": NormalizedPoint(x: centerX - 0.15, y: 0.62),
            "right_hand": NormalizedPoint(x: centerX + 0.15, y: 0.62),
            "left_hip": NormalizedPoint(x: centerX - 0.08, y: 0.55),
            "right_hip": NormalizedPoint(x: centerX + 0.08, y: 0.55),
            "left_knee": NormalizedPoint(x: centerX - 0.09, y: 0.38),
            "right_knee": NormalizedPoint(x: centerX + 0.09, y: 0.38),
            "left_ankle": NormalizedPoint(x: centerX - 0.06, y: 0.14),
            "right_ankle": NormalizedPoint(x: centerX + 0.06, y: 0.14),
            "left_foot": NormalizedPoint(x: centerX - 0.07, y: 0.11),
            "right_foot": NormalizedPoint(x: centerX + 0.07, y: 0.11),
        ]
    }

    private func makeDescriptor(
        humanRects: [CGRect] = [CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.6)],
        nose: NormalizedPoint? = NormalizedPoint(x: 0.5, y: 0.7),
        luma: Double = 0.5,
        quality: Double? = 0.8
    ) -> SceneDescriptor {
        let pose = standingLandmarks()
        return SceneDescriptor(
            subjectRect: humanRects.first,
            subjectIdentityID: 1,
            humanRects: humanRects,
            poseLandmarks: pose.map { PoseLandmark(name: $0.key, point: $0.value, confidence: 0.8) },
            pose3D: nil,
            faceLandmarks: nose.map { [FaceLandmark(name: "nose", point: $0, confidence: 0.9)] } ?? [],
            faceCaptureQuality: quality,
            saliencyRect: nil,
            horizonAngle: nil,
            luma: luma,
            lighting: LightingInfo(
                histogram: LightingInfo.histogram(fromLumaSamples: [0.2, 0.4, 0.6, 0.8]),
                backlit: false,
                contrast: 0.05
            ),
            blurProxy: 0.4,
            classifications: ["onePerson"],
            generation: 1,
            timestamp: 1
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

    private func makeCoachPlan() -> CoachPlan {
        CoachPlan(
            id: "primary",
            templateID: "test-template",
            titleVI: "Đẹp nhất",
            titleEN: "Best",
            targetFraming: TargetFraming(
                subjectWidth: 0.3,
                subjectHeight: 0.6,
                centerX: 0.5,
                centerY: 0.5
            ),
            recommendedZoom: 1.2,
            recommendedExposureBias: 0.2,
            instructionVI: "Giữ khung.",
            instructionEN: "Hold the frame.",
            score: 1,
            motion: 0.2
        )
    }
}
