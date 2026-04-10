import Vision
import AVFoundation

// MARK: - AI 视觉处理服务
// 负责：高频姿态识别（~30fps）+ 低频场景分类（~0.5fps）+ 场景防抖
final class VisionService {

    // MARK: - 配置
    private let visionQueue = DispatchQueue(
        label: "com.poseai.visionQueue",
        qos: .userInitiated
    )

    /// 场景识别最小间隔（秒）
    private let sceneUpdateInterval: TimeInterval = 2.0
    private var lastSceneUpdate: Date = .distantPast

    /// 场景防抖：连续 2 次相同才触发（每次间隔 2s，共 ~4s）
    private let sceneDebounceThreshold = 2
    private var sceneVoteBuffer: [SceneType] = []

    /// 场景分类器（MobileNetV2 失败时自动降级 Mock）
    lazy var sceneProvider: SceneClassificationProvider = {
        let provider = MobileNetV2SceneProvider()
        guard provider.isModelLoaded else {
            print("[VisionService] MobileNetV2 未加载，降级为 MockSceneProvider")
            return MockSceneProvider()
        }
        return provider
    }()

    // MARK: - 回调
    /// points: 关节归一化坐标(0~1)
    /// isHalfBody: 是否半身
    /// bodyBoundingBox: 人体在画面中的归一化包围盒 (x,y,w,h)，可能为 nil（未检测到人）
    var onUpdate: (([String: CGPoint], Bool, CGRect?) -> Void)?
    var onSceneChange: ((SceneType) -> Void)?
    /// 暗光监测：检测到人体但关节置信度测极低时触发
    var onLowLight: ((Bool) -> Void)?
    private var lastLowLightTime: Date = .distantPast
    private let lowLightInterval: TimeInterval = 5.0
    private var isCurrentlyLowLight: Bool = false

    var isFrontCamera: Bool = false

    // MARK: - 帧处理入口
    func process(_ buffer: CMSampleBuffer) {
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

            // 2. 低频场景分类（每 2s 一次，防抖 2 帧）
            let now = Date()
            if now.timeIntervalSince(lastSceneUpdate) > sceneUpdateInterval {
                lastSceneUpdate = now
                let retainedBuffer = pixelBuffer
                sceneProvider.classify(pixelBuffer: retainedBuffer) { [weak self] scene in
                    self?.handleSceneResult(scene)
                }
            }
        }
    }

    // MARK: - 场景防抖处理
    private func handleSceneResult(_ scene: SceneType) {
        // unknown 不进 buffer，但也不重置（避免偶发 unknown 打断连续性）
        guard scene != .unknown else { return }

        sceneVoteBuffer.append(scene)
        if sceneVoteBuffer.count > sceneDebounceThreshold {
            sceneVoteBuffer.removeFirst()
        }

        // 连续 N 帧一致才触发
        guard sceneVoteBuffer.count == sceneDebounceThreshold,
              sceneVoteBuffer.allSatisfy({ $0 == scene }) else { return }

        sceneVoteBuffer.removeAll()
        onSceneChange?(scene)
    }

    // MARK: - 姿态结果解析
    private func handlePose(_ request: VNRequest) {
        guard let observation = request.results?.first as? VNHumanBodyPoseObservation else {
            DispatchQueue.main.async { [weak self] in self?.onUpdate?([:], true, nil) }
            return
        }

        var points: [String: CGPoint] = [:]
        var lowerBodyConfSum: Float = 0
        var lowerBodyCount = 0
        // 用于计算人体包围盒（归一化坐标系，翻转 y 使 0=顶部）
        var minX: CGFloat = 1.0, maxX: CGFloat = 0.0
        var minY: CGFloat = 1.0, maxY: CGFloat = 0.0

        guard let recognized = try? observation.recognizedPoints(.all) else { return }

        for (joint, point) in recognized {
            guard point.confidence > 0.3 else { continue }
            var x = point.location.x
            if isFrontCamera { x = 1.0 - x }
            let y = 1.0 - point.location.y   // 翻转：0=顶部 1=底部
            guard let key = mapJointName(joint) else { continue }
            points[key] = CGPoint(x: x, y: y)
            // 更新包围盒
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
            if PoseMatcher.lowerBodyJoints.contains(key) {
                lowerBodyConfSum += point.confidence
                lowerBodyCount += 1
            }
        }

        let avgLowerConf = lowerBodyCount > 0 ? lowerBodyConfSum / Float(lowerBodyCount) : 0
        let isHalfBody = avgLowerConf < 0.25

        // 有效点足够多时才输出包围盒
        let bbox: CGRect? = points.count >= 3
            ? CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            : nil

        // MARK: 暗光检测：有人（observation 存在）但有效关节点极少 → 光线不足
        // 阈值：有效点 < 4（正常光线下应该能识别 8+ 个关节）
        let lowLight = points.count < 4
        let now = Date()
        if lowLight != isCurrentlyLowLight {
            if now.timeIntervalSince(lastLowLightTime) > lowLightInterval || !lowLight {
                isCurrentlyLowLight = lowLight
                lastLowLightTime = now
                DispatchQueue.main.async { [weak self] in self?.onLowLight?(lowLight) }
            }
        }

        DispatchQueue.main.async { [weak self] in self?.onUpdate?(points, isHalfBody, bbox) }
    }

    // MARK: - 关节字段映射
    private func mapJointName(_ joint: VNHumanBodyPoseObservation.JointName) -> String? {
        switch joint {
        case .leftShoulder:  return "leftShoulder"
        case .rightShoulder: return "rightShoulder"
        case .leftElbow:     return "leftElbow"
        case .rightElbow:    return "rightElbow"
        case .leftWrist:     return "leftWrist"
        case .rightWrist:    return "rightWrist"
        case .leftHip:       return "leftHip"
        case .rightHip:      return "rightHip"
        case .leftKnee:      return "leftKnee"
        case .rightKnee:     return "rightKnee"
        case .leftAnkle:     return "leftAnkle"
        case .rightAnkle:    return "rightAnkle"
        case .neck:          return "neck"
        default:             return nil
        }
    }
}
