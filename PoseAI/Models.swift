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
    case city_street = "city street"
    case park = "park"
    case indoor_home = "indoor home"
    case neon_night = "neon night"
    case unknown = "unknown"

    var displayName: String {
        switch self {
        case .coffee_shop: return "咖啡馆"
        case .beach:       return "海边"
        case .forest:      return "森林"
        case .city_street: return "城市街道"
        case .park:        return "公园"
        case .indoor_home: return "室内家居"
        case .neon_night:  return "夜晚霓虹"
        case .unknown:     return "未知"
        }
    }

    var icon: String {
        switch self {
        case .coffee_shop: return "cup.and.saucer.fill"
        case .beach:       return "figure.pool.swim"
        case .forest:      return "tree.fill"
        case .city_street: return "building.2.fill"
        case .park:        return "leaf.fill"
        case .indoor_home: return "house.fill"
        case .neon_night:  return "moon.stars.fill"
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
        case .city_street: return cityStreetPlans
        case .park:        return parkPlans
        case .indoor_home: return indoorHomePlans
        case .neon_night:  return neonNightPlans
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

    // MARK: 城市街道（3 套）
    private var cityStreetPlans: [ShootingPlan] = [
        ShootingPlan(id: "city_walk", poseName: "街头大步走", poseEmoji: "🚶‍♀️", poseDescription: "假装不经意走过，抓拍自然动态", composition: .center, frameRatio: .fullBody, voiceGuide: "在画面中心大步往前走或横排走，自然甩动手臂", posePoints: [
            "neck": CGPoint(x: 0.50, y: 0.28), "leftShoulder": CGPoint(x: 0.40, y: 0.38), "rightShoulder": CGPoint(x: 0.60, y: 0.38),
            "leftElbow": CGPoint(x: 0.35, y: 0.55), "rightElbow": CGPoint(x: 0.70, y: 0.50), "leftHip": CGPoint(x: 0.45, y: 0.60), "rightHip": CGPoint(x: 0.55, y: 0.60),
            "leftKnee": CGPoint(x: 0.40, y: 0.75), "rightKnee": CGPoint(x: 0.65, y: 0.70)
        ]),
        ShootingPlan(id: "city_lean", poseName: "靠路灯柱", poseEmoji: "🚦", poseDescription: "侧身倚靠，腿交叉拉长比例", composition: .rightThird, frameRatio: .fullBody, voiceGuide: "偏右站立，身体依靠物体，一条腿向镜头前方伸出", posePoints: [
            "neck": CGPoint(x: 0.65, y: 0.30), "leftShoulder": CGPoint(x: 0.55, y: 0.40), "rightShoulder": CGPoint(x: 0.75, y: 0.40),
            "leftHip": CGPoint(x: 0.60, y: 0.60), "rightHip": CGPoint(x: 0.70, y: 0.60), "leftAnkle": CGPoint(x: 0.50, y: 0.85), "rightAnkle": CGPoint(x: 0.70, y: 0.85)
        ]),
        ShootingPlan(id: "city_lookback", poseName: "回眸一笑", poseEmoji: "👀", poseDescription: "背对镜头走，突然折返看镜头", composition: .goldenLeft, frameRatio: .halfBody, voiceGuide: "左侧构图，身体微侧背对镜头，回头看并带一点笑容", posePoints: [
            "neck": CGPoint(x: 0.35, y: 0.30), "leftShoulder": CGPoint(x: 0.25, y: 0.42), "rightShoulder": CGPoint(x: 0.45, y: 0.38),
            "leftHip": CGPoint(x: 0.30, y: 0.65), "rightHip": CGPoint(x: 0.40, y: 0.65)
        ])
    ]

    // MARK: 公园（3 套）
    private var parkPlans: [ShootingPlan] = [
        ShootingPlan(id: "park_sit", poseName: "草坪席地", poseEmoji: "🧘‍♀️", poseDescription: "盘腿或屈膝坐在草坪上，元气满满", composition: .center, frameRatio: .fullBody, voiceGuide: "在画面中心席地而坐，抱膝或者盘腿，抬头看镜头", posePoints: [
            "neck": CGPoint(x: 0.50, y: 0.45), "leftShoulder": CGPoint(x: 0.40, y: 0.55), "rightShoulder": CGPoint(x: 0.60, y: 0.55),
            "leftHip": CGPoint(x: 0.45, y: 0.75), "rightHip": CGPoint(x: 0.55, y: 0.75), "leftKnee": CGPoint(x: 0.35, y: 0.85), "rightKnee": CGPoint(x: 0.65, y: 0.85)
        ]),
        ShootingPlan(id: "park_tree", poseName: "大树乘凉", poseEmoji: "🌳", poseDescription: "躲在树荫下，抬头感受阳光", composition: .leftThird, frameRatio: .halfBody, voiceGuide: "偏左构图，背靠大树，微微抬头看树叶的缝隙", posePoints: [
            "neck": CGPoint(x: 0.30, y: 0.30), "leftShoulder": CGPoint(x: 0.20, y: 0.42), "rightShoulder": CGPoint(x: 0.40, y: 0.42),
            "leftHip": CGPoint(x: 0.25, y: 0.65), "rightHip": CGPoint(x: 0.35, y: 0.65)
        ]),
        ShootingPlan(id: "park_sun", poseName: "手遮阳光", poseEmoji: "☀️", poseDescription: "用手挡住刺眼的阳光，氛围感强", composition: .goldenRight, frameRatio: .halfBody, voiceGuide: "右侧黄金分割点，抬起一只手挡在眼睛上方挡阳光", posePoints: [
            "neck": CGPoint(x: 0.70, y: 0.30), "leftShoulder": CGPoint(x: 0.60, y: 0.40), "rightShoulder": CGPoint(x: 0.80, y: 0.40),
            "leftElbow": CGPoint(x: 0.55, y: 0.55), "leftWrist": CGPoint(x: 0.65, y: 0.30), "rightHip": CGPoint(x: 0.75, y: 0.65)
        ])
    ]

    // MARK: 室内家居（3 套）
    private var indoorHomePlans: [ShootingPlan] = [
        ShootingPlan(id: "home_sofa", poseName: "沙发慵懒", poseEmoji: "🛋️", poseDescription: "靠在沙发里，随意放松", composition: .center, frameRatio: .halfBody, voiceGuide: "居中构图，在沙发上找个舒服的姿势靠着，很放松地看镜头", posePoints: [
            "neck": CGPoint(x: 0.50, y: 0.35), "leftShoulder": CGPoint(x: 0.35, y: 0.45), "rightShoulder": CGPoint(x: 0.65, y: 0.45),
            "leftElbow": CGPoint(x: 0.25, y: 0.50), "rightElbow": CGPoint(x: 0.75, y: 0.50), "leftHip": CGPoint(x: 0.45, y: 0.70), "rightHip": CGPoint(x: 0.55, y: 0.70)
        ]),
        ShootingPlan(id: "home_window", poseName: "窗台托腮", poseEmoji: "🪟", poseDescription: "趴在窗台上看风景，宁静自在", composition: .leftThird, frameRatio: .halfBody, voiceGuide: "在画面左侧，手肘撑在台面上托住下巴", posePoints: [
            "neck": CGPoint(x: 0.35, y: 0.40), "leftShoulder": CGPoint(x: 0.25, y: 0.50), "rightShoulder": CGPoint(x: 0.45, y: 0.50),
            "leftElbow": CGPoint(x: 0.30, y: 0.65), "leftWrist": CGPoint(x: 0.32, y: 0.45)
        ]),
        ShootingPlan(id: "home_hug", poseName: "抱枕卖萌", poseEmoji: "🧸", poseDescription: "抱紧抱枕或宠物，增加亲近感", composition: .goldenRight, frameRatio: .halfBody, voiceGuide: "在偏右的位置，双手抱住一个软萌物体在胸前", posePoints: [
            "neck": CGPoint(x: 0.70, y: 0.30), "leftShoulder": CGPoint(x: 0.60, y: 0.42), "rightShoulder": CGPoint(x: 0.80, y: 0.42),
            "leftWrist": CGPoint(x: 0.65, y: 0.55), "rightWrist": CGPoint(x: 0.75, y: 0.55)
        ])
    ]

    // MARK: 夜晚霓虹（3 套）
    private var neonNightPlans: [ShootingPlan] = [
        ShootingPlan(id: "neon_back", poseName: "霓虹背影", poseEmoji: "🌃", poseDescription: "留出大片夜景，人物作为剪影点缀", composition: .center, frameRatio: .fullBody, voiceGuide: "背对镜头站立，面朝前方的灯光，中心构图", posePoints: [
            "neck": CGPoint(x: 0.50, y: 0.40), "leftShoulder": CGPoint(x: 0.40, y: 0.48), "rightShoulder": CGPoint(x: 0.60, y: 0.48),
            "leftHip": CGPoint(x: 0.45, y: 0.65), "rightHip": CGPoint(x: 0.55, y: 0.65), "leftKnee": CGPoint(x: 0.40, y: 0.80), "rightKnee": CGPoint(x: 0.60, y: 0.80)
        ]),
        ShootingPlan(id: "neon_lookback", poseName: "借光回望", poseEmoji: "✨", poseDescription: "让店面的霓虹灯照亮侧脸", composition: .goldenLeft, frameRatio: .halfBody, voiceGuide: "站到画面左边，侧脸借旁边霓虹的灯光，有电影女主角的感觉", posePoints: [
            "neck": CGPoint(x: 0.30, y: 0.30), "leftShoulder": CGPoint(x: 0.20, y: 0.42), "rightShoulder": CGPoint(x: 0.40, y: 0.42),
            "leftHip": CGPoint(x: 0.25, y: 0.65), "rightHip": CGPoint(x: 0.35, y: 0.65)
        ]),
        ShootingPlan(id: "neon_umbrella", poseName: "夜雨撑伞", poseEmoji: "☔️", poseDescription: "如果是雨夜，透明伞是绝佳道具", composition: .rightThird, frameRatio: .fullBody, voiceGuide: "右侧站立，单手假装或真的撑伞，肩颈放松", posePoints: [
            "neck": CGPoint(x: 0.70, y: 0.35), "leftShoulder": CGPoint(x: 0.60, y: 0.45), "rightShoulder": CGPoint(x: 0.80, y: 0.45),
            "rightWrist": CGPoint(x: 0.85, y: 0.25), "leftHip": CGPoint(x: 0.65, y: 0.60), "rightHip": CGPoint(x: 0.75, y: 0.60)
        ])
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
