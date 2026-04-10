import AVFoundation
import SwiftUI
import CoreMotion

// MARK: - 摄像头管理器
// 负责 AVCaptureSession 的生命周期、前后置切换、帧输出
final class CameraManager: NSObject, ObservableObject {

    // MARK: - 公开属性
    let session = AVCaptureSession()
    let visionService = VisionService()

    /// 拍照成功回调，传回原始 UIImage，由上层 UI 决定是否保存
    var onPhotoCapture: ((UIImage) -> Void)?

    @Published var isFront: Bool = false {
        didSet {
            visionService.isFrontCamera = isFront
            configure() // 切换摄像头时重新配置 session
        }
    }

    @Published var authorizationStatus: AVAuthorizationStatus = .notDetermined
    
    /// 设备俯仰角（弧度）：正数仰拍，负数俯拍（手机上半部向前倾）。例如 -0.4 约等于俯角 23度
    @Published var devicePitch: Double = 0.0

    // MARK: - 私有属性
    private let videoOutput = AVCaptureVideoDataOutput()
    private let photoOutput = AVCapturePhotoOutput()
    private let motionManager = CMMotionManager()
    private let frameQueue = DispatchQueue(
        label: "com.poseai.videoQueue",
        qos: .userInteractive
    )

    // MARK: - Init
    override init() {
        super.init()
        checkAuthorization()
        startMotionTracking()
    }
    
    private func startMotionTracking() {
        guard motionManager.isDeviceMotionAvailable else { return }
        motionManager.deviceMotionUpdateInterval = 0.2 // 1秒5次足够防直男拍照
        motionManager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let motion = motion else { return }
            self?.devicePitch = motion.attitude.pitch
        }
    }

    // MARK: - 权限检查
    func checkAuthorization() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            authorizationStatus = .authorized
            configure()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    self?.authorizationStatus = granted ? .authorized : .denied
                    if granted { self?.configure() }
                }
            }
        case .denied, .restricted:
            authorizationStatus = .denied
        @unknown default:
            break
        }
    }

    // MARK: - Session 配置
    func configure() {
        // 在后台线程配置，避免阻塞主线程
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.setupSession()
        }
    }

    private func setupSession() {
        session.beginConfiguration()
        session.sessionPreset = .hd1280x720

        // 移除旧输入
        session.inputs.forEach { session.removeInput($0) }

        // 添加新摄像头输入
        let position: AVCaptureDevice.Position = isFront ? .front : .back
        if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
           let input = try? AVCaptureDeviceInput(device: device),
           session.canAddInput(input) {
            session.addInput(input)
        }

        // 添加视频输出（仅首次）
        if !session.outputs.contains(videoOutput) {
            videoOutput.setSampleBufferDelegate(self, queue: frameQueue)
            videoOutput.alwaysDiscardsLateVideoFrames = true // 保持实时性，丢弃积压帧
            if session.canAddOutput(videoOutput) {
                session.addOutput(videoOutput)
            }
        }

        // 添加拍照输出（仅首次）
        if !session.outputs.contains(photoOutput) {
            if session.canAddOutput(photoOutput) {
                session.addOutput(photoOutput)
            }
        }

        // 修正视频方向
        if let connection = videoOutput.connection(with: .video) {
            if connection.isVideoOrientationSupported {
                connection.videoOrientation = .portrait
            }
            if connection.isVideoMirroringSupported {
                connection.isVideoMirrored = isFront
            }
        }

        session.commitConfiguration()
    }

    // MARK: - Session 控制
    func start() {
        guard !session.isRunning else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.session.startRunning()
        }
    }

    func stop() {
        guard session.isRunning else { return }
        DispatchQueue.global(qos: .background).async { [weak self] in
            self?.session.stopRunning()
        }
    }

    // MARK: - 拍照接口
    func takePhoto() {
        // 这里的配置极其重要：防止照出来的原图是横向的或是没有前置镜像的！ (经典底层Bug修复)
        if let connection = photoOutput.connection(with: .video) {
            if connection.isVideoOrientationSupported {
                connection.videoOrientation = .portrait
            }
            if connection.isVideoMirroringSupported {
                connection.isVideoMirrored = isFront
            }
        }
        
        let settings = AVCapturePhotoSettings()
        // 建议开启防抖，特别适用于这种需要定格 0.5 秒的抓拍场景
        settings.photoQualityPrioritization = .balanced
        photoOutput.capturePhoto(with: settings, delegate: self)
    }
}

// MARK: - AVCapturePhotoCaptureDelegate
extension CameraManager: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil else {
            print("📸 照片捕获失败: \(String(describing: error))")
            return
        }
        guard let imageData = photo.fileDataRepresentation(),
              let image = UIImage(data: imageData) else { return }

        // 触觉反馈
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()

        // 回调给上层（ContentView 负责展示预览 + 用户确认后保存）
        DispatchQueue.main.async { [weak self] in
            self?.onPhotoCapture?(image)
        }
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate
extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        visionService.process(sampleBuffer)
    }
}

// MARK: - SwiftUI 摄像头预览层
struct CameraPreview: UIViewRepresentable {
    @ObservedObject var manager: CameraManager

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.session = manager.session
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {
        // 前后置切换时更新预览层（镜像由 AVCaptureConnection 处理）
    }

    // MARK: 自定义 UIView 确保预览层自动适配尺寸
    class PreviewUIView: UIView {
        override class var layerClass: AnyClass {
            AVCaptureVideoPreviewLayer.self
        }

        var previewLayer: AVCaptureVideoPreviewLayer {
            layer as! AVCaptureVideoPreviewLayer
        }

        var session: AVCaptureSession? {
            didSet { previewLayer.session = session }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            previewLayer.videoGravity = .resizeAspectFill
            previewLayer.frame = bounds
        }
    }
}
