import CoreImage
import XCTest
@testable import Focelle

final class SmokeTests: XCTestCase {
    func testCameraViewCanBeCreated() {
        XCTAssertNotNil(CameraView())
    }

    func testRestrictedCameraPermissionIsDenied() {
        XCTAssertEqual(CameraPermission(.restricted), .denied)
        XCTAssertEqual(CameraPermission(.authorized), .allowed)
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

    func testAutoCaptureRequiresStableReadySubjectAndCancels() {
        var auto = AutoCapture()
        let subject = CGRect(x: 0.3, y: 0.2, width: 0.3, height: 0.5)

        XCTAssertFalse(auto.update(
            aligned: true,
            subject: subject,
            faceReady: true,
            timestamp: 1
        ))
        XCTAssertFalse(auto.update(
            aligned: true,
            subject: subject.offsetBy(dx: 0.04, dy: 0),
            faceReady: true,
            timestamp: 2
        ))
        XCTAssertTrue(auto.update(
            aligned: true,
            subject: subject.offsetBy(dx: 0.04, dy: 0),
            faceReady: true,
            timestamp: 3.3
        ))

        auto.cancel(now: 4)
        XCTAssertFalse(auto.update(
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
    }

    @MainActor
    func testVoiceGuidanceThrottlesRepeatedAdvice() {
        let voice = VoiceGuidance()
        XCTAssertTrue(voice.shouldSpeak("Move left", now: 1))
        XCTAssertFalse(voice.shouldSpeak("Move left", now: 2))
        XCTAssertTrue(voice.shouldSpeak("Move left", now: 5))
    }

    private func makeAIResponse() -> AICompositionResponse {
        AICompositionResponse(
            schemaVersion: 1,
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
            instructionVi: "D\u1ecbch m\u00e1y sang tr\u00e1i",
            instructionEn: "Move left",
            target: NormalizedRect(CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.5)),
            movement: .left,
            angle: .eyeLevel,
            zoom: zoom,
            exposureBias: 0.2,
            flash: .off,
            presetIDs: ["neutral-skin"],
            poseVi: "Th\u1ea3 l\u1ecfng vai",
            poseEn: "Relax shoulders"
        )
    }
}
