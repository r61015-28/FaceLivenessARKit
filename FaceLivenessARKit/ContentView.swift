import SwiftUI
import ARKit

// MARK: - 偵測模式

enum DetectionMode: String, CaseIterable {
    case arkit       = "ARKit 3D"
    case perspective = "一般相機"
}

// MARK: - 主畫面（模式選擇 → 偵測）

struct ContentView: View {
    @State private var detectionMode: DetectionMode = .perspective
    @State private var started = false

    var body: some View {
        if !started {
            modeSelectionScreen
                .onAppear { DataSyncManager.shared.syncAll() }
        } else {
            Group {
                switch detectionMode {
                case .arkit:
                    ARKitDetectionView(onBack: { started = false })
                case .perspective:
                    PerspectiveDetectionView(onBack: { started = false })
                }
            }
        }
    }

    private var modeSelectionScreen: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                Text("Liveness Detection")
                    .font(.title.bold())
                    .foregroundColor(.white)
                    .padding(.top, 100)

                Spacer()

                // 模式選擇
                VStack(spacing: 20) {
                    Text("選擇偵測模式")
                        .font(.headline)
                        .foregroundColor(.white.opacity(0.8))

                    Picker("", selection: $detectionMode) {
                        ForEach(DetectionMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 40)

                    // 模式說明
                    Group {
                        if detectionMode == .arkit {
                            VStack(spacing: 6) {
                                Text("ARKit 3D 深度偵測")
                                    .font(.subheadline.bold())
                                Text("需要 TrueDepth 相機（Face ID 機型）")
                                Text("使用結構光 3D + 眼球追蹤 + BlendShape")
                            }
                        } else {
                            VStack(spacing: 6) {
                                Text("透視畸變偵測")
                                    .font(.subheadline.bold())
                                Text("所有 iOS 裝置皆可使用")
                                Text("引導靠近 → 分析透視畸變 + EAR 眨眼")
                            }
                        }
                    }
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                }
                .padding(24)
                .background(Color.white.opacity(0.08))
                .cornerRadius(20)
                .padding(.horizontal, 24)

                Spacer()

                Button(action: { started = true }) {
                    Text("開始偵測")
                        .font(.title2.bold())
                        .foregroundColor(.white)
                        .frame(width: 220, height: 56)
                        .background(Color.blue)
                        .cornerRadius(28)
                }
                .padding(.bottom, 80)
            }
        }
    }
}

// MARK: - ARKit 偵測畫面（原有邏輯）

struct ARKitDetectionView: View {
    var onBack: () -> Void

    @StateObject private var faceManager = ARFaceManager()
    @StateObject private var checker = LivenessChecker()
    @State private var capturedImage: UIImage? = nil
    @State private var labelSaved = false
    @State private var yoloResult: YoloResponse? = nil
    @State private var yoloError: String? = nil
    @State private var isCheckingYolo = false

    private let timer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            // 背景：結果頁顯示截圖，其他時候顯示相機
            if checker.phase == .done, let image = capturedImage {
                Color.clear
                    .background(
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    )
                    .clipped()
                    .ignoresSafeArea()
                    .overlay(Color.black.opacity(0.3))
            } else {
                ARViewContainer(session: faceManager.session)
                    .ignoresSafeArea()
            }

            // 前景 UI
            switch checker.phase {
            case .idle:
                idleOverlay
            case .counting(let remaining):
                countingOverlay(remaining: remaining)
            case .done:
                doneOverlay
            }
        }
        .onAppear {
            faceManager.start()
        }
        .onReceive(timer) { _ in
            let wasCounting: Bool
            if case .counting = checker.phase { wasCounting = true } else { wasCounting = false }

            checker.tick(dt: 0.1)

            // 偵測 phase 從 counting → done 的瞬間截圖 + 送 YOLO
            if case .done = checker.phase, wasCounting {
                let photo = faceManager.capturePhoto()
                capturedImage = photo
                faceManager.stop()
                if let photo = photo {
                    sendToYolo(image: photo)
                }
            }
        }
        .onReceive(faceManager.$trackingFrameCount) { _ in
            guard case .counting = checker.phase else { return }
            checker.evaluate(
                isFaceDetected: faceManager.isFaceDetected,
                faceDistance: faceManager.faceDistance,
                headEulerAngles: faceManager.headEulerAngles,
                blendShapes: faceManager.blendShapes,
                vertexCount: faceManager.vertexCount,
                trackingFrameCount: faceManager.trackingFrameCount
            )
        }
    }

    // MARK: - 待機畫面（等 ARKit 啟動後自動開始）

    private var idleOverlay: some View {
        VStack {
            HStack {
                Button(action: {
                    faceManager.stop()
                    onBack()
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text("返回")
                    }
                    .font(.subheadline)
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.5))
                    .cornerRadius(20)
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 60)

            Text("ARKit 3D 模式")
                .font(.title3.bold())
                .foregroundColor(.white)
                .padding(.top, 8)

            Spacer()

            VStack(spacing: 8) {
                Text("請將臉對準鏡頭")
                    .font(.headline)
                    .foregroundColor(.white)
                Text("偵測時請跟隨黃色圓點移動視線")
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.7))
            }
            .padding(20)
            .background(Color.black.opacity(0.6))
            .cornerRadius(16)
            .padding(.horizontal, 32)

            Spacer()

            Button(action: startDetection) {
                Text("開始偵測")
                    .font(.title2.bold())
                    .foregroundColor(.white)
                    .frame(width: 200, height: 56)
                    .background(Color.blue)
                    .cornerRadius(28)
            }
            .padding(.bottom, 80)
        }
    }

    // MARK: - 偵測中畫面

    private func countingOverlay(remaining: Double) -> some View {
        ZStack {
            if let dot = checker.currentDot {
                dotView(corner: dot)
            }

            VStack {
                HStack {
                    Circle()
                        .fill(faceManager.isFaceDetected ? Color.green : Color.red)
                        .frame(width: 12, height: 12)
                    Text(faceManager.isFaceDetected ? "人臉追蹤中" : "未偵測到人臉")
                        .font(.subheadline)
                        .foregroundColor(.white)
                    Spacer()
                    Text("偵測中")
                        .font(.subheadline.bold())
                        .foregroundColor(.yellow)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .background(Color.black.opacity(0.5))
                .padding(.top, 60)

                Spacer()

                Text(String(format: "%.1f", max(remaining, 0)))
                    .font(.system(size: 72, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .shadow(color: .black, radius: 10)

                Spacer()

                VStack(alignment: .leading, spacing: 4) {
                    ForEach(checker.liveDetails, id: \.self) { detail in
                        Text(detail)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.white)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color.black.opacity(0.6))
                .cornerRadius(12)
                .padding(.horizontal, 16)
                .padding(.bottom, 40)
            }
        }
    }

    // MARK: - 圓點

    private func dotView(corner: LivenessChecker.Corner) -> some View {
        GeometryReader { geo in
            let size: CGFloat = 28
            let marginX: CGFloat = 44
            let marginTop: CGFloat = 130
            let marginBottom: CGFloat = 180

            let pos: CGPoint = {
                switch corner {
                case .topLeft:
                    return CGPoint(x: marginX, y: marginTop)
                case .topRight:
                    return CGPoint(x: geo.size.width - marginX, y: marginTop)
                case .bottomLeft:
                    return CGPoint(x: marginX, y: geo.size.height - marginBottom)
                case .bottomRight:
                    return CGPoint(x: geo.size.width - marginX, y: geo.size.height - marginBottom)
                }
            }()

            let hermesOrange = Color(red: 0.91, green: 0.45, blue: 0.16)
            Circle()
                .fill(hermesOrange)
                .frame(width: size, height: size)
                .shadow(color: hermesOrange.opacity(0.7), radius: 10)
                .overlay(Circle().stroke(Color.white, lineWidth: 2))
                .position(pos)
                .animation(.easeInOut(duration: 0.25), value: corner)
        }
    }

    // MARK: - 結果畫面

    private var doneOverlay: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("ARKit（第一層）")
                        .font(.caption.bold())
                        .foregroundColor(.white.opacity(0.6))
                    Text(checker.result.rawValue)
                        .font(.title.bold())
                        .foregroundColor(checker.result == .live ? .green : .red)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Divider().background(Color.white.opacity(0.3))

                VStack(alignment: .leading, spacing: 6) {
                    ForEach(checker.finalDetails, id: \.self) { detail in
                        Text(detail)
                            .font(.system(size: 14))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                Divider().background(Color.white.opacity(0.3))

                if isCheckingYolo {
                    HStack(spacing: 8) {
                        ProgressView().tint(.white)
                        Text("YOLO 驗證中...")
                            .font(.subheadline)
                            .foregroundColor(.white.opacity(0.7))
                    }
                } else if let yolo = yoloResult {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("YOLO（第二層）")
                            .font(.caption.bold())
                            .foregroundColor(.white.opacity(0.6))
                        Text(yolo.isLive == true ? "✅ Live" : "❌ Spoof")
                            .font(.headline.bold())
                            .foregroundColor(yolo.isLive == true ? .green : .red)
                        Text("Live \(String(format: "%.1f", yolo.liveProbability * 100))%  /  Spoof \(String(format: "%.1f", yolo.spoofProbability * 100))%")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.white.opacity(0.8))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else if let err = yoloError {
                    Text("YOLO：\(err)")
                        .font(.caption)
                        .foregroundColor(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(20)
            .background(Color.black.opacity(0.85))
            .cornerRadius(20)
            .padding(.horizontal, 12)

            if !labelSaved {
                Text("目前已收集 \(checker.logCount()) 筆")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.6))
                    .padding(.top, 8)
                HStack(spacing: 16) {
                    Button(action: { labelAndSave("real") }) {
                        Text("✅ 標記真人")
                            .font(.subheadline.bold())
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(Color.green.opacity(0.8))
                            .cornerRadius(12)
                    }
                    Button(action: { labelAndSave("spoof") }) {
                        Text("❌ 標記假人")
                            .font(.subheadline.bold())
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(Color.red.opacity(0.8))
                            .cornerRadius(12)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 4)
            } else {
                Text("已儲存 第 \(checker.logCount()) 筆 ✓")
                    .font(.subheadline)
                    .foregroundColor(.green)
                    .padding(.top, 12)
            }

            HStack(spacing: 16) {
                Button(action: {
                    faceManager.stop()
                    onBack()
                }) {
                    Text("返回選擇")
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(Color.gray.opacity(0.6))
                        .cornerRadius(25)
                }
                Button(action: retryDetection) {
                    Text("再次偵測")
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(Color.blue)
                        .cornerRadius(25)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 動作

    private func startDetection() {
        checker.startCountdown()
    }

    private func labelAndSave(_ groundTruth: String) {
        guard !labelSaved else { return }  // 防重複標記
        let yoloPred: String? = yoloResult.map { $0.isLive == true ? "live" : "spoof" }
        let yoloProb: Float? = yoloResult?.liveProbability
        checker.saveLog(groundTruth: groundTruth, yoloPrediction: yoloPred, yoloLiveProb: yoloProb)
        labelSaved = true
        DataSyncManager.shared.sync(mode: "arkit")
    }

    private func retryDetection() {
        capturedImage = nil
        labelSaved = false
        yoloResult = nil
        yoloError = nil
        isCheckingYolo = false
        checker.reset()
        faceManager.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            checker.startCountdown()
        }
    }

    private func sendToYolo(image: UIImage) {
        isCheckingYolo = true
        yoloResult = nil
        yoloError = nil
        Task {
            do {
                let result = try await LivenessAPIClient.shared.detect(image: image)
                await MainActor.run {
                    yoloResult = result
                    isCheckingYolo = false
                }
            } catch YoloError.noFace {
                await MainActor.run { yoloError = "未偵測到人臉"; isCheckingYolo = false }
            } catch YoloError.serverError(let msg) {
                await MainActor.run { yoloError = msg; isCheckingYolo = false }
            } catch {
                await MainActor.run { yoloError = "連線失敗，確認 WiFi 與 server"; isCheckingYolo = false }
            }
        }
    }
}

// MARK: - ARKit 相機畫面

struct ARViewContainer: UIViewRepresentable {
    let session: ARSession

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView()
        view.session = session
        view.automaticallyUpdatesLighting = true
        return view
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {}
}
