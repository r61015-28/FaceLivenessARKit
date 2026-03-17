import SwiftUI
import ARKit

struct ContentView: View {
    @StateObject private var faceManager = ARFaceManager()
    @StateObject private var checker = LivenessChecker()
    @State private var isRunning = false

    var body: some View {
        ZStack {
            // ARKit 相機預覽
            ARViewContainer(session: faceManager.session)
                .ignoresSafeArea()

            VStack {
                // 頂部狀態列
                statusBar
                    .padding(.top, 60)

                Spacer()

                // 即時資訊面板
                infoPanel
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)

                // 結果顯示
                resultView
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)

                // 按鈕
                controlButtons
                    .padding(.bottom, 40)
            }
        }
        .onDisappear {
            faceManager.stop()
        }
        .onReceive(faceManager.$trackingFrameCount) { _ in
            guard isRunning else { return }
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

    // MARK: - 元件

    private var statusBar: some View {
        HStack {
            Circle()
                .fill(faceManager.isFaceDetected ? Color.green : Color.red)
                .frame(width: 12, height: 12)
            Text(faceManager.isFaceDetected ? "人臉追蹤中" : "未偵測到人臉")
                .font(.subheadline)
                .foregroundColor(.white)
            Spacer()
            Text("3D Liveness PoC")
                .font(.subheadline.bold())
                .foregroundColor(.white)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.5))
    }

    private var infoPanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(checker.details, id: \.self) { detail in
                Text(detail)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.white)
            }
            if faceManager.isFaceDetected {
                Text("頂點數：\(faceManager.vertexCount)  距離：\(Int(faceManager.faceDistance * 100)) cm")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.white.opacity(0.7))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.black.opacity(0.6))
        .cornerRadius(12)
    }

    private var resultView: some View {
        VStack(spacing: 8) {
            // 進度條
            ProgressView(value: checker.confidence)
                .progressViewStyle(LinearProgressViewStyle(tint: resultColor))
                .scaleEffect(y: 2)

            // 結果文字
            Text(checker.result.rawValue)
                .font(.title2.bold())
                .foregroundColor(resultColor)
        }
        .padding(16)
        .background(Color.black.opacity(0.7))
        .cornerRadius(16)
    }

    private var controlButtons: some View {
        HStack(spacing: 20) {
            Button(action: {
                if isRunning {
                    faceManager.stop()
                    checker.reset()
                    isRunning = false
                } else {
                    faceManager.start()
                    checker.reset()
                    isRunning = true
                }
            }) {
                Text(isRunning ? "停止" : "開始偵測")
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(width: 160, height: 50)
                    .background(isRunning ? Color.red : Color.blue)
                    .cornerRadius(25)
            }

            if isRunning {
                Button(action: {
                    checker.reset()
                }) {
                    Text("重置")
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(width: 100, height: 50)
                        .background(Color.gray)
                        .cornerRadius(25)
                }
            }
        }
    }

    private var resultColor: Color {
        switch checker.result {
        case .live:     return .green
        case .spoof:    return .red
        case .checking: return .yellow
        case .unknown:  return .gray
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
