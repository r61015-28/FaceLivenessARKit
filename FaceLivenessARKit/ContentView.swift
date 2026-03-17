import SwiftUI
import ARKit

struct ContentView: View {
    @StateObject private var faceManager = ARFaceManager()
    @StateObject private var checker = LivenessChecker()
    @State private var capturedImage: UIImage? = nil
    @State private var labelSaved = false

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

            // 偵測 phase 從 counting → done 的瞬間截圖
            if case .done = checker.phase, wasCounting {
                capturedImage = faceManager.capturePhoto()
                faceManager.stop()
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

    // MARK: - 待機畫面

    private var idleOverlay: some View {
        VStack {
            // 頂部標題
            Text("3D Liveness PoC")
                .font(.title3.bold())
                .foregroundColor(.white)
                .padding(.top, 80)

            Spacer()

            // 說明文字
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

            // 開始按鈕
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
            // 角落圓點（每次一個，共出現 3 次）
            if let dot = checker.currentDot {
                dotView(corner: dot)
            }

            VStack {
                // 頂部狀態
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

                // 倒數計時（大字）
                Text(String(format: "%.1f", max(remaining, 0)))
                    .font(.system(size: 72, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .shadow(color: .black, radius: 10)

                Spacer()

                // 即時 check 面板
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
            let marginTop: CGFloat = 130   // 避開狀態列
            let marginBottom: CGFloat = 180 // 避開 check 面板

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

            // 結果卡片
            VStack(spacing: 12) {
                // 大結果文字
                Text(checker.result.rawValue)
                    .font(.title.bold())
                    .foregroundColor(checker.result == .live ? .green : .red)

                Divider().background(Color.white.opacity(0.3))

                // 各項 check 詳情
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(checker.finalDetails, id: \.self) { detail in
                        Text(detail)
                            .font(.system(size: 14))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(20)
            .background(Color.black.opacity(0.85))
            .cornerRadius(20)
            .padding(.horizontal, 12)

            // 標記按鈕：人工標記真人/假人，存 log
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

            // 再次偵測按鈕
            Button(action: retryDetection) {
                Text("再次偵測")
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(width: 200, height: 50)
                    .background(Color.blue)
                    .cornerRadius(25)
            }
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
        checker.saveLog(groundTruth: groundTruth)
        labelSaved = true
    }

    private func retryDetection() {
        capturedImage = nil
        labelSaved = false
        checker.reset()
        faceManager.start()
        // 等 ARKit 重新啟動後開始倒數
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            checker.startCountdown()
        }
    }

    private var resultColor: Color {
        checker.result == .live ? .green : .red
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
