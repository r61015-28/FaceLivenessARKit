import UIKit

struct YoloResponse {
    let faceDetected: Bool
    let isLive: Bool?
    let confidence: Float
    let liveProbability: Float
    let spoofProbability: Float
    let message: String?
}

enum YoloError: Error {
    case noFace
    case serverError(String)
    case networkError(Error)
}

final class LivenessAPIClient {

    static let shared = LivenessAPIClient()

    // PoC 用本機 server，正式環境換成 HTTPS 域名
    private let baseURL = "http://192.168.1.115:8002"

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
        return YoloResponse(
            faceDetected: faceDetected,
            isLive: json["is_live"] as? Bool,
            confidence: Float(json["confidence"] as? Double ?? 0),
            liveProbability: Float(probs["live"] ?? 0),
            spoofProbability: Float(probs["spoof"] ?? 0),
            message: json["message"] as? String
        )
    }
}
