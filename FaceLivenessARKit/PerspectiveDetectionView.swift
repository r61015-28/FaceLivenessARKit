import SwiftUI
import AVFoundation

// MARK: - 一般相機模式偵測畫面

struct PerspectiveDetectionView: View {
    var onBack: () -> Void = {}

    @StateObject private var cameraManager = CameraManager()
    @StateObject private var checker = PerspectiveLivenessChecker()
    @ObservedObject private var syncManager = DataSyncManager.shared
    @State private var capturedImage: UIImage? = nil
    @State private var yoloResult: YoloResponse? = nil
    @State private var yoloError: String? = nil
    @State private var isCheckingYolo = false
    @State private var labelSaved = false

    private let timer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            // 背景：結果頁顯示截圖，其他顯示相機
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
                CameraPreviewView(session: cameraManager.session)
                    .ignoresSafeArea()
            }

            // 前景 UI
            switch checker.phase {
            case .idle:
                idleOverlay
            case .aligning:
                aligningOverlay
            case .zoomIn(let progress):
                zoomInOverlay(progress: progress)
            case .done:
                doneOverlay
            }

            // 同步 overlay
            if syncManager.isSyncing {
                SyncOverlayView(syncManager: syncManager)
            }
        }
        .allowsHitTesting(!syncManager.isSyncing)
        .onAppear {
            cameraManager.start()
        }
        .onDisappear {
            cameraManager.stop()
        }
        .onReceive(timer) { _ in
            let wasCounting: Bool
            switch checker.phase {
            case .aligning, .zoomIn: wasCounting = true
            default: wasCounting = false
            }

            checker.tick(dt: 0.1)

            // 偵測完成瞬間截圖 + 送 YOLO
            if case .done = checker.phase, wasCounting {
                let photo = cameraManager.capturePhoto()
                capturedImage = photo
                cameraManager.stop()
                if let photo = photo {
                    sendToYolo(image: photo)
                }
            }
        }
        .onReceive(cameraManager.$frameCount) { _ in
            let wasActive: Bool
            switch checker.phase {
            case .aligning, .zoomIn: wasActive = true
            default: wasActive = false
            }

            checker.evaluate(
                isFaceDetected: cameraManager.isFaceDetected,
                faceWidthRatio: cameraManager.faceWidthRatio,
                noseTip: cameraManager.noseTip,
                leftContour: cameraManager.leftContourOuter,
                rightContour: cameraManager.rightContourOuter,
                leftEyePoints: cameraManager.leftEyePoints,
                rightEyePoints: cameraManager.rightEyePoints
            )

            // evaluate() 內部可能直接 finalize() → 在這裡補抓 done 轉換
            if case .done = checker.phase, wasActive {
                let photo = cameraManager.capturePhoto()
                capturedImage = photo
                cameraManager.stop()
                if let photo = photo {
                    sendToYolo(image: photo)
                }
            }
        }
    }

    // MARK: - 待機畫面

    private var idleOverlay: some View {
        VStack {
            HStack {
                Button(action: {
                    cameraManager.stop()
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

            Text("一般相機模式")
                .font(.title3.bold())
                .foregroundColor(.white)
                .padding(.top, 8)

            Spacer()

            VStack(spacing: 8) {
                Text("透視畸變活體偵測")
                    .font(.headline)
                    .foregroundColor(.white)
                Text("請將臉對準框框，然後緩慢靠近手機")
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.7))
            }
            .padding(20)
            .background(Color.black.opacity(0.6))
            .cornerRadius(16)
            .padding(.horizontal, 32)

            Spacer()

            Button(action: {
                checker.startDetection()
            }) {
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

    // MARK: - 對齊階段

    private var aligningOverlay: some View {
        ZStack {
            // 引導橢圓框
            guideOval(color: .gray)

            VStack {
                statusBar

                Spacer()

                Text("請將臉放入框中")
                    .font(.title2.bold())
                    .foregroundColor(.white)
                    .shadow(color: .black, radius: 8)

                Spacer()

                detailPanel
            }
        }
    }

    // MARK: - 靠近階段

    private func zoomInOverlay(progress: Double) -> some View {
        ZStack {
            // 引導橢圓框（顏色隨進度變化）
            guideOval(color: progress > 0.8 ? .green : .orange)

            VStack {
                statusBar

                Spacer()

                // 進度環
                ZStack {
                    Circle()
                        .stroke(Color.white.opacity(0.3), lineWidth: 6)
                        .frame(width: 80, height: 80)
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(Color.green, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .frame(width: 80, height: 80)
                        .rotationEffect(.degrees(-90))
                    Text("\(Int(progress * 100))%")
                        .font(.title3.bold())
                        .foregroundColor(.white)
                }

                Text(checker.statusText)
                    .font(.headline)
                    .foregroundColor(.white)
                    .shadow(color: .black, radius: 8)
                    .padding(.top, 8)

                Spacer()

                detailPanel
            }
        }
    }

    // MARK: - 結果畫面

    private var doneOverlay: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 12) {
                // 透視畸變結果
                VStack(alignment: .leading, spacing: 4) {
                    Text("透視畸變（第一層）")
                        .font(.caption.bold())
                        .foregroundColor(.white.opacity(0.6))
                    Text(checker.result.rawValue)
                        .font(.title.bold())
                        .foregroundColor(checker.result == .live ? .green : .red)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Divider().background(Color.white.opacity(0.3))

                // 各項指標
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(checker.finalDetails, id: \.self) { detail in
                        Text(detail)
                            .font(.system(size: 14))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                Divider().background(Color.white.opacity(0.3))

                // YOLO 結果
                yoloResultView
            }
            .frame(maxWidth: .infinity)
            .padding(20)
            .background(Color.black.opacity(0.85))
            .cornerRadius(20)
            .padding(.horizontal, 12)

            // 標記按鈕
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

            // 再次偵測 / 返回
            HStack(spacing: 16) {
                Button(action: {
                    cameraManager.stop()
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

    // MARK: - 共用元件

    private var statusBar: some View {
        HStack {
            Circle()
                .fill(cameraManager.isFaceDetected ? Color.green : Color.red)
                .frame(width: 12, height: 12)
            Text(cameraManager.isFaceDetected ? "人臉追蹤中" : "未偵測到人臉")
                .font(.subheadline)
                .foregroundColor(.white)
            Spacer()
            Text("一般相機模式")
                .font(.subheadline.bold())
                .foregroundColor(.cyan)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.5))
        .padding(.top, 60)
    }

    private var detailPanel: some View {
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

    /// 引導橢圓框
    private func guideOval(color: Color) -> some View {
        GeometryReader { geo in
            let ovalWidth = geo.size.width * 0.65
            let ovalHeight = ovalWidth * 1.35

            Ellipse()
                .stroke(color, lineWidth: 3)
                .frame(width: ovalWidth, height: ovalHeight)
                .position(x: geo.size.width / 2, y: geo.size.height * 0.4)
                .shadow(color: color.opacity(0.5), radius: 8)
        }
    }

    @ViewBuilder
    private var yoloResultView: some View {
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

    // MARK: - 動作

    private func labelAndSave(_ groundTruth: String) {
        guard !labelSaved else { return }  // 防重複標記
        let yoloPred: String? = yoloResult.map { $0.isLive == true ? "live" : "spoof" }
        let yoloProb: Float? = yoloResult?.liveProbability
        checker.saveLog(groundTruth: groundTruth, yoloPrediction: yoloPred, yoloLiveProb: yoloProb)
        labelSaved = true
        DataSyncManager.shared.sync(mode: "perspective")
    }

    private func retryDetection() {
        capturedImage = nil
        labelSaved = false
        yoloResult = nil
        yoloError = nil
        isCheckingYolo = false
        checker.reset()
        cameraManager.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            checker.startDetection()
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
                await MainActor.run { yoloError = "連線失敗"; isCheckingYolo = false }
            }
        }
    }
}

// MARK: - 同步進度 Overlay

struct SyncOverlayView: View {
    @ObservedObject var syncManager: DataSyncManager

    var body: some View {
        ZStack {
            Color.black.opacity(0.7)
                .ignoresSafeArea()

            VStack(spacing: 20) {
                // 進度環
                ZStack {
                    Circle()
                        .stroke(Color.white.opacity(0.2), lineWidth: 8)
                        .frame(width: 100, height: 100)
                    Circle()
                        .trim(from: 0, to: syncManager.progress)
                        .stroke(Color.green, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                        .frame(width: 100, height: 100)
                        .rotationEffect(.degrees(-90))
                        .animation(.easeInOut(duration: 0.3), value: syncManager.progress)

                    Text("\(Int(syncManager.progress * 100))%")
                        .font(.title2.bold())
                        .foregroundColor(.white)
                }

                // 狀態文字
                if let result = syncManager.syncResult {
                    switch result {
                    case .success(let accepted):
                        Text("上傳完成 \(accepted) 筆")
                            .font(.headline)
                            .foregroundColor(.green)
                    case .failure(let msg):
                        Text("上傳失敗：\(msg)")
                            .font(.headline)
                            .foregroundColor(.orange)
                    }
                } else {
                    Text("資料上傳中 \(syncManager.sentRows)/\(syncManager.totalRows)")
                        .font(.headline)
                        .foregroundColor(.white)
                }
            }
            .padding(40)
            .background(Color.black.opacity(0.8))
            .cornerRadius(24)
        }
    }
}

// MARK: - 相機預覽（UIViewRepresentable）

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(previewLayer)
        context.coordinator.previewLayer = previewLayer
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        DispatchQueue.main.async {
            context.coordinator.previewLayer?.frame = uiView.bounds
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator {
        var previewLayer: AVCaptureVideoPreviewLayer?
    }
}
