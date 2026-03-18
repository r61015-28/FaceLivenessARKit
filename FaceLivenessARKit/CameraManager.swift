import AVFoundation
import Vision
import UIKit
import Combine

/// 一般相機管理器（AVFoundation + Vision Landmark）
/// 不需要 TrueDepth，所有 iOS 裝置皆可使用
final class CameraManager: NSObject, ObservableObject {

    let session = AVCaptureSession()

    // MARK: - Published 狀態

    @Published var isFaceDetected = false

    /// 臉部 bounding box（normalized 0~1，origin = bottom-left）
    @Published var faceBoundingBox: CGRect = .zero

    /// 臉寬佔畫面比例（用於判定靠近程度）
    @Published var faceWidthRatio: CGFloat = 0

    /// 鼻尖位置（image-normalized 座標）
    @Published var noseTip: CGPoint = .zero

    /// 臉輪廓最左點（接近左耳）
    @Published var leftContourOuter: CGPoint = .zero

    /// 臉輪廓最右點（接近右耳）
    @Published var rightContourOuter: CGPoint = .zero

    /// 左眼 landmark 點陣列（用於 EAR 計算）
    @Published var leftEyePoints: [CGPoint] = []

    /// 右眼 landmark 點陣列（用於 EAR 計算）
    @Published var rightEyePoints: [CGPoint] = []

    /// 幀計數器（每次偵測到臉 +1，供外部 onReceive 觸發）
    @Published var frameCount: Int = 0

    // MARK: - 內部

    private let processingQueue = DispatchQueue(label: "com.liveness.camera", qos: .userInteractive)
    private var lastFrame: UIImage?
    private var isRunning = false

    override init() {
        super.init()
        setupCamera()
    }

    func start() {
        guard !isRunning else { return }
        processingQueue.async { [weak self] in
            self?.session.startRunning()
        }
        isRunning = true
    }

    func stop() {
        session.stopRunning()
        isRunning = false
        DispatchQueue.main.async {
            self.isFaceDetected = false
            self.frameCount = 0
        }
    }

    /// 截取當前畫面
    func capturePhoto() -> UIImage? {
        return lastFrame
    }

    // MARK: - 相機設定

    private func setupCamera() {
        session.sessionPreset = .high

        guard let camera = AVCaptureDevice.default(
            .builtInWideAngleCamera, for: .video, position: .front
        ), let input = try? AVCaptureDeviceInput(device: camera) else {
            print("[CameraManager] 無法取得前鏡頭")
            return
        }

        if session.canAddInput(input) {
            session.addInput(input)
        }

        let videoOutput = AVCaptureVideoDataOutput()
        videoOutput.setSampleBufferDelegate(self, queue: processingQueue)
        videoOutput.alwaysDiscardsLateVideoFrames = true

        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
        }

        // 前鏡頭鏡像 + 直向
        if let connection = videoOutput.connection(with: .video) {
            connection.isVideoMirrored = true
            if connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
            }
        }
    }

    // MARK: - Landmark 座標轉換

    /// 將 landmark 的 bbox-relative 座標轉成 image-normalized 座標
    private func convertPoint(_ point: CGPoint, in bbox: CGRect) -> CGPoint {
        CGPoint(
            x: bbox.origin.x + point.x * bbox.width,
            y: bbox.origin.y + point.y * bbox.height
        )
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // 存最後一幀供截圖
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext()
        if let cgImage = context.createCGImage(ciImage, from: ciImage.extent) {
            lastFrame = UIImage(cgImage: cgImage)
        }

        // Vision 人臉 Landmark 偵測
        let request = VNDetectFaceLandmarksRequest { [weak self] request, error in
            self?.handleFaceResult(request: request, error: error)
        }
        request.revision = VNDetectFaceLandmarksRequestRevision3

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up)
        try? handler.perform([request])
    }

    private func handleFaceResult(request: VNRequest, error: Error?) {
        guard let results = request.results as? [VNFaceObservation],
              let face = results.first,
              let landmarks = face.landmarks else {
            DispatchQueue.main.async {
                self.isFaceDetected = false
            }
            return
        }

        let bbox = face.boundingBox

        // 鼻尖：nose region 最後一個點（tip）
        var noseTipPt: CGPoint = .zero
        if let nose = landmarks.nose {
            let points = nose.normalizedPoints
            // Vision nose region: 中間偏下的點通常是鼻尖
            // 取 y 值最小的點（Vision 座標系 y 向上，鼻尖在最下方）
            if let tip = points.min(by: { $0.y < $1.y }) {
                noseTipPt = convertPoint(tip, in: bbox)
            }
        }

        // 臉輪廓：faceContour 的第一點 ≈ 右臉邊緣，最後一點 ≈ 左臉邊緣
        var leftOuter: CGPoint = .zero
        var rightOuter: CGPoint = .zero
        if let contour = landmarks.faceContour {
            let points = contour.normalizedPoints
            if let first = points.first {
                rightOuter = convertPoint(first, in: bbox)
            }
            if let last = points.last {
                leftOuter = convertPoint(last, in: bbox)
            }
        }

        // 左眼、右眼 landmark（用於 EAR）
        var leftEye: [CGPoint] = []
        var rightEye: [CGPoint] = []
        if let le = landmarks.leftEye {
            leftEye = le.normalizedPoints.map { convertPoint($0, in: bbox) }
        }
        if let re = landmarks.rightEye {
            rightEye = re.normalizedPoints.map { convertPoint($0, in: bbox) }
        }

        DispatchQueue.main.async {
            self.isFaceDetected = true
            self.faceBoundingBox = bbox
            self.faceWidthRatio = bbox.width
            self.noseTip = noseTipPt
            self.leftContourOuter = leftOuter
            self.rightContourOuter = rightOuter
            self.leftEyePoints = leftEye
            self.rightEyePoints = rightEye
            self.frameCount += 1
        }
    }
}
