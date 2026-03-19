import ARKit
import Combine

/// 3D 活體偵測邏輯（倒數 + 眼球追蹤挑戰模式）
///
/// 偵測流程：
/// 1. 5 秒倒數，分 3 個 phase，每 phase 在螢幕角落顯示黃色圓點
/// 2. 圓點位置含跨對角，引導用戶眼球移動
/// 3. 結束後綜合判定：基本 check + (眼球追蹤 OR 表情微動) → Live/Spoof
/// 4. 凍結顯示最終結果 + 各項通過率
final class LivenessChecker: ObservableObject {

    // MARK: - 型別

    enum Result: String {
        case unknown = "等待開始"
        case live    = "✅ 真人 (Live)"
        case spoof   = "❌ 偽造 (Spoof)"
    }

    enum Phase: Equatable {
        case idle
        case counting(remaining: Double)
        case done
    }

    enum Corner: CaseIterable, Equatable, Hashable {
        case topLeft, topRight, bottomLeft, bottomRight
        case topCenter, bottomCenter

        var label: String {
            switch self {
            case .topLeft:      return "左上 ↖"
            case .topRight:     return "右上 ↗"
            case .bottomLeft:   return "左下 ↙"
            case .bottomRight:  return "右下 ↘"
            case .topCenter:    return "正上方 ↑"
            case .bottomCenter: return "正下方 ↓"
            }
        }

        /// 期望視線方向（x: 負=左 正=右, y: 負=下 正=上）
        var expectedGaze: SIMD2<Float> {
            switch self {
            case .topLeft:      return SIMD2<Float>(-1,  1)
            case .topRight:     return SIMD2<Float>( 1,  1)
            case .bottomLeft:   return SIMD2<Float>(-1, -1)
            case .bottomRight:  return SIMD2<Float>( 1, -1)
            case .topCenter:    return SIMD2<Float>( 0,  1)
            case .bottomCenter: return SIMD2<Float>( 0, -1)
            }
        }
    }

    // MARK: - Published 狀態

    @Published var result: Result = .unknown
    @Published var phase: Phase = .idle
    @Published var currentDot: Corner? = nil
    @Published var liveDetails: [String] = []
    @Published var finalDetails: [String] = []

    /// finalize() 後保存的原始數值，供 log 使用
    private(set) var lastMetrics: [String: Float] = [:]
    /// 最後一次 saveLog 的 timestamp（供撤銷用）
    private(set) var lastSavedTimestamp: String?

    // MARK: - 設定

    let countdownDuration: Double = 2.0
    private let phaseDuration: Double
    private let distanceRange: ClosedRange<Float> = 0.20...0.80
    private let minVertexCount = 1000

    // MARK: - 內部狀態

    private var dotSequence: [Corner] = []
    private var currentDotIndex = 0
    private var elapsed: Double = 0
    private var totalFrames = 0
    @Published private(set) var blinkDetected = false

    /// 基本 check 各自通過幀數
    private var vertexPassCount = 0
    private var distancePassCount = 0
    private var posePassCount = 0
    private var trackPassCount = 0

    /// 每幀的頭部 yaw/pitch（度）
    private var headYawHistory:   [Float] = []
    private var headPitchHistory: [Float] = []

    /// 每幀的眼球 gaze（與頭部分開記錄）
    private var gazeXHistory: [Float] = []
    private var gazeYHistory: [Float] = []
    private var gazePhaseHistory: [Int] = []

    /// 表情 blendshape 時序紀錄（只放臉部表情，不含 gaze，避免移照片時被騙）
    private var blendShapeHistory: [[Float]] = []

    // MARK: - Init

    init() {
        phaseDuration = countdownDuration / 2.0  // 2 個圓點 → 2 個 phase
    }

    // MARK: - 控制

    func startCountdown() {
        dotSequence = Self.generateDotSequence()
        currentDotIndex = 0
        elapsed = 0
        totalFrames = 0
        blinkDetected = false
        vertexPassCount = 0
        distancePassCount = 0
        posePassCount = 0
        trackPassCount = 0
        headYawHistory = []
        headPitchHistory = []
        gazeXHistory = []
        gazeYHistory = []
        gazePhaseHistory = []
        blendShapeHistory = []
        result = .unknown
        liveDetails = []
        finalDetails = []
        currentDot = dotSequence[0]
        phase = .counting(remaining: countdownDuration)
    }

    func reset() {
        phase = .idle
        result = .unknown
        liveDetails = []
        finalDetails = []
        currentDot = nil
    }

    /// 由 ContentView Timer 每 0.1 秒呼叫
    func tick(dt: Double) {
        guard case .counting(let remaining) = phase else { return }
        elapsed += dt

        // 切換圓點 phase（最多 1，對應 2 個圓點）
        let phaseIdx = min(Int(elapsed / phaseDuration), 1)
        if phaseIdx != currentDotIndex && phaseIdx < dotSequence.count {
            currentDotIndex = phaseIdx
            currentDot = dotSequence[phaseIdx]
        }

        let next = remaining - dt
        if next <= 0 {
            finalize()
        } else {
            phase = .counting(remaining: next)
        }
    }

    // MARK: - 每幀評估

    func evaluate(
        isFaceDetected: Bool,
        faceDistance: Float,
        headEulerAngles: SIMD3<Float>,
        blendShapes: [ARFaceAnchor.BlendShapeLocation: NSNumber],
        vertexCount: Int,
        trackingFrameCount: Int
    ) {
        guard case .counting = phase else { return }
        guard isFaceDetected else {
            liveDetails = ["⚠️ 未偵測到人臉，請對準鏡頭"]
            return
        }

        totalFrames += 1
        var checks: [String] = []

        // ── Check 1: 3D Mesh 頂點數 ──
        let vertexOK = vertexCount >= minVertexCount
        if vertexOK { vertexPassCount += 1 }
        checks.append("3D 頂點：\(vertexCount)  \(vertexOK ? "✓" : "✗")")

        // ── Check 2: 深度距離 ──
        let distOK = distanceRange.contains(faceDistance)
        if distOK { distancePassCount += 1 }
        checks.append("距離：\(Int(faceDistance * 100)) cm  \(distOK ? "✓" : "✗")")

        // ── Check 3: 頭部姿態 ──
        let pitchDeg = headEulerAngles.x * 180 / .pi
        let yawDeg   = headEulerAngles.y * 180 / .pi
        let rollDeg  = headEulerAngles.z * 180 / .pi
        let poseOK = abs(pitchDeg) < 35 && abs(yawDeg) < 35 && abs(rollDeg) < 25
        if poseOK { posePassCount += 1 }
        checks.append("姿態 P:\(Int(pitchDeg))° Y:\(Int(yawDeg))° R:\(Int(rollDeg))°  \(poseOK ? "✓" : "✗")")

        // ── Check 4: 追蹤穩定性 ──
        let trackOK = trackingFrameCount > 5
        if trackOK { trackPassCount += 1 }
        checks.append("追蹤穩定：\(trackingFrameCount) 幀  \(trackOK ? "✓" : "✗")")

        // ── 眼球視線 + 頭部姿態分別記錄 ──
        let gazeX: Float = Self.gazeX(from: blendShapes)
        let gazeY: Float = Self.gazeY(from: blendShapes)
        gazeXHistory.append(gazeX)
        gazeYHistory.append(gazeY)
        gazePhaseHistory.append(currentDotIndex)
        headYawHistory.append(yawDeg)
        headPitchHistory.append(pitchDeg)

        let gazeDir = Self.gazeDirectionText(gazeX: gazeX, gazeY: gazeY)
        checks.append("👁️ 視線：\(gazeDir)　請看 \(dotSequence[currentDotIndex].label)")
        checks.append("眨眼：\(blinkDetected ? "✓ 已偵測" : "⬜ 請眨眼一次")")

        // ── 表情微動記錄（只含臉部表情，不含 gaze）──
        let leftBlink:  Float = blendShapes[.eyeBlinkLeft]?.floatValue  ?? 0
        let rightBlink: Float = blendShapes[.eyeBlinkRight]?.floatValue ?? 0
        if leftBlink > 0.15 || rightBlink > 0.15 { blinkDetected = true }

        let jawOpen: Float = blendShapes[.jawOpen]?.floatValue         ?? 0
        let smileL:  Float = blendShapes[.mouthSmileLeft]?.floatValue  ?? 0
        let smileR:  Float = blendShapes[.mouthSmileRight]?.floatValue ?? 0
        let browUp:  Float = blendShapes[.browInnerUp]?.floatValue     ?? 0
        blendShapeHistory.append([leftBlink, rightBlink, jawOpen, smileL, smileR, browUp])

        liveDetails = checks
    }

    // MARK: - 最終判定

    private func finalize() {
        phase = .done
        currentDot = nil

        guard totalFrames > 0 else {
            result = .spoof
            finalDetails = ["偵測期間未偵測到人臉"]
            return
        }

        var summary: [String] = []

        // 基本 check 通過率
        let rates: [(String, Float)] = [
            ("3D 頂點",   Float(vertexPassCount)   / Float(totalFrames)),
            ("距離範圍",  Float(distancePassCount)  / Float(totalFrames)),
            ("頭部姿態",  Float(posePassCount)      / Float(totalFrames)),
            ("追蹤穩定",  Float(trackPassCount)     / Float(totalFrames)),
        ]
        for (name, rate) in rates {
            summary.append("\(name)：\(pct(rate))  \(rate >= 0.6 ? "✓" : "✗")")
        }
        let basicPass = rates.allSatisfy { $0.1 >= 0.6 }

        // 眨眼（主判定：照片永遠無法眨眼）
        summary.append("眨眼：\(blinkDetected ? "✓ 偵測到" : "✗ 無")")

        // 眉毛活動（自然臉部微動，靜止照片無法產生）
        let maxBrowUp = blendShapeHistory.map { $0[5] }.max() ?? 0
        summary.append("眉毛活動：\(String(format: "%.3f", maxBrowUp))  \(maxBrowUp >= 0.05 ? "✓" : "✗")")

        // 眼球移動量（移動照片 = 全臉移動 → 值爆高；真人只動眼球 → 值適中）
        let gazeMovement = computeTotalGazeMovement()
        summary.append("👁️ 眼球移動量：\(String(format: "%.3f", gazeMovement))  \(gazeMovement < 0.65 ? "✓ 正常" : "✗ 過高")")

        // 參考指標
        let stillGazeVar = computeStillHeadGazeVariance()
        summary.append("靜止眼動：\(String(format: "%.4f", stillGazeVar))（參考）")

        let variation = computeTemporalVariation()
        summary.append("表情微動：\(String(format: "%.4f", variation))（參考）")

        summary.append("─────────────────")
        summary.append("共 \(totalFrames) 幀")

        // 最終判定：眨眼為加分項（非必要條件）
        let isLive = basicPass

        result = isLive ? .live : .spoof
        summary.append("判定：\(result.rawValue)")
        finalDetails = summary

        // 保存原始數值供 log
        lastMetrics = [
            "vertexRate":   rates[0].1,
            "distanceRate": rates[1].1,
            "poseRate":     rates[2].1,
            "trackRate":    rates[3].1,
            "blinkDetected": blinkDetected ? 1.0 : 0.0,
            "gazeMovement": gazeMovement,
            "stillGazeVar": stillGazeVar,
            "variation":    variation,
            "totalFrames":  Float(totalFrames),
            "maxBlinkL":    blendShapeHistory.map { $0[0] }.max() ?? 0,
            "maxBlinkR":    blendShapeHistory.map { $0[1] }.max() ?? 0,
            "maxBrowUp":    blendShapeHistory.map { $0[5] }.max() ?? 0,
        ]
    }

    // MARK: - 資料標記 Log

    /// 目前 CSV 已有幾筆資料（不含 header）
    func logCount() -> Int {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let logFile = docs.appendingPathComponent("liveness_log.csv")
        guard let content = try? String(contentsOf: logFile, encoding: .utf8) else { return 0 }
        return content.components(separatedBy: "\n").filter { !$0.isEmpty && !$0.hasPrefix("timestamp") }.count
    }

    /// 將本次偵測的所有特徵數值 + 人工標記寫入 CSV
    /// groundTruth: "real" 或 "spoof"
    func saveLog(groundTruth: String, yoloPrediction: String? = nil, yoloLiveProb: Float? = nil) {
        let m = lastMetrics
        guard !m.isEmpty else { return }

        let header = "timestamp,groundTruth,prediction,vertexRate,distanceRate,poseRate,trackRate,blinkDetected,maxBlinkL,maxBlinkR,maxBrowUp,gazeMovement,stillGazeVar,variation,totalFrames,yoloPrediction,yoloLiveProb\n"

        let ts = ISO8601DateFormatter().string(from: Date())
        let prediction = result == .live ? "live" : "spoof"
        let yoloPred = yoloPrediction ?? "N/A"
        let yoloProb = yoloLiveProb.map { String(format: "%.4f", $0) } ?? "N/A"
        let row = [
            ts, groundTruth, prediction,
            f(m["vertexRate"]), f(m["distanceRate"]), f(m["poseRate"]), f(m["trackRate"]),
            f(m["blinkDetected"]), f(m["maxBlinkL"]), f(m["maxBlinkR"]), f(m["maxBrowUp"]),
            f(m["gazeMovement"]), f(m["stillGazeVar"]), f(m["variation"]), f(m["totalFrames"]),
            yoloPred, yoloProb,
        ].joined(separator: ",") + "\n"

        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let logFile = docs.appendingPathComponent("liveness_log.csv")

        if !FileManager.default.fileExists(atPath: logFile.path) {
            try? header.write(to: logFile, atomically: true, encoding: .utf8)
        }

        if let handle = try? FileHandle(forWritingTo: logFile) {
            handle.seekToEndOfFile()
            handle.write(row.data(using: .utf8)!)
            handle.closeFile()
        }

        lastSavedTimestamp = ts
    }

    /// 移除最後一筆 log（撤銷用）
    func removeLastLog() {
        guard let ts = lastSavedTimestamp else { return }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let logFile = docs.appendingPathComponent("liveness_log.csv")
        guard let content = try? String(contentsOf: logFile, encoding: .utf8) else {
            lastSavedTimestamp = nil
            return
        }
        var lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
        lines.removeAll { $0.hasPrefix(ts) }
        let newContent = lines.joined(separator: "\n") + "\n"
        try? newContent.write(to: logFile, atomically: true, encoding: .utf8)
        lastSavedTimestamp = nil
    }

    private func f(_ v: Float?) -> String {
        guard let v = v else { return "0" }
        return String(format: "%.4f", v)
    }

    // MARK: - 眼球移動總量

    /// 累計每幀 gazeX 的絕對位移量
    /// 真人追圓點：眼球左右大幅移動，累計量高（≥ 0.5）
    /// 照片：gaze 估算只有 noise，累計量低（< 0.2）
    private func computeTotalGazeMovement() -> Float {
        guard gazeXHistory.count > 1 else { return 0 }
        var total: Float = 0
        for i in 1..<gazeXHistory.count {
            total += abs(gazeXHistory[i] - gazeXHistory[i - 1])
        }
        return total
    }

    // MARK: - 頭靜止期間眼球微動

    /// 關鍵算法：找出頭部幾乎不動的幀，計算這段期間 gaze 的變化量。
    ///
    /// 真人：頭靜止時眼睛還是會跟著圓點或自然微動 → 值較高
    /// 照片：頭靜止 = 照片靜止 = gaze 完全不變 → 值接近 0
    /// 攻擊（移照片）：頭在動時 gaze 也動，但頭靜止時 gaze 不動 → 值低
    private func computeStillHeadGazeVariance() -> Float {
        let n = headYawHistory.count
        guard n > 10 else { return 0 }

        // 找頭部靜止的幀（相鄰幀 yaw + pitch 變化 < 0.8 度）
        var stillGazeX: [Float] = []
        var stillGazeY: [Float] = []

        for i in 1..<n {
            let deltaYaw   = abs(headYawHistory[i]   - headYawHistory[i - 1])
            let deltaPitch = abs(headPitchHistory[i] - headPitchHistory[i - 1])
            if deltaYaw < 0.8 && deltaPitch < 0.8 {
                stillGazeX.append(gazeXHistory[i])
                stillGazeY.append(gazeYHistory[i])
            }
        }

        guard stillGazeX.count > 5 else { return 0 }

        // 計算靜止期間 gaze 的標準差
        func stdDev(_ values: [Float]) -> Float {
            let mean = values.reduce(0, +) / Float(values.count)
            let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Float(values.count)
            return sqrt(variance)
        }

        return stdDev(stillGazeX) + stdDev(stillGazeY)
    }

    // MARK: - 視線挑戰相關性

    /// 每個 phase 的平均視線方向是否與對應圓點的期望方向一致
    ///
    /// 真人追蹤圓點：眼球主動往圓點方向轉 → 至少 2/3 phase 方向符合
    /// 照片被隨意移動：gaze 方向隨機，不會系統性對齊圓點方向
    private func computeGazeChallengeCorrelation() -> Float {
        guard gazeYHistory.count >= 6 && dotSequence.count == 2 else { return 0 }
        var matchCount = 0
        for phaseIdx in 0..<2 {
            let indices = gazePhaseHistory.indices.filter { gazePhaseHistory[$0] == phaseIdx }
            guard indices.count >= 3 else { continue }
            let avgY = indices.map { gazeYHistory[$0] }.reduce(0, +) / Float(indices.count)
            let exp = dotSequence[phaseIdx].expectedGaze
            let yMatch = exp.y > 0 ? avgY > 0.01 : avgY < -0.01
            if yMatch { matchCount += 1 }
        }
        return Float(matchCount) / 2.0
    }

    // MARK: - 表情微動

    /// 計算 blendshape 在 5 秒內的平均變化幅度（max - min）
    private func computeTemporalVariation() -> Float {
        guard blendShapeHistory.count > 10 else { return 0 }
        let dims = blendShapeHistory[0].count
        var totalRange: Float = 0
        for d in 0..<dims {
            let values = blendShapeHistory.map { $0[d] }
            totalRange += (values.max() ?? 0) - (values.min() ?? 0)
        }
        return totalRange / Float(dims)
    }

    // MARK: - 工具

    /// 固定上→下順序，誘發自然眨眼
    /// 從正上方跳到正下方是最自然的視線移動，容易觸發眨眼
    static func generateDotSequence() -> [Corner] {
        return [.topCenter, .bottomCenter]
    }

    /// 水平視線：正=看右，負=看左
    static func gazeX(from bs: [ARFaceAnchor.BlendShapeLocation: NSNumber]) -> Float {
        let inL  = bs[.eyeLookInLeft]?.floatValue   ?? 0  // 左眼往鼻子 → 看右
        let outR = bs[.eyeLookOutRight]?.floatValue ?? 0  // 右眼往外 → 看右
        let outL = bs[.eyeLookOutLeft]?.floatValue  ?? 0  // 左眼往外 → 看左
        let inR  = bs[.eyeLookInRight]?.floatValue  ?? 0  // 右眼往鼻子 → 看左
        return (inL + outR) / 2 - (outL + inR) / 2
    }

    /// 垂直視線：正=看上，負=看下
    static func gazeY(from bs: [ARFaceAnchor.BlendShapeLocation: NSNumber]) -> Float {
        let upL   = bs[.eyeLookUpLeft]?.floatValue    ?? 0
        let upR   = bs[.eyeLookUpRight]?.floatValue   ?? 0
        let downL = bs[.eyeLookDownLeft]?.floatValue  ?? 0
        let downR = bs[.eyeLookDownRight]?.floatValue ?? 0
        return (upL + upR) / 2 - (downL + downR) / 2
    }

    static func gazeDirectionText(gazeX: Float, gazeY: Float) -> String {
        let h = gazeX > 0.05 ? "右" : (gazeX < -0.05 ? "左" : "中")
        let v = gazeY > 0.05 ? "上" : (gazeY < -0.05 ? "下" : "中")
        return "\(v)\(h)"
    }

    private func pct(_ v: Float) -> String { "\(Int(v * 100))%" }
}
