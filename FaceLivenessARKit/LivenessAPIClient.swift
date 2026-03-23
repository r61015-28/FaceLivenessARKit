import UIKit

struct ModelResult {
    let prediction: String
    let confidence: Float
    let liveProbability: Float
    let spoofProbability: Float
    let isLive: Bool
}

struct YoloResponse {
    let faceDetected: Bool
    let isLive: Bool?
    let confidence: Float
    let liveProbability: Float
    let spoofProbability: Float
    let message: String?
    let mn3: ModelResult?
    let mn3Custom: ModelResult?
}

enum YoloError: Error {
    case noFace
    case serverError(String)
    case networkError(Error)
}

final class LivenessAPIClient {

    static let shared = LivenessAPIClient()

    // PoC 用本機 server，正式環境換成 HTTPS 域名
    private let baseURL = "http://omninano.myds.me:8001"

    func detect(image: UIImage) async throws -> YoloResponse {
        guard let url = URL(string: "\(baseURL)/api/detect") else {
            throw YoloError.serverError("Invalid URL")
        }

        guard let imageData = image.jpegData(compressionQuality: 0.85) else {
            throw YoloError.serverError("Failed to encode image")
        }

        let boundary = UUID().uuidString
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"image\"; filename=\"face.jpg\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
        body.append(imageData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw YoloError.serverError("HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw YoloError.serverError("Invalid JSON")
        }

        let faceDetected = json["face_detected"] as? Bool ?? false
        guard faceDetected else {
            throw YoloError.noFace
        }

        let probs = json["probabilities"] as? [String: Double] ?? [:]

        let models = json["models"] as? [String: Any] ?? [:]

        // 解析 mn3 結果
        var mn3Result: ModelResult? = nil
        if let mn3 = models["mn3"] as? [String: Any],
           let mn3Probs = mn3["probabilities"] as? [String: Double] {
            mn3Result = ModelResult(
                prediction: mn3["prediction"] as? String ?? "unknown",
                confidence: Float(mn3["confidence"] as? Double ?? 0),
                liveProbability: Float(mn3Probs["live"] ?? 0),
                spoofProbability: Float(mn3Probs["spoof"] ?? 0),
                isLive: mn3["is_live"] as? Bool ?? false
            )
        }

        // 解析 mn3_custom 結果
        var mn3CustomResult: ModelResult? = nil
        if let mc = models["mn3_custom"] as? [String: Any],
           let mcProbs = mc["probabilities"] as? [String: Double] {
            mn3CustomResult = ModelResult(
                prediction: mc["prediction"] as? String ?? "unknown",
                confidence: Float(mc["confidence"] as? Double ?? 0),
                liveProbability: Float(mcProbs["live"] ?? 0),
                spoofProbability: Float(mcProbs["spoof"] ?? 0),
                isLive: mc["is_live"] as? Bool ?? false
            )
        }

        return YoloResponse(
            faceDetected: faceDetected,
            isLive: json["is_live"] as? Bool,
            confidence: Float(json["confidence"] as? Double ?? 0),
            liveProbability: Float(probs["live"] ?? 0),
            spoofProbability: Float(probs["spoof"] ?? 0),
            message: json["message"] as? String,
            mn3: mn3Result,
            mn3Custom: mn3CustomResult
        )
    }
}
