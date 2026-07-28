import AVFoundation
import CoreImage
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
        _ = engine.update(left)
        var right = left
        right.subjectRect = CGRect(x: 0.75, y: 0.3, width: 0.2, height: 0.4)
        XCTAssertEqual(engine.update(right).direction, .left)
        XCTAssertEqual(engine.update(right).direction, .right)
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

    func testLanguageTagFallsBackToEnglishAndKeepsScript() {
        XCTAssertEqual(AIClient.languageTag(for: Locale(identifier: "en_US")), "en")
        XCTAssertEqual(AIClient.languageTag(for: Locale(identifier: "vi_VN")), "vi")
        XCTAssertEqual(AIClient.languageTag(for: Locale(identifier: "ja_JP")), "ja")
        XCTAssertEqual(AIClient.languageTag(for: Locale(identifier: "ko_KR")), "ko")
        XCTAssertEqual(AIClient.languageTag(for: Locale(identifier: "zh_Hans_CN")), "zh-Hans")
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
