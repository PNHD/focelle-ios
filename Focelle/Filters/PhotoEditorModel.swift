import Combine
import CoreImage
import Foundation
import ImageIO
import Photos

@MainActor
final class PhotoEditorModel: ObservableObject {
    @Published private(set) var preview: CGImage?
    @Published private(set) var isSaving = false
    @Published var errorKey: String?
    @Published var recipe: FilterRecipe?
    @Published var intensity = 1.0

    let originalData: Data

    private let renderer = FilterRenderer()
    private let previewInput: CIImage?

    init(data: Data) {
        originalData = data
        previewInput = Self.makePreview(from: data)
        refreshPreview()
    }

    func apply(_ recipe: FilterRecipe?, intensity: Double = 1) {
        self.recipe = recipe
        self.intensity = min(max(intensity, 0), 1)
        refreshPreview()
    }

    func compareOriginal(_ comparing: Bool) {
        guard let input = previewInput else { return }
        preview = renderer.previewImage(
            input,
            recipe: recipe,
            intensity: comparing ? 0 : intensity
        )
    }

    func saveCopy() async -> Bool {
        guard !isSaving else { return false }
        isSaving = true
        defer { isSaving = false }

        let data = originalData
        let selectedRecipe = recipe
        let selectedIntensity = intensity
        let output = await Task.detached {
            FilterRenderer().renderedData(
                from: data,
                recipe: selectedRecipe,
                intensity: selectedIntensity,
                aspectRatio: nil
            )
        }.value

        guard let output else {
            errorKey = "photoEditor.error.render"
            return false
        }

        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            errorKey = "camera.error.photosPermission"
            return false
        }

        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset()
                    .addResource(with: .photo, data: output, options: nil)
            }
            return true
        } catch {
            errorKey = "camera.error.save"
            return false
        }
    }

    private func refreshPreview() {
        guard let previewInput else {
            errorKey = "photoEditor.error.load"
            return
        }
        preview = renderer.previewImage(
            previewInput,
            recipe: recipe,
            intensity: intensity
        )
    }

    private static func makePreview(from data: Data) -> CIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let image = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 1_600,
                ] as CFDictionary
            )
        else { return nil }
        return CIImage(cgImage: image)
    }
}
