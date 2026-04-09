import Vision
import AVFoundation

// MARK: - AI 视觉处理服务
// 负责：高频姿态识别（~30fps）+ 低频场景分类（~0.5fps）
// 关键：使用 autoreleasepool 防止高频 CVPixelBuffer 造成内存泄漏
final class VisionService {

    // MARK: - 配置
    private let visionQueue = DispatchQueue(
        label: "com.poseai.visionQueue",
        qos: .userInitiated
    )

    /// 场景识别最小间隔（秒），避免高频调用导致性能下降
    private let sceneUpdateInterval: TimeInterval = 2.0
    private var lastSceneUpdate: Date = .distantPast

    /// 场景分类器（可运行时替换，支持 Mock 降级）
    lazy var sceneProvider: SceneClassificationProvider = {
        // 优先使用 GoogLeNet；若模型未加载，自动切换 Mock
        let provider = MobileNetV2SceneProvider()
        return provider
    }()

    // MARK: - 回调
    /// 姿态数据回调：(关节坐标字典, 是否半身模式)
    var onUpdate: (([String: CGPoint], Bool) -> Void)?
    /// 场景变化回调
    var onSceneChange: ((SceneType) -> Void)?

    /// 前置摄像头标志（影响 X 轴镜像修正）
    var isFrontCamera: Bool = false

    // MARK: - 帧处理入口
    func process(_ buffer: CMSampleBuffer) {
        // ⚠️ 关键：高频处理必须使用 autoreleasepool 手动管理内存
        autoreleasepool {
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(buffer) else { return }

            // 1. 高频姿态检测（每帧执行）
            let poseRequest = VNDetectHumanBodyPoseRequest { [weak self] req, error in
                if let error = error {
                    print("[VisionService] Pose error: \(error.localizedDescription)")
                    return
                }
                self?.handlePose(req)
            }

            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
            visionQueue.async { [weak self] in
                guard self != nil else { return }
                try? handler.perform([poseRequest])
            }

            // 2. 低频场景分类（每 sceneUpdateInterval 秒一次）
            let now = Date()
            if now.timeIntervalSince(lastSceneUpdate) > sceneUpdateInterval {
                lastSceneUpdate = now
                // 注意：CVPixelBuffer 需要 retain 后跨线程传递
                let retainedBuffer = pixelBuffer
                sceneProvider.classify(pixelBuffer: retainedBuffer) { [weak self] scene in
                    self?.onSceneChange?(scene)
                }
            }
        }
    }

    // MARK: - 姿态结果解析
    private func handlePose(_ request: VNRequest) {
        guard let observation = request.results?.first as? VNHumanBodyPoseObservation else {
            // 未检测到人体，返回空数据
            DispatchQueue.main.async { [weak self] in
                self?.onUpdate?([:], true)
            }
            return
        }

        var points: [String: CGPoint] = [:]
        var lowerBodyConfSum: Float = 0
        var lowerBodyCount = 0

        guard let recognized = try? observation.recognizedPoints(.all) else { return }

        for (joint, point) in recognized {
            // 置信度过滤：低于 0.3 的关节不可靠
            guard point.confidence > 0.3 else { continue }

            var x = point.location.x
            // 前置摄像头：Vision 坐标系已做镜像，需反转 X 轴对齐屏幕
            if isFrontCamera { x = 1.0 - x }

            // Vision 坐标系 Y 轴朝上，转换为 SwiftUI 的 Y 轴朝下
            let y = 1.0 - point.location.y

            // 映射 Vision 原生 JointName 到自定义 String key
            guard let key = mapJointName(joint) else { continue }
            points[key] = CGPoint(x: x, y: y)

            // 统计下半身关节的平均置信度
            if PoseMatcher.lowerBodyJoints.contains(key) {
                lowerBodyConfSum += point.confidence
                lowerBodyCount += 1
            }
        }
        // 半身模式判定：下半身关节平均置信度低于阈值 → 判定为半身拍摄
        let avgLowerConf = lowerBodyCount > 0
            ? lowerBodyConfSum / Float(lowerBodyCount)
            : 0
        let isHalfBody = avgLowerConf < 0.25

        DispatchQueue.main.async { [weak self] in
            self?.onUpdate?(points, isHalfBody)
        }
    }

    // MARK: - 关节字段映射
    private func mapJointName(_ joint: VNHumanBodyPoseObservation.JointName) -> String? {
        switch joint {
        case .leftShoulder: return "leftShoulder"
        case .rightShoulder: return "rightShoulder"
        case .leftElbow: return "leftElbow"
        case .rightElbow: return "rightElbow"
        case .leftWrist: return "leftWrist"
        case .rightWrist: return "rightWrist"
        case .leftHip: return "leftHip"
        case .rightHip: return "rightHip"
        case .leftKnee: return "leftKnee"
        case .rightKnee: return "rightKnee"
        case .leftAnkle: return "leftAnkle"
        case .rightAnkle: return "rightAnkle"
        case .neck: return "neck"
        default: return nil
        }
    }
}
