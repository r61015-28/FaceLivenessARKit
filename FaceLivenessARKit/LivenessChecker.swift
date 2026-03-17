import ARKit
import Combine

/// 3D 活體偵測邏輯
/// 利用 ARKit Face Tracking 的 3D 資訊判斷是否為真人
final class LivenessChecker: ObservableObject {

    // MARK: - 判定結果

    enum Result: String {
        case unknown   = "等待偵測..."
        case checking  = "偵測中..."
        case live      = "✅ 真人 (Live)"
        case spoof     = "❌ 偽造 (Spoof)"
    }

    @Published var result: Result = .unknown
    @Published var confidence: Float = 0
    @Published var details: [String] = []

    // MARK: - 判定閾值

    /// 需要連續多少幀通過才算 live
    private let requiredFrames = 15

    /// 累積通過幀數
    private var passedFrames = 0

    /// 深度範圍（公尺），太近或太遠都不合理
    private let distanceRange: ClosedRange<Float> = 0.20...0.80

    /// 頂點數下限（真 3D mesh 應有 1220 個頂點）
    private let minVertexCount = 1000

    /// 表情變化門檻（眨眼等）
    private var hasBlinkDetected = false
    private let blinkThreshold: Float = 0.4

    // MARK: - 主判定

    /// 每幀呼叫，傳入 ARFaceManager 的最新資料
    func evaluate(
        isFaceDetected: Bool,
        faceDistance: Float,
        headEulerAngles: SIMD3<Float>,
        blendShapes: [ARFaceAnchor.BlendShapeLocation: NSNumber],
        vertexCount: Int,
        trackingFrameCount: Int
    ) {
        guard isFaceDetected else {
            reset()
            result = .unknown
            details = ["未偵測到人臉"]
            return
        }

        result = .checking
        var checks: [String] = []
        var allPass = true

        // ── Check 1: 3D Mesh 頂點數 ──
        let vertexOK = vertexCount >= minVertexCount
        checks.append("3D 頂點：\(vertexCount) \(vertexOK ? "✓" : "✗")")
        if !vertexOK { allPass = false }

        // ── Check 2: 深度距離 ──
        let distOK = distanceRange.contains(faceDistance)
        let distCm = Int(faceDistance * 100)
        checks.append("距離：\(distCm) cm \(distOK ? "✓" : "✗")")
        if !distOK { allPass = false }

        // ── Check 3: 頭部姿態合理性 ──
        let pitchDeg = headEulerAngles.x * 180 / .pi
        let yawDeg = headEulerAngles.y * 180 / .pi
        let rollDeg = headEulerAngles.z * 180 / .pi
        let poseOK = abs(pitchDeg) < 35 && abs(yawDeg) < 35 && abs(rollDeg) < 25
        checks.append("姿態 P:\(Int(pitchDeg))° Y:\(Int(yawDeg))° R:\(Int(rollDeg))° \(poseOK ? "✓" : "✗")")
        if !poseOK { allPass = false }

        // ── Check 4: BlendShape 活性（眨眼偵測） ──
        let leftBlink = blendShapes[.eyeBlinkLeft]?.floatValue ?? 0
        let rightBlink = blendShapes[.eyeBlinkRight]?.floatValue ?? 0
        if leftBlink > blinkThreshold || rightBlink > blinkThreshold {
            hasBlinkDetected = true
        }
        checks.append("眨眼：\(hasBlinkDetected ? "已偵測 ✓" : "等待中...")")

        // ── Check 5: 表情豐富度（嘴巴、眉毛等有微動） ──
        let jawOpen: Float = blendShapes[.jawOpen]?.floatValue ?? 0
        let smileL: Float = blendShapes[.mouthSmileLeft]?.floatValue ?? 0
        let smileR: Float = blendShapes[.mouthSmileRight]?.floatValue ?? 0
        let mouthSmile: Float = (smileL + smileR) / 2
        let browUp: Float = blendShapes[.browInnerUp]?.floatValue ?? 0
        let expressionActivity: Float = jawOpen + mouthSmile + browUp + leftBlink + rightBlink
        let expressionOK = expressionActivity > 0.1
        checks.append("表情活性：\(String(format: "%.2f", expressionActivity)) \(expressionOK ? "✓" : "✗")")
        if !expressionOK { allPass = false }

        // ── Check 6: 連續追蹤穩定性 ──
        let trackOK = trackingFrameCount > 5
        checks.append("追蹤幀數：\(trackingFrameCount) \(trackOK ? "✓" : "✗")")
        if !trackOK { allPass = false }

        // ── 綜合判定 ──
        details = checks

        if allPass && hasBlinkDetected {
            passedFrames += 1
            confidence = min(Float(passedFrames) / Float(requiredFrames), 1.0)
            if passedFrames >= requiredFrames {
                result = .live
            }
        } else if allPass {
            // 全通過但還沒眨眼
            confidence = Float(passedFrames) / Float(requiredFrames) * 0.8
        } else {
            // 有不通過 → 可能是 spoof
            passedFrames = max(0, passedFrames - 2)
            confidence = max(0, confidence - 0.05)

            // 如果持續很多幀都不通過 → 判定 spoof
            if trackingFrameCount > 60 && passedFrames == 0 {
                result = .spoof
            }
        }
    }

    func reset() {
        passedFrames = 0
        confidence = 0
        hasBlinkDetected = false
        result = .unknown
        details = []
    }
}
