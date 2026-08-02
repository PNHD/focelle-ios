import Foundation

struct AICompositionResponse: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let primary: AICompositionPlan
    let alternatives: [AICompositionPlan]

    var plans: [AICompositionPlan] { [primary] + alternatives }

    var isValid: Bool {
        schemaVersion == 2
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
    // Schema 2 carries one instruction and one pose, already written in the
    // language the request asked for.
    let instruction: String
    let target: NormalizedRect
    let movement: Movement
    let angle: Angle
    let zoom: Double
    let exposureBias: Double
    let flash: CameraFlash
    let presetIDs: [String]
    let pose: String

    fileprivate var isValid: Bool {
        let knownPresets = Set(FocelleOriginals.all.map(\.id))
        return !instruction.isEmpty && instruction.count <= 120
            && !pose.isEmpty && pose.count <= 160
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
    // The backend only accepts letters plus one hyphen, so anything unexpected
    // falls back to English rather than being rejected on arrival. Only Chinese
    // carries its script: Foundation may report a likely script for any locale,
    // and "en-Latn" would be noise the model does not need.
    static func languageTag(for locale: Locale = .current) -> String {
        guard let code = locale.language.languageCode?.identifier.lowercased(),
            (2...3).contains(code.count),
            code.allSatisfy(\.isLetter)
        else { return "en" }
        guard code == "zh",
            let script = locale.language.script?.identifier,
            (2...8).contains(script.count),
            script.allSatisfy(\.isLetter)
        else { return code }
        return "\(code)-\(script)"
    }

    static func analyze(_ preview: Data, measurement: SceneMeasurement?) async throws
        -> AICompositionResponse
    {
        let deviceId = await FocelleAPI.deviceID()
        let requestBody = AnalyzeRequest(
            deviceId: deviceId,
            requestId: UUID().uuidString.replacingOccurrences(of: "-", with: ""),
            timezoneOffsetMinutes: TimeZone.current.secondsFromGMT() / 60,
            locale: languageTag(),
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
