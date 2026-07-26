import Foundation

struct AICompositionResponse: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let primary: AICompositionPlan
    let alternatives: [AICompositionPlan]

    var plans: [AICompositionPlan] { [primary] + alternatives }

    var isValid: Bool {
        schemaVersion == 1
            && alternatives.count == 2
            && primary.id == "primary"
            && alternatives[0].id == "safe"
            && alternatives[1].id == "creative"
            && plans.allSatisfy(\.isValid)
    }
}

struct AICompositionPlan: Codable, Equatable, Sendable {
    enum Movement: String, Codable, Sendable {
        case none, left, right, up, down, closer, farther, level
    }

    enum Angle: String, Codable, Sendable {
        case eyeLevel = "eye-level"
        case slightlyHigh = "slightly-high"
        case slightlyLow = "slightly-low"
    }

    let id: String
    let instructionVi: String
    let instructionEn: String
    let target: NormalizedRect
    let movement: Movement
    let angle: Angle
    let zoom: Double
    let exposureBias: Double
    let flash: CameraFlash
    let presetIDs: [String]
    let poseVi: String
    let poseEn: String

    var instruction: String {
        Locale.current.language.languageCode?.identifier == "vi" ? instructionVi : instructionEn
    }

    var pose: String {
        Locale.current.language.languageCode?.identifier == "vi" ? poseVi : poseEn
    }

    fileprivate var isValid: Bool {
        let knownPresets = Set(FocelleOriginals.all.map(\.id))
        return !instructionVi.isEmpty && instructionVi.count <= 120
            && !instructionEn.isEmpty && instructionEn.count <= 120
            && !poseVi.isEmpty && poseVi.count <= 160
            && !poseEn.isEmpty && poseEn.count <= 160
            && target.isValid
            && (1...5).contains(zoom)
            && (-2...2).contains(exposureBias)
            && (1...3).contains(presetIDs.count)
            && presetIDs.allSatisfy(knownPresets.contains)
    }
}

struct NormalizedRect: Codable, Equatable, Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    init(_ rect: CGRect) {
        x = rect.origin.x
        y = rect.origin.y
        width = rect.width
        height = rect.height
    }

    var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }

    fileprivate var isValid: Bool {
        (0...1).contains(x) && (0...1).contains(y)
            && (0.01...1).contains(width) && (0.01...1).contains(height)
            && x + width <= 1 && y + height <= 1
    }
}

enum AIClientError: String, Error, Equatable, Sendable {
    case unavailable
    case offline
    case timedOut
    case rateLimited
    case invalidResponse
    case quotaExhausted
    case server
}

enum AIClient {
    static func analyze(_ preview: Data, measurement: SceneMeasurement?) async throws
        -> AICompositionResponse
    {
        let deviceId = await FocelleAPI.deviceID()
        let requestBody = AnalyzeRequest(
            deviceId: deviceId,
            requestId: UUID().uuidString.replacingOccurrences(of: "-", with: ""),
            timezoneOffsetMinutes: TimeZone.current.secondsFromGMT() / 60,
            locale: Locale.current.language.languageCode?.identifier == "vi" ? "vi" : "en",
            image: .init(mimeType: "image/jpeg", data: preview.base64EncodedString()),
            measurements: measurement.map(AnalyzeRequest.Measurements.init)
        )

        var request = try await FocelleAPI.request(path: "v1/analyze", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(requestBody)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw AIClientError.invalidResponse
            }
            if http.statusCode == 429 || http.statusCode == 503 {
                throw AIClientError.rateLimited
            }
            if http.statusCode == 402 {
                throw AIClientError.quotaExhausted
            }
            guard http.statusCode == 200,
                let envelope = try? JSONDecoder().decode(AnalyzeResponse.self, from: data),
                envelope.ok,
                let result = envelope.result,
                result.isValid
            else {
                throw AIClientError.server
            }
            return result
        } catch let error as AIClientError {
            throw error
        } catch let error as URLError {
            throw error.code == .timedOut ? AIClientError.timedOut : AIClientError.offline
        } catch {
            throw AIClientError.invalidResponse
        }
    }
}

private struct AnalyzeRequest: Encodable {
    struct Image: Encodable {
        let mimeType: String
        let data: String
    }

    struct Measurements: Encodable {
        let subject: NormalizedRect?
        let faces: Int
        let poses: Int
        let horizonAngle: Double?
        let exposure: Double

        init(_ measurement: SceneMeasurement) {
            subject = measurement.primaryRect.map(NormalizedRect.init)
            faces = measurement.faceRects.count
            poses = measurement.bodyPoseCount
            horizonAngle = measurement.horizonAngle
            exposure = measurement.exposure
        }
    }

    let deviceId: String
    let requestId: String
    let timezoneOffsetMinutes: Int
    let locale: String
    let image: Image
    let measurements: Measurements?
}

private struct AnalyzeResponse: Decodable {
    let ok: Bool
    let result: AICompositionResponse?
}
