@preconcurrency import CoreVideo
import Foundation
@preconcurrency import Vision

final class OnDeviceAnalyzer: @unchecked Sendable {
    private let queue = DispatchQueue(
        label: "com.pnhd.focelle.analysis",
        qos: .userInitiated
    )

    func analyze(
        _ buffer: CVPixelBuffer,
        completion: @escaping @Sendable (SceneMeasurement?) -> Void
    ) {
        nonisolated(unsafe) let pixelBuffer = buffer
        queue.async {
            let faces = VNDetectFaceCaptureQualityRequest()
            let humans = VNDetectHumanRectanglesRequest()
            humans.upperBodyOnly = false
            let bodyPoses = VNDetectHumanBodyPoseRequest()
            let horizon = VNDetectHorizonRequest()
            let saliency = VNGenerateAttentionBasedSaliencyImageRequest()
            let handler = VNImageRequestHandler(
                cvPixelBuffer: pixelBuffer,
                orientation: .up
            )

            do {
                try handler.perform([faces, humans, bodyPoses, horizon, saliency])
                completion(
                    SceneMeasurement(
                        subjectRect: humans.results?
                            .max { Self.area($0.boundingBox) < Self.area($1.boundingBox) }?
                            .boundingBox,
                        faceRects: faces.results?.map(\.boundingBox) ?? [],
                        bodyPoseCount: bodyPoses.results?.count ?? 0,
                        salientRect: saliency.results?
                            .first?
                            .salientObjects?
                            .max { Self.area($0.boundingBox) < Self.area($1.boundingBox) }?
                            .boundingBox,
                        horizonAngle: horizon.results?.first.map { Double($0.angle) },
                        exposure: Self.averageLuma(pixelBuffer),
                        faceReady: faces.results?.allSatisfy {
                            ($0.faceCaptureQuality ?? 0) >= 0.35
                        } ?? true,
                        timestamp: ProcessInfo.processInfo.systemUptime
                    )
                )
            } catch {
                completion(nil)
            }
        }
    }

    private static func area(_ rect: CGRect) -> CGFloat {
        rect.width * rect.height
    }

    private static func averageLuma(_ buffer: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA,
              let base = CVPixelBufferGetBaseAddress(buffer)
        else { return 0.5 }

        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        let stride = max(min(width, height) / 24, 1)
        var total = 0.0
        var count = 0

        for y in Swift.stride(from: 0, to: height, by: stride) {
            for x in Swift.stride(from: 0, to: width, by: stride) {
                let pixel = bytes + y * bytesPerRow + x * 4
                total += (
                    0.0722 * Double(pixel[0])
                        + 0.7152 * Double(pixel[1])
                        + 0.2126 * Double(pixel[2])
                ) / 255
                count += 1
            }
        }
        return count == 0 ? 0.5 : total / Double(count)
    }
}
