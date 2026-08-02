import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

struct FilterThumbnailRequest: Equatable, Sendable {
    let key: String
    let recipe: FilterRecipe?
    let intensity: Double

    init(key: String, recipe: FilterRecipe?, intensity: Double = 1) {
        self.key = key
        self.recipe = recipe
        self.intensity = intensity
    }
}

struct FilterRenderer {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let grain = FilterRenderer.makeGrain()

    func render(_ input: CIImage, recipe: FilterRecipe, intensity: Double = 1) -> CIImage {
        let amount = min(max(intensity, 0), 1)
        var image = input

        let exposure = CIFilter.exposureAdjust()
        exposure.inputImage = image
        exposure.ev = Float(recipe.exposure * amount)
        image = exposure.outputImage ?? image

        let tone = CIFilter.highlightShadowAdjust()
        tone.inputImage = image
        tone.highlightAmount = Float(1 + recipe.highlights * amount * 0.55)
        tone.shadowAmount = Float(recipe.shadows * amount)
        image = tone.outputImage ?? image

        let color = CIFilter.colorControls()
        color.inputImage = image
        color.contrast = Float(1 + recipe.contrast * amount)
        color.saturation = Float(
            recipe.monochrome ? 1 - amount : 1 + recipe.saturation * amount
        )
        image = color.outputImage ?? image

        if recipe.warmth != 0 || recipe.tint != 0 {
            let temperature = CIFilter.temperatureAndTint()
            temperature.inputImage = image
            temperature.neutral = CIVector(x: 6_500, y: 0)
            temperature.targetNeutral = CIVector(
                x: CGFloat(6_500 + recipe.warmth * amount * 900),
                y: CGFloat(recipe.tint * amount * 80)
            )
            image = temperature.outputImage ?? image
        }

        if recipe.fade > 0 {
            let fade = recipe.fade * amount
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = image
            let scale = 1 - fade * 0.18
            let lift = fade * 0.08
            matrix.rVector = CIVector(x: CGFloat(scale), y: 0, z: 0, w: 0)
            matrix.gVector = CIVector(x: 0, y: CGFloat(scale), z: 0, w: 0)
            matrix.bVector = CIVector(x: 0, y: 0, z: CGFloat(scale), w: 0)
            matrix.biasVector = CIVector(
                x: CGFloat(lift),
                y: CGFloat(lift),
                z: CGFloat(lift),
                w: 0
            )
            image = matrix.outputImage ?? image
        }

        if recipe.grain > 0, let grain {
            let tiled =
                grain
                .transformed(by: CGAffineTransform(scaleX: 1.4, y: 1.4))
                .applyingFilter("CIAffineTile")
                .cropped(to: image.extent)
            let alpha = CIFilter.colorMatrix()
            alpha.inputImage = tiled
            alpha.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
            alpha.biasVector = CIVector(
                x: 0,
                y: 0,
                z: 0,
                w: CGFloat(recipe.grain * amount * 0.32)
            )

            let overlay = CIFilter.overlayBlendMode()
            overlay.inputImage = alpha.outputImage
            overlay.backgroundImage = image
            image = overlay.outputImage ?? image
        }

        if recipe.vignette > 0 {
            let vignette = CIFilter.vignette()
            vignette.inputImage = image
            vignette.intensity = Float(recipe.vignette * amount * 1.4)
            vignette.radius = Float(min(image.extent.width, image.extent.height) * 0.65)
            image = vignette.outputImage ?? image
        }

        return image.cropped(to: input.extent)
    }

    func renderedData(
        from data: Data,
        recipe: FilterRecipe?,
        intensity: Double,
        aspectRatio: CGFloat?
    ) -> Data? {
        if recipe == nil, aspectRatio == nil { return data }
        guard var image = CIImage(data: data, options: [.applyOrientationProperty: true]),
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        else { return nil }

        if let aspectRatio {
            image = crop(image, to: aspectRatio)
        }
        if let recipe {
            image = render(image, recipe: recipe, intensity: intensity)
        }

        return context.heifRepresentation(
            of: image,
            format: .RGBA8,
            colorSpace: colorSpace
        ) ?? context.jpegRepresentation(of: image, colorSpace: colorSpace)
    }

    func previewImage(
        _ input: CIImage,
        recipe: FilterRecipe?,
        intensity: Double
    ) -> CGImage? {
        let output = recipe.map { render(input, recipe: $0, intensity: intensity) } ?? input
        return context.createCGImage(output, from: output.extent)
    }

    // Thumbnails come off the live frame rather than bundled sample photos, so
    // the strip shows each look on the scene actually being shot and the app
    // ships no image assets for it. 96 points is the largest one is ever drawn.
    func thumbnails(
        _ input: CIImage,
        requests: [FilterThumbnailRequest],
        side: CGFloat = 96
    ) -> [String: CGImage] {
        let square = crop(input, to: 1)
        guard square.extent.width > 0 else { return [:] }
        let scale = side / square.extent.width
        let source = square.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        var output: [String: CGImage] = [:]
        for request in requests {
            output[request.key] = previewImage(
                source,
                recipe: request.recipe,
                intensity: request.intensity
            )
        }
        return output
    }

    func aiPreviewData(_ input: CIImage, maxDimension: CGFloat = 1_024) -> Data? {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let scale = min(1, maxDimension / max(input.extent.width, input.extent.height))
        let image = input.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return context.jpegRepresentation(of: image, colorSpace: colorSpace)
    }

    private func crop(_ image: CIImage, to ratio: CGFloat) -> CIImage {
        let extent = image.extent
        let current = extent.width / extent.height
        let crop: CGRect
        if current > ratio {
            let width = extent.height * ratio
            crop = CGRect(x: extent.midX - width / 2, y: extent.minY, width: width, height: extent.height)
        } else {
            let height = extent.width / ratio
            crop = CGRect(x: extent.minX, y: extent.midY - height / 2, width: extent.width, height: height)
        }
        return
            image
            .cropped(to: crop)
            .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
    }

    private static func makeGrain() -> CIImage? {
        let side = 64
        var seed: UInt32 = 0xF0CE_11E
        var bytes = [UInt8](repeating: 0, count: side * side)
        for index in bytes.indices {
            seed = 1_664_525 &* seed &+ 1_013_904_223
            bytes[index] = UInt8(truncatingIfNeeded: seed >> 24)
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
            let image = CGImage(
                width: side,
                height: side,
                bitsPerComponent: 8,
                bitsPerPixel: 8,
                bytesPerRow: side,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGBitmapInfo(rawValue: 0),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            )
        else { return nil }
        return CIImage(cgImage: image)
    }
}
