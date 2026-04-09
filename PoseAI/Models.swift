import Foundation
import CoreGraphics
import CoreML
import Vision

// MARK: - Pose 模型
struct Pose: Codable {
    let points: [String: CGPoint]
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
        case .beach: return "海滩"
        case .forest: return "森林"
        case .unknown: return "未知"
        }
    }

    var recommendedPose: Pose {
        return PoseLibrary.shared.pose(for: self)
    }
}

// MARK: - 姿势库管理器 (JSON 化、支持热更新思路)
final class PoseLibrary {
    static let shared = PoseLibrary()
    private var poses: [String: Pose] = [:]
    
    private init() {
        loadPoses()
    }
    
    func loadPoses() {
        // 从本地加载 JSON 配置，保留未来从 Server 下载替换的设计空间
        guard let url = Bundle.main.url(forResource: "Poses", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let dict = try? JSONDecoder().decode([String: Pose].self, from: data) else {
            // 解析失败时提供极其基础的默认站姿，避免崩溃
            print("Failed to load Poses.json, using fallback")
            poses = [:]
            return
        }
        poses = dict
    }
    
    func pose(for scene: SceneType) -> Pose {
        // 如果找不到匹配场景，退回 unknown 座标
        return poses[scene.rawValue] ?? poses[SceneType.unknown.rawValue] ?? Pose(points: ["neck": CGPoint(x: 0.5, y: 0.3)])
    }
}

// MARK: - 场景分类协议（面向接口，方便后续替换模型）
protocol SceneClassificationProvider {
    func classify(pixelBuffer: CVPixelBuffer, completion: @escaping (SceneType) -> Void)
}

// MARK: - MobileNetV2 场景分类实现
// 注意：需要将 MobileNetV2.mlmodel 拖入 Xcode 项目才能使用此实现。
// 模型下载：https://developer.apple.com/machine-learning/models/ 搜索 MobileNetV2
// 若未添加模型，系统将自动降级使用 MockSceneProvider。
class MobileNetV2SceneProvider: SceneClassificationProvider {
    private let visionQueue = DispatchQueue(label: "com.poseai.sceneQueue", qos: .utility)
    private var mlModel: VNCoreMLModel?

    init() {
        // 动态加载模型，避免编译期强依赖
        // 优先查找已编译版本（.mlmodelc），其次查找源版本（.mlmodel）
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
            // 降级：模型未加载时返回 unknown
            DispatchQueue.main.async { completion(.unknown) }
            return
        }

        let request = VNCoreMLRequest(model: mlModel) { req, _ in
            guard let results = req.results as? [VNClassificationObservation],
                  let top = results.first else {
                DispatchQueue.main.async { completion(.unknown) }
                return
            }

            // MobileNetV2 输出 ImageNet 1000类，使用关键词映射到业务场景
            // ImageNet 类名格式：snake_case，如 "coffee_mug", "seashore"
            var scene = SceneType.unknown
            let id = top.identifier.lowercased()

            // 咖啡馆关键词（ImageNet 餐具/饮品类）
            let coffeeKeywords = ["coffee", "espresso", "cappuccino", "cup", "mug",
                                  "coffeepot", "french_loaf", "dining_table", "restaurant"]
            // 海滩关键词（ImageNet 地貌/水域类）
            let beachKeywords  = ["beach", "seashore", "sandbar", "lakeside", "ocean",
                                  "sea", "shore", "coast", "promontory", "breakwater"]
            // 森林关键词（ImageNet 植物/自然类）
            let forestKeywords = ["forest", "woodland", "jungle", "tree", "fern",
                                  "plant", "leaf", "mushroom", "rainforest", "pine"]

            if coffeeKeywords.contains(where: { id.contains($0) }) {
                scene = .coffee_shop
            } else if beachKeywords.contains(where: { id.contains($0) }) {
                scene = .beach
            } else if forestKeywords.contains(where: { id.contains($0) }) {
                scene = .forest
            }

            DispatchQueue.main.async { completion(scene) }
        }
        request.imageCropAndScaleOption = .centerCrop

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        visionQueue.async {
            try? handler.perform([request])
        }
    }
}

// MARK: - Mock 场景分类（无需 mlmodel，供模拟器或降级使用）
class MockSceneProvider: SceneClassificationProvider {
    private let scenes: [SceneType] = [.coffee_shop, .beach, .forest]
    private var index = 0

    func classify(pixelBuffer: CVPixelBuffer, completion: @escaping (SceneType) -> Void) {
        // 每次调用轮换场景，方便开发调试
        let scene = scenes[index % scenes.count]
        index += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { completion(scene) }
    }
}
