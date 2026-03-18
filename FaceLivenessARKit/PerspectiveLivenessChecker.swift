import Foundation
import Combine

/// 透視畸變活體偵測（一般 2D 相機版）
///
/// 偵測流程：
/// 1. 引導使用者把臉對準框 → 偵測到臉後自動開始
/// 2. 引導使用者靠近（臉佔比從 ~35% → ~60%）
/// 3. 靠近過程中記錄「鼻尖 vs 臉輪廓」的位移比 → 透視畸變分析
/// 4. 同時偵測 EAR 眨眼
/// 5. 結束後輸出 distortion_score + blink_weight
final class PerspectiveLivenessChecker: ObservableObject {

    // MARK: - 型別

    enum Result: String {
        case unknown  = "等待開始"
        case live     = "✅ 真人 (Live)"
        case spoof    = "❌ 偽造 (Spoof)"
    }

    enum Phase: Equatable {
        case idle
        case aligning          // 等待使用者把臉對準
        case zoomIn(progress: Double)  // 靠近中（0.0 ~ 1.0）
        case done
    }

    // MARK: - Published 狀態

    @Published var result: Result = .unknown
    @Published var phase: Phase = .idle
    @Published var statusText: String = ""
    @Published var liveDetails: [String] = []
    @Published var finalDetails: [String] = []

    /// 給後端的分數
    private(set) var distortionScore: Float = 0
    private(set) var blinkWeight: Float = 0

    // MARK: - 設定

    /// 臉寬佔比目標範圍
    private let startWidthRatio: CGFloat = 0.30    // 開始收集（臉夠大才開始）
    private let targetWidthRatio: CGFloat = 0.55   // 目標靠近程度
    private let maxDuration: Double = 3.0          // 最長等待時間（秒）

    /// EAR 閾值
    private let earBlinkThreshold: Float = 0.20    // 低於此值 = 眼睛閉合
    private let earBlinkConsecFrames = 2           // 連續幾幀才算眨眼

    // MARK: - 內部狀態

    private var elapsed: Double = 0
    private var totalFrames = 0

    /// 透視畸變：記錄每幀的特徵點位移
    private struct FrameRecord {
        let noseTipX: Float
        let noseTipY: Float
        let leftContourX: Float
        let leftContourY: Float
        let rightContourX: Float
        let rightContourY: Float
        let faceWidth: Float
    }
    private var frameRecords: [FrameRecord] = []

    /// EAR 歷史
    private var earHistory: [Float] = []
    private var blinkDetected = false
    private var blinkCounter = 0

    /// 起始臉寬（用於計算靠近進度）
    private var initialFaceWidth: CGFloat?

    // MARK: - 控制

    func startDetection() {
        elapsed = 0
        totalFrames = 0
        frameRecords = []
        earHistory = []
        blinkDetected = false
        blinkCounter = 0
        initialFaceWidth = nil
        result = .unknown
        liveDetails = []
        finalDetails = []
        distortionScore = 0
        blinkWeight = 0
        phase = .aligning
        statusText = "請將臉放入框中"
    }

    func reset() {
        phase = .idle
        result = .unknown
        statusText = ""
        liveDetails = []
        finalDetails = []
    }

    /// Timer 每 0.1 秒呼叫
    func tick(dt: Double) {
        guard phase != .idle && phase != .done else { return }

        elapsed += dt

        // 超時保護
        if elapsed > maxDuration {
            if frameRecords.count >= 10 {
                finalize()
            } else {
                result = .spoof
                finalDetails = ["偵測超時，資料不足（\(frameRecords.count) 幀）"]
                phase = .done
            }
        }
    }

    // MARK: - 每幀評估

    func evaluate(
        isFaceDetected: Bool,
        faceWidthRatio: CGFloat,
        noseTip: CGPoint,
        leftContour: CGPoint,
        rightContour: CGPoint,
        leftEyePoints: [CGPoint],
        rightEyePoints: [CGPoint]
    ) {
        guard phase != .idle && phase != .done else { return }
        guard isFaceDetected else {
            statusText = "⚠️ 未偵測到人臉"
            liveDetails = [statusText]
            return
        }

        // ── 對齊階段：等臉夠大 ──
        if case .aligning = phase {
            if faceWidthRatio >= startWidthRatio {
                initialFaceWidth = faceWidthRatio
                phase = .zoomIn(progress: 0)
                statusText = "請緩慢靠近手機"
            } else {
                statusText = "請再靠近一些（\(pct(faceWidthRatio)) / \(pct(startWidthRatio))）"
                liveDetails = [statusText]
                return
            }
        }

        // ── 靠近階段：收集資料 ──
        guard case .zoomIn = phase else { return }

        totalFrames += 1

        // 計算靠近進度
        let startW = initialFaceWidth ?? startWidthRatio
        let progress = min(max(
            Double(faceWidthRatio - startW) / Double(targetWidthRatio - startW),
            0
        ), 1.0)
        phase = .zoomIn(progress: progress)

        // 記錄特徵點
        let record = FrameRecord(
            noseTipX:      Float(noseTip.x),
            noseTipY:      Float(noseTip.y),
            leftContourX:  Float(leftContour.x),
            leftContourY:  Float(leftContour.y),
            rightContourX: Float(rightContour.x),
            rightContourY: Float(rightContour.y),
            faceWidth:     Float(faceWidthRatio)
        )
        frameRecords.append(record)

        // EAR 計算
        let ear = computeEAR(leftEye: leftEyePoints, rightEye: rightEyePoints)
        earHistory.append(ear)
        checkBlink(ear: ear)

        // 即時狀態
        var checks: [String] = []
        checks.append("臉部大小：\(pct(faceWidthRatio))")
        checks.append("靠近進度：\(Int(progress * 100))%")
        checks.append("已收集：\(frameRecords.count) 幀")
        checks.append("EAR：\(String(format: "%.3f", ear))  \(blinkDetected ? "👁️ 已眨眼" : "")")
        if frameRecords.count >= 5 {
            let ratio = computeCurrentDistortionRatio()
            checks.append("畸變比：\(String(format: "%.4f", ratio))")
        }
        liveDetails = checks
        statusText = progress >= 1.0 ? "分析中..." : "請繼續靠近"

        // 達到目標距離 → 結束
        if progress >= 1.0 && frameRecords.count >= 15 {
            finalize()
        }
    }

    // MARK: - EAR（Eye Aspect Ratio）

    /// 計算雙眼平均 EAR
    /// Vision 的 eye landmark 8 個點：沿眼睛輪廓排列
    /// 我們取最上/最下/最左/最右來計算
    private func computeEAR(leftEye: [CGPoint], rightEye: [CGPoint]) -> Float {
        let leftEAR  = singleEyeEAR(leftEye)
        let rightEAR = singleEyeEAR(rightEye)
        return (leftEAR + rightEAR) / 2.0
    }

    private func singleEyeEAR(_ points: [CGPoint]) -> Float {
        guard points.count >= 6 else { return 0.3 }

        // Vision eye landmark: 大約 8 個點繞眼睛輪廓
        // 取垂直高度 / 水平寬度
        let xs = points.map { Float($0.x) }
        let ys = points.map { Float($0.y) }

        let width  = (xs.max() ?? 0) - (xs.min() ?? 0)
        let height = (ys.max() ?? 0) - (ys.min() ?? 0)

        guard width > 0.001 else { return 0.3 }
        return height / width
    }

    private func checkBlink(ear: Float) {
        if ear < earBlinkThreshold {
            blinkCounter += 1
        } else {
            if blinkCounter >= earBlinkConsecFrames {
                blinkDetected = true
            }
            blinkCounter = 0
        }
    }

    // MARK: - 透視畸變分析

    /// 計算目前的平均畸變比
    /// > 1.0 表示鼻尖移動比臉輪廓快（3D 物體特徵）
    /// ≈ 1.0 表示等比例縮放（平面物體特徵）
    private func computeCurrentDistortionRatio() -> Float {
        computeDistortionRatio(records: frameRecords)
    }

    /// 核心演算法：計算特徵點位移比
    ///
    /// 原理：靠近相機時，近的特徵（鼻尖）放大速度 > 遠的特徵（臉輪廓邊緣）
    /// 我們用「鼻尖到臉中心的距離變化」vs「輪廓點到臉中心的距離變化」來量化
    private func computeDistortionRatio(records: [FrameRecord]) -> Float {
        guard records.count >= 5 else { return 1.0 }

        var noseDisplacements: [Float] = []
        var contourDisplacements: [Float] = []

        for i in 1..<records.count {
            let prev = records[i - 1]
            let curr = records[i]

            // 臉中心 = 左右輪廓的中點
            let prevCenterX = (prev.leftContourX + prev.rightContourX) / 2
            let prevCenterY = (prev.leftContourY + prev.rightContourY) / 2
            let currCenterX = (curr.leftContourX + curr.rightContourX) / 2
            let currCenterY = (curr.leftContourY + curr.rightContourY) / 2

            // 鼻尖到中心的距離
            let prevNoseDist = hypot(prev.noseTipX - prevCenterX, prev.noseTipY - prevCenterY)
            let currNoseDist = hypot(curr.noseTipX - currCenterX, curr.noseTipY - currCenterY)

            // 臉寬（左右輪廓距離）
            let prevFaceW = hypot(prev.leftContourX - prev.rightContourX,
                                  prev.leftContourY - prev.rightContourY)
            let currFaceW = hypot(curr.leftContourX - curr.rightContourX,
                                  curr.leftContourY - curr.rightContourY)

            // 只計算臉有變大的幀（靠近動作）
            guard currFaceW > prevFaceW + 0.0005 else { continue }

            // normalize: 除以臉寬，消除整體縮放影響
            let noseChange = abs(currNoseDist / currFaceW - prevNoseDist / prevFaceW)
            let faceChange = abs(currFaceW - prevFaceW) / prevFaceW

            if faceChange > 0.001 {
                noseDisplacements.append(noseChange)
                contourDisplacements.append(faceChange)
            }
        }

        guard !noseDisplacements.isEmpty else { return 1.0 }

        // 方法二：直接看臉寬變化 vs 鼻尖-中心距離變化的比例
        // 真人靠近時鼻尖相對突出量會增加（nose-center/face-width 上升）
        // 照片靠近時等比例縮放，nose-center/face-width 不變

        let firstRecord = records.first!
        let lastRecord  = records.last!

        let firstFaceW = hypot(firstRecord.leftContourX - firstRecord.rightContourX,
                               firstRecord.leftContourY - firstRecord.rightContourY)
        let lastFaceW  = hypot(lastRecord.leftContourX - lastRecord.rightContourX,
                               lastRecord.leftContourY - lastRecord.rightContourY)

        guard firstFaceW > 0.01 && lastFaceW > 0.01 else { return 1.0 }

        let firstNoseDist = hypot(
            firstRecord.noseTipX - (firstRecord.leftContourX + firstRecord.rightContourX) / 2,
            firstRecord.noseTipY - (firstRecord.leftContourY + firstRecord.rightContourY) / 2
        )
        let lastNoseDist = hypot(
            lastRecord.noseTipX - (lastRecord.leftContourX + lastRecord.rightContourX) / 2,
            lastRecord.noseTipY - (lastRecord.leftContourY + lastRecord.rightContourY) / 2
        )

        // 正規化鼻尖突出比例
        let firstRatio = firstNoseDist / firstFaceW
        let lastRatio  = lastNoseDist  / lastFaceW

        // 真人：lastRatio > firstRatio（鼻尖越靠近相機，相對臉寬的突出越明顯）
        // 照片：lastRatio ≈ firstRatio（等比例縮放）
        guard firstRatio > 0.001 else { return 1.0 }
        return lastRatio / firstRatio
    }

    // MARK: - 最終判定

    private func finalize() {
        phase = .done

        guard frameRecords.count >= 5 else {
            result = .spoof
            finalDetails = ["資料不足（\(frameRecords.count) 幀）"]
            return
        }

        var summary: [String] = []

        // 1. 透視畸變分析
        let ratio = computeDistortionRatio(records: frameRecords)
        distortionScore = ratio

        // 畸變比 > 1.02 表示有 3D 深度特徵
        let distortionPass = ratio > 1.01
        summary.append("透視畸變比：\(String(format: "%.4f", ratio))  \(distortionPass ? "✓ 3D" : "✗ 平面")")

        // 2. 臉寬變化量
        let firstW = frameRecords.first?.faceWidth ?? 0
        let lastW  = frameRecords.last?.faceWidth ?? 0
        let zoomRatio = lastW > 0.01 ? lastW / firstW : 1.0
        summary.append("靠近倍率：\(String(format: "%.2f", zoomRatio))×")

        // 3. EAR 眨眼
        let maxEAR = earHistory.max() ?? 0
        let minEAR = earHistory.min() ?? 0
        let earDrop = maxEAR - minEAR
        summary.append("眨眼：\(blinkDetected ? "✓ 偵測到" : "✗ 無")")
        summary.append("EAR 最大降幅：\(String(format: "%.3f", earDrop))")

        // 計算 blink_weight
        if blinkDetected {
            blinkWeight = min(0.7 + (earDrop - 0.1) / 0.15 * 0.3, 1.0)
        } else {
            blinkWeight = min(earDrop / 0.15, 0.5)
        }
        summary.append("眨眼權重：\(String(format: "%.2f", blinkWeight))")

        // 4. 幀數穩定性
        summary.append("有效幀數：\(frameRecords.count)")

        summary.append("─────────────────")

        // 最終判定
        // 透視畸變是主要依據；眨眼是輔助
        // 但因為 PoC 階段精度未確認，採寬鬆標準
        let isLive = distortionPass || (blinkDetected && ratio > 0.98)

        result = isLive ? .live : .spoof
        summary.append("判定：\(result.rawValue)")
        summary.append("（PoC 階段，閾值待校準）")
        finalDetails = summary
    }

    // MARK: - 資料標記 Log

    func logCount() -> Int {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let logFile = docs.appendingPathComponent("perspective_log.csv")
        guard let content = try? String(contentsOf: logFile, encoding: .utf8) else { return 0 }
        return content.components(separatedBy: "\n").filter { !$0.isEmpty && !$0.hasPrefix("timestamp") }.count
    }

    func saveLog(groundTruth: String) {
        let header = "timestamp,groundTruth,prediction,distortionScore,blinkWeight,blinkDetected,earDrop,zoomRatio,frameCount\n"

        let ts = ISO8601DateFormatter().string(from: Date())
        let prediction = result == .live ? "live" : "spoof"

        let firstW = frameRecords.first?.faceWidth ?? 0
        let lastW  = frameRecords.last?.faceWidth ?? 0
        let zoomRatio = firstW > 0.01 ? lastW / firstW : 1.0
        let maxEAR = earHistory.max() ?? 0
        let minEAR = earHistory.min() ?? 0
        let earDrop = maxEAR - minEAR

        let row = [
            ts, groundTruth, prediction,
            String(format: "%.4f", distortionScore),
            String(format: "%.4f", blinkWeight),
            blinkDetected ? "1" : "0",
            String(format: "%.4f", earDrop),
            String(format: "%.4f", zoomRatio),
            "\(frameRecords.count)"
        ].joined(separator: ",") + "\n"

        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let logFile = docs.appendingPathComponent("perspective_log.csv")

        if !FileManager.default.fileExists(atPath: logFile.path) {
            try? header.write(to: logFile, atomically: true, encoding: .utf8)
        }

        if let handle = try? FileHandle(forWritingTo: logFile) {
            handle.seekToEndOfFile()
            handle.write(row.data(using: .utf8)!)
            handle.closeFile()
        }
    }

    // MARK: - 工具

    private func pct(_ v: CGFloat) -> String {
        "\(Int(v * 100))%"
    }
}
