import Foundation
import CoreGraphics
import CoreML
import Vision

// MARK: - 基础 Pose 模型（保留，向后兼容 JSON 解析）
struct Pose: Codable {
    let points: [String: CGPoint]
}

// MARK: - 人物在画面中的比例
enum FrameRatio: String, CaseIterable {
    case fullBody   // 全身（头顶留 10%，脚部贴底）
    case halfBody   // 半身（腰部以上）
    case portrait   // 特写（胸部以上）

    /// 剪影高度相对屏幕高度的比例
    var heightRatio: CGFloat {
        switch self {
        case .fullBody:  return 0.80
        case .halfBody:  return 0.50
        case .portrait:  return 0.35
        }
    }

    var displayName: String {
        switch self {
        case .fullBody:  return "全身"
        case .halfBody:  return "半身"
        case .portrait:  return "特写"
        }
    }

    var icon: String {
        switch self {
        case .fullBody:  return "figure.stand"
        case .halfBody:  return "figure.arms.open"
        case .portrait:  return "person.crop.circle"
        }
    }

    var distanceHint: String {
        switch self {
        case .fullBody:  return "站远点，让镜头能拍到全身"
        case .halfBody:  return "站近些，拍到腰部以上"
        case .portrait:  return "靠近镜头，拍胸部以上"
        }
    }
}

// MARK: - 构图规则
enum CompositionRule: String, CaseIterable {
    case center      // 居中
    case leftThird   // 三分法左置
    case rightThird  // 三分法右置
    case goldenLeft  // 黄金分割左置
    case goldenRight // 黄金分割右置

    /// 剪影水平偏移量（正=向右, 负=向左, 单位 pt）
    var offset: CGFloat {
        switch self {
        case .center:      return 0
        case .leftThird:   return -80
        case .rightThird:  return 80
        case .goldenLeft:  return -55
        case .goldenRight: return 55
        }
    }

    var displayName: String {
        switch self {
        case .center:      return "居中"
        case .leftThird:   return "三分左"
        case .rightThird:  return "三分右"
        case .goldenLeft:  return "黄金左"
        case .goldenRight: return "黄金右"
        }
    }

    /// 为什么这样构图好看（向用户解释）
    var reason: String {
        switch self {
        case .center:      return "居中对称，稳重大气，适合正式感强的场景"
        case .leftThird:   return "三分法构图，人物偏左，右侧留白给视线延伸空间"
        case .rightThird:  return "三分法构图，人物偏右，左侧留白富有层次感"
        case .goldenLeft:  return "黄金分割比例，视觉最舒适的天然比例，偏左站位"
        case .goldenRight: return "黄金分割比例，视觉最舒适的天然比例，偏右站位"
        }
    }

    /// 语音提示（简短，适合 TTS）
    var voiceHint: String {
        switch self {
        case .center:      return "居中站位"
        case .leftThird:   return "站到画面左侧"
        case .rightThird:  return "站到画面右侧"
        case .goldenLeft:  return "稍微往左站"
        case .goldenRight: return "稍微往右站"
        }
    }

    var icon: String {
        switch self {
        case .center:      return "rectangle.center.inset.filled"
        case .leftThird:   return "rectangle.lefthalf.inset.filled"
        case .rightThird:  return "rectangle.righthalf.inset.filled"
        case .goldenLeft:  return "align.horizontal.left"
        case .goldenRight: return "align.horizontal.right"
        }
    }
}

// MARK: - 完整拍摄方案
struct ShootingPlan: Identifiable {
    let id: String
    let poseName: String         // 姿势名（"一手叉腰"）
    let poseEmoji: String        // 直观 emoji 代表姿势
    let poseDescription: String  // 为什么这个姿势好看
    let composition: CompositionRule
    let frameRatio: FrameRatio
    let voiceGuide: String       // 进入方案时的完整语音
    let posePoints: [String: CGPoint]  // 骨骼关键点（用于匹配得分）
}

// MARK: - 场景类型
enum SceneType: String {
    case coffee_shop = "coffee shop"
    case beach = "beach"
    case forest = "forest"
    case unknown = "unknown"

    var displayName: String {
        switch self {
        case .coffee_shop: return "咖啡馆"
        case .beach:       return "海边"
        case .forest:      return "森林"
        case .unknown:     return "未知"
        }
    }

    var icon: String {
        switch self {
        case .coffee_shop: return "cup.and.saucer.fill"
        case .beach:       return "figure.pool.swim"
        case .forest:      return "tree.fill"
        case .unknown:     return "viewfinder"
        }
    }

    /// 该场景的所有推荐方案
    var plans: [ShootingPlan] {
        PoseLibrary.shared.plans(for: self)
    }

    /// 兼容旧代码，取第一个方案的关键点
    var recommendedPose: Pose {
        Pose(points: plans.first?.posePoints ?? [:])
    }
}

// MARK: - 姿势库管理器
final class PoseLibrary {
    static let shared = PoseLibrary()

    private init() {}

    func plans(for scene: SceneType) -> [ShootingPlan] {
        switch scene {
        case .coffee_shop: return coffeePlans
        case .beach:       return beachPlans
        case .forest:      return forestPlans
        case .unknown:     return []
        }
    }

    // MARK: 咖啡馆方案（3 套）
    private var coffeePlans: [ShootingPlan] = [
        ShootingPlan(
            id: "coffee_lean",
            poseName: "侧身靠墙",
            poseEmoji: "🧍",
            poseDescription: "一侧靠墙，视线望向远处，展现慵懒文艺气质",
            composition: .goldenLeft,
            frameRatio: .halfBody,
            voiceGuide: "侧身靠着墙或椅背，目光看向右侧，黄金分割构图，显气质",
            posePoints: [
                "neck":          CGPoint(x: 0.48, y: 0.32),
                "leftShoulder":  CGPoint(x: 0.38, y: 0.42),
                "rightShoulder": CGPoint(x: 0.58, y: 0.40),
                "leftElbow":     CGPoint(x: 0.30, y: 0.56),
                "rightElbow":    CGPoint(x: 0.64, y: 0.52),
                "leftWrist":     CGPoint(x: 0.28, y: 0.68),
                "rightWrist":    CGPoint(x: 0.66, y: 0.62),
                "leftHip":       CGPoint(x: 0.42, y: 0.62),
                "rightHip":      CGPoint(x: 0.56, y: 0.61)
            ]
        ),
        ShootingPlan(
            id: "coffee_cup",
            poseName: "双手捧杯",
            poseEmoji: "☕",
            poseDescription: "双手轻托咖啡杯，低头微笑，生活感十足的氛围照",
            composition: .center,
            frameRatio: .halfBody,
            voiceGuide: "双手捧着杯子，微微低头或看向镜头，居中构图，温柔有氛围",
            posePoints: [
                "neck":          CGPoint(x: 0.50, y: 0.33),
                "leftShoulder":  CGPoint(x: 0.38, y: 0.42),
                "rightShoulder": CGPoint(x: 0.62, y: 0.42),
                "leftElbow":     CGPoint(x: 0.36, y: 0.56),
                "rightElbow":    CGPoint(x: 0.64, y: 0.56),
                "leftWrist":     CGPoint(x: 0.42, y: 0.65),
                "rightWrist":    CGPoint(x: 0.58, y: 0.65),
                "leftHip":       CGPoint(x: 0.44, y: 0.62),
                "rightHip":      CGPoint(x: 0.56, y: 0.62)
            ]
        ),
        ShootingPlan(
            id: "coffee_window",
            poseName: "望向窗外",
            poseEmoji: "🪟",
            poseDescription: "侧身望向窗外自然光，轮廓在逆光下格外迷人",
            composition: .rightThird,
            frameRatio: .fullBody,
            voiceGuide: "身体转向侧面，望向窗外方向，人物偏右构图，光线打亮脸部轮廓",
            posePoints: [
                "neck":          CGPoint(x: 0.50, y: 0.28),
                "leftShoulder":  CGPoint(x: 0.38, y: 0.38),
                "rightShoulder": CGPoint(x: 0.62, y: 0.38),
                "leftElbow":     CGPoint(x: 0.30, y: 0.52),
                "rightElbow":    CGPoint(x: 0.70, y: 0.52),
                "leftWrist":     CGPoint(x: 0.28, y: 0.65),
                "rightWrist":    CGPoint(x: 0.72, y: 0.50),
                "leftHip":       CGPoint(x: 0.44, y: 0.60),
                "rightHip":      CGPoint(x: 0.56, y: 0.60),
                "leftKnee":      CGPoint(x: 0.42, y: 0.78),
                "rightKnee":     CGPoint(x: 0.58, y: 0.78)
            ]
        )
    ]

    // MARK: 海边方案（3 套）
    private var beachPlans: [ShootingPlan] = [
        ShootingPlan(
            id: "beach_open",
            poseName: "张开双臂",
            poseEmoji: "🌊",
            poseDescription: "张开双臂拥抱大海，自由奔放，视觉冲击力强",
            composition: .center,
            frameRatio: .fullBody,
            voiceGuide: "站在沙滩上，双臂向两侧平展张开，面朝镜头，居中全身构图，感受自由",
            posePoints: [
                "neck":          CGPoint(x: 0.50, y: 0.28),
                "leftShoulder":  CGPoint(x: 0.32, y: 0.36),
                "rightShoulder": CGPoint(x: 0.68, y: 0.36),
                "leftElbow":     CGPoint(x: 0.16, y: 0.36),
                "rightElbow":    CGPoint(x: 0.84, y: 0.36),
                "leftWrist":     CGPoint(x: 0.05, y: 0.36),
                "rightWrist":    CGPoint(x: 0.95, y: 0.36),
                "leftHip":       CGPoint(x: 0.44, y: 0.58),
                "rightHip":      CGPoint(x: 0.56, y: 0.58),
                "leftKnee":      CGPoint(x: 0.42, y: 0.76),
                "rightKnee":     CGPoint(x: 0.58, y: 0.76),
                "leftAnkle":     CGPoint(x: 0.40, y: 0.92),
                "rightAnkle":    CGPoint(x: 0.60, y: 0.92)
            ]
        ),
        ShootingPlan(
            id: "beach_sunshield",
            poseName: "单手遮阳",
            poseEmoji: "🌅",
            poseDescription: "单手搭凉篷遮阳，侧脸望远，充满故事感",
            composition: .leftThird,
            frameRatio: .halfBody,
            voiceGuide: "一只手遮在额头上遮阳，眼神望向远方，偏左三分法，很有电影感",
            posePoints: [
                "neck":          CGPoint(x: 0.50, y: 0.30),
                "leftShoulder":  CGPoint(x: 0.38, y: 0.40),
                "rightShoulder": CGPoint(x: 0.62, y: 0.40),
                "leftElbow":     CGPoint(x: 0.34, y: 0.54),
                "rightElbow":    CGPoint(x: 0.68, y: 0.38),
                "leftWrist":     CGPoint(x: 0.32, y: 0.66),
                "rightWrist":    CGPoint(x: 0.60, y: 0.26),
                "leftHip":       CGPoint(x: 0.44, y: 0.62),
                "rightHip":      CGPoint(x: 0.56, y: 0.62)
            ]
        ),
        ShootingPlan(
            id: "beach_tiptoe",
            poseName: "踮脚望远",
            poseEmoji: "🦩",
            poseDescription: "踮起脚尖望向远方，拉长腿部线条，显高显腿长",
            composition: .goldenRight,
            frameRatio: .fullBody,
            voiceGuide: "踮起脚尖，微微仰头，双腿收紧，偏右黄金分割，线条超美",
            posePoints: [
                "neck":          CGPoint(x: 0.50, y: 0.25),
                "leftShoulder":  CGPoint(x: 0.40, y: 0.34),
                "rightShoulder": CGPoint(x: 0.60, y: 0.34),
                "leftElbow":     CGPoint(x: 0.36, y: 0.48),
                "rightElbow":    CGPoint(x: 0.64, y: 0.48),
                "leftWrist":     CGPoint(x: 0.38, y: 0.60),
                "rightWrist":    CGPoint(x: 0.62, y: 0.60),
                "leftHip":       CGPoint(x: 0.44, y: 0.55),
                "rightHip":      CGPoint(x: 0.56, y: 0.55),
                "leftKnee":      CGPoint(x: 0.43, y: 0.72),
                "rightKnee":     CGPoint(x: 0.57, y: 0.72),
                "leftAnkle":     CGPoint(x: 0.43, y: 0.88),
                "rightAnkle":    CGPoint(x: 0.57, y: 0.88)
            ]
        )
    ]

    // MARK: 森林方案（3 套）
    private var forestPlans: [ShootingPlan] = [
        ShootingPlan(
            id: "forest_lean_tree",
            poseName: "倚树而立",
            poseEmoji: "🌲",
            poseDescription: "背靠树干，一手轻搭树，自然随性，与环境融为一体",
            composition: .goldenRight,
            frameRatio: .fullBody,
            voiceGuide: "找棵树靠着，一只手搭在树上，另一手自然垂放，黄金分割偏右，很自然",
            posePoints: [
                "neck":          CGPoint(x: 0.50, y: 0.28),
                "leftShoulder":  CGPoint(x: 0.38, y: 0.38),
                "rightShoulder": CGPoint(x: 0.62, y: 0.38),
                "leftElbow":     CGPoint(x: 0.30, y: 0.52),
                "rightElbow":    CGPoint(x: 0.68, y: 0.44),
                "leftWrist":     CGPoint(x: 0.28, y: 0.64),
                "rightWrist":    CGPoint(x: 0.72, y: 0.36),
                "leftHip":       CGPoint(x: 0.44, y: 0.60),
                "rightHip":      CGPoint(x: 0.56, y: 0.60),
                "leftKnee":      CGPoint(x: 0.43, y: 0.77),
                "rightKnee":     CGPoint(x: 0.57, y: 0.77),
                "leftAnkle":     CGPoint(x: 0.42, y: 0.92),
                "rightAnkle":    CGPoint(x: 0.58, y: 0.92)
            ]
        ),
        ShootingPlan(
            id: "forest_squat",
            poseName: "蹲下仰拍",
            poseEmoji: "🍃",
            poseDescription: "双膝微蹲，仰头望向树梢，展现渺小又治愈的氛围感",
            composition: .center,
            frameRatio: .halfBody,
            voiceGuide: "双腿微曲蹲下，头微微仰起，居中构图，上方是树，氛围感超强",
            posePoints: [
                "neck":          CGPoint(x: 0.50, y: 0.35),
                "leftShoulder":  CGPoint(x: 0.38, y: 0.44),
                "rightShoulder": CGPoint(x: 0.62, y: 0.44),
                "leftElbow":     CGPoint(x: 0.32, y: 0.56),
                "rightElbow":    CGPoint(x: 0.68, y: 0.56),
                "leftWrist":     CGPoint(x: 0.38, y: 0.68),
                "rightWrist":    CGPoint(x: 0.62, y: 0.68),
                "leftHip":       CGPoint(x: 0.42, y: 0.64),
                "rightHip":      CGPoint(x: 0.58, y: 0.64),
                "leftKnee":      CGPoint(x: 0.38, y: 0.80),
                "rightKnee":     CGPoint(x: 0.62, y: 0.80)
            ]
        ),
        ShootingPlan(
            id: "forest_walk",
            poseName: "穿越步伐",
            poseEmoji: "🚶",
            poseDescription: "迈步行走，侧身或背对镜头，动态感十足的森系大片",
            composition: .leftThird,
            frameRatio: .fullBody,
            voiceGuide: "面向前方迈步走，可以侧脸或背对镜头，偏左构图，前方留空间，动感十足",
            posePoints: [
                "neck":          CGPoint(x: 0.50, y: 0.26),
                "leftShoulder":  CGPoint(x: 0.38, y: 0.36),
                "rightShoulder": CGPoint(x: 0.62, y: 0.36),
                "leftElbow":     CGPoint(x: 0.32, y: 0.50),
                "rightElbow":    CGPoint(x: 0.68, y: 0.50),
                "leftWrist":     CGPoint(x: 0.36, y: 0.62),
                "rightWrist":    CGPoint(x: 0.64, y: 0.44),
                "leftHip":       CGPoint(x: 0.42, y: 0.58),
                "rightHip":      CGPoint(x: 0.58, y: 0.58),
                "leftKnee":      CGPoint(x: 0.38, y: 0.74),
                "rightKnee":     CGPoint(x: 0.60, y: 0.70),
                "leftAnkle":     CGPoint(x: 0.36, y: 0.90),
                "rightAnkle":    CGPoint(x: 0.62, y: 0.86)
            ]
        )
    ]
}

// MARK: - 场景分类协议
protocol SceneClassificationProvider {
    func classify(pixelBuffer: CVPixelBuffer, completion: @escaping (SceneType) -> Void)
}

// MARK: - MobileNetV2 场景分类实现
class MobileNetV2SceneProvider: SceneClassificationProvider {
    private let visionQueue = DispatchQueue(label: "com.poseai.sceneQueue", qos: .utility)
    private var mlModel: VNCoreMLModel?

    /// 供 VisionService 检查模型是否成功加载
    var isModelLoaded: Bool { mlModel != nil }

    init() {
        let modelName = "MobileNetV2"
        let compiledURL = Bundle.main.url(forResource: modelName, withExtension: "mlmodelc")
            ?? (Bundle.main.url(forResource: modelName, withExtension: "mlmodel")
                .flatMap { try? MLModel.compileModel(at: $0) })
        if let url = compiledURL,
           let compiled = try? MLModel(contentsOf: url),
           let visionModel = try? VNCoreMLModel(for: compiled) {
            self.mlModel = visionModel
        }
    }

    func classify(pixelBuffer: CVPixelBuffer, completion: @escaping (SceneType) -> Void) {
        guard let mlModel = mlModel else {
            DispatchQueue.main.async { completion(.unknown) }
            return
        }

        let request = VNCoreMLRequest(model: mlModel) { req, _ in
            guard let results = req.results as? [VNClassificationObservation],
                  !results.isEmpty else {
                DispatchQueue.main.async { completion(.unknown) }
                return
            }

            // MARK: 扩充关键词：覆盖 ImageNet 更多类别
            // 咖啡馆 / 室内 / 餐饮场景
            let coffeeKeywords = [
                "coffee", "espresso", "cappuccino", "latte", "cup", "mug", "coffeepot",
                "restaurant", "dining", "cafeteria", "table", "chair", "stool", "bar",
                "bakery", "wine", "beer", "bottle", "plate", "food", "bread", "cake",
                "bookcase", "bookshelf", "library", "desk", "laptop", "computer",
                "sofa", "couch", "studio", "interior", "room", "wall", "window",
                "curtain", "mirror", "vase", "lamp", "pot", "kitchen", "counter",
                "mall", "shop", "store", "street", "city", "building", "corridor"
            ]

            // 海边 / 水景 / 户外开阔场景
            let beachKeywords = [
                "beach", "seashore", "sandbar", "ocean", "sea", "shore", "coast",
                "lakeside", "lake", "river", "water", "pool", "wave", "tide",
                "promontory", "breakwater", "dock", "pier", "boat", "ship", "surf",
                "sand", "sunscreen", "umbrella", "swimsuit", "bikini", "horizon",
                "sky", "sunset", "sunrise", "cloud", "cliff", "rock", "stone"
            ]

            // 森林 / 自然 / 植物场景
            let forestKeywords = [
                "forest", "woodland", "jungle", "tree", "rainforest", "pine", "oak",
                "fern", "plant", "leaf", "leaves", "grass", "flower", "garden",
                "mushroom", "moss", "bark", "branch", "bush", "shrub", "bamboo",
                "mountain", "hill", "valley", "meadow", "field", "park", "path",
                "trail", "nature", "green", "wilderness", "spring"
            ]

            // top-5 结果投票（避免第一名抖动导致误判）
            let topResults = Array(results.prefix(5))

            var votes: [SceneType: Float] = [.coffee_shop: 0, .beach: 0, .forest: 0]
            for obs in topResults {
                let id = obs.identifier.lowercased()
                let w = obs.confidence
                if coffeeKeywords.contains(where: { id.contains($0) }) { votes[.coffee_shop]! += w }
                if beachKeywords.contains(where:  { id.contains($0) }) { votes[.beach]!       += w }
                if forestKeywords.contains(where: { id.contains($0) }) { votes[.forest]!      += w }
            }

            // 取投票权重最高的场景
            let best = votes.max(by: { $0.value < $1.value })

            var scene: SceneType
            if let best = best, best.value > 0 {
                scene = best.key
            } else {
                // 完全无关键词匹配：用 top-1 的绝对置信度兜底
                // 置信度 > 0.05 就给一个通用室内方案（咖啡馆方案最丰富）
                let top1 = results[0]
                scene = top1.confidence > 0.05 ? .coffee_shop : .unknown
                if scene != .unknown {
                    print("[Scene] 关键词未匹配，兜底coffee_shop | top1=\(top1.identifier) conf=\(top1.confidence)")
                }
            }

            // Debug 日志（Release 可删）
            print("[Scene] → \(scene.rawValue) | \(topResults.prefix(3).map { "\($0.identifier)(\(String(format:"%.2f",$0.confidence)))" }.joined(separator:", "))")

            DispatchQueue.main.async { completion(scene) }
        }
        request.imageCropAndScaleOption = .centerCrop

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        visionQueue.async { try? handler.perform([request]) }
    }
}

// MARK: - Mock 场景分类（模拟器降级）
class MockSceneProvider: SceneClassificationProvider {
    private let scenes: [SceneType] = [.coffee_shop, .beach, .forest]
    private var index = 0

    func classify(pixelBuffer: CVPixelBuffer, completion: @escaping (SceneType) -> Void) {
        let scene = scenes[index % scenes.count]
        index += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { completion(scene) }
    }
}
