import ARKit
import Combine

/// ARKit Face Tracking 管理器
/// 負責 TrueDepth 3D 人臉追蹤，提供深度、表情、頭部姿態資料
final class ARFaceManager: NSObject, ObservableObject, ARSessionDelegate {

    let session = ARSession()

    // MARK: - Published 狀態

    /// 是否偵測到人臉
    @Published var isFaceDetected = false

    /// 人臉深度資訊（距離相機公尺數）
    @Published var faceDistance: Float = 0

    /// 頭部旋轉（歐拉角 x=pitch, y=yaw, z=roll，弧度）
    @Published var headEulerAngles: SIMD3<Float> = .zero

    /// 52 個 BlendShape 權重（表情係數）
    @Published var blendShapes: [ARFaceAnchor.BlendShapeLocation: NSNumber] = [:]

    /// 3D 頂點數量（用於驗證是否為真 3D mesh）
    @Published var vertexCount: Int = 0

    /// 連續追蹤幀數
    @Published var trackingFrameCount: Int = 0

    // MARK: - 內部

    private var isRunning = false

    override init() {
        super.init()
        session.delegate = self
    }

    /// 啟動 Face Tracking
    func start() {
        guard ARFaceTrackingConfiguration.isSupported else {
            print("[ARFaceManager] 此裝置不支援 Face Tracking（需要 TrueDepth 相機）")
            return
        }
        let config = ARFaceTrackingConfiguration()
        config.maximumNumberOfTrackedFaces = 1
        config.isWorldTrackingEnabled = false
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
        isRunning = true
        print("[ARFaceManager] Face Tracking 啟動")
    }

    /// 停止追蹤
    func stop() {
        session.pause()
        isRunning = false
        isFaceDetected = false
        trackingFrameCount = 0
        print("[ARFaceManager] Face Tracking 停止")
    }

    // MARK: - ARSessionDelegate

    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        guard let faceAnchor = anchors.compactMap({ $0 as? ARFaceAnchor }).first else {
            DispatchQueue.main.async {
                self.isFaceDetected = false
                self.trackingFrameCount = 0
            }
            return
        }

        let transform = faceAnchor.transform
        let position = SIMD3<Float>(transform.columns.3.x,
                                     transform.columns.3.y,
                                     transform.columns.3.z)
        let distance = simd_length(position)

        // 歐拉角（從 transform 矩陣萃取）
        let euler = Self.eulerAngles(from: transform)

        let shapes = faceAnchor.blendShapes
        let vCount = faceAnchor.geometry.vertices.count

        DispatchQueue.main.async {
            self.isFaceDetected = faceAnchor.isTracked
            self.faceDistance = distance
            self.headEulerAngles = euler
            self.blendShapes = shapes
            self.vertexCount = vCount
            if faceAnchor.isTracked {
                self.trackingFrameCount += 1
            } else {
                self.trackingFrameCount = 0
            }
        }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        print("[ARFaceManager] 錯誤：\(error.localizedDescription)")
    }

    // MARK: - 工具

    /// 從 4x4 transform 矩陣萃取歐拉角（弧度）
    static func eulerAngles(from transform: simd_float4x4) -> SIMD3<Float> {
        let sy = sqrt(transform.columns.0.x * transform.columns.0.x +
                      transform.columns.1.x * transform.columns.1.x)
        let singular = sy < 1e-6

        let x: Float  // pitch
        let y: Float  // yaw
        let z: Float  // roll

        if !singular {
            x = atan2(transform.columns.2.y, transform.columns.2.z)
            y = atan2(-transform.columns.2.x, sy)
            z = atan2(transform.columns.1.x, transform.columns.0.x)
        } else {
            x = atan2(-transform.columns.1.z, transform.columns.1.y)
            y = atan2(-transform.columns.2.x, sy)
            z = 0
        }
        return SIMD3<Float>(x, y, z)
    }
}
