import CoreGraphics

// MARK: - 姿态匹配核心算法（向量夹角法）
// 使用肢体三关节角度差异衡量相似度，消除距离远近影响。
final class PoseMatcher {

    // MARK: 肢体三元组定义 (A, B, C) → 计算 ∠ABC
    static let jointsToCompare: [(String, String, String)] = [
        ("leftShoulder",  "leftElbow",  "leftWrist"),
        ("rightShoulder", "rightElbow", "rightWrist"),
        ("leftShoulder",  "leftHip",    "leftKnee"),
        ("rightShoulder", "rightHip",   "rightKnee"),
        ("neck",          "leftShoulder","leftElbow"),
        ("neck",          "rightShoulder","rightElbow")
    ]

    // MARK: 下半身关节集合（半身模式时跳过）
    static let lowerBodyJoints: Set<String> = [
        "leftHip", "rightHip",
        "leftKnee", "rightKnee",
        "leftAnkle", "rightAnkle",
        "leftFoot", "rightFoot"
    ]

    // MARK: - 向量夹角计算
    /// 计算以 center 为顶点，p1-center-p2 的夹角（0~180°）
    static func calculateAngle(p1: CGPoint, center: CGPoint, p2: CGPoint) -> Double {
        let v1 = CGVector(dx: p1.x - center.x, dy: p1.y - center.y)
        let v2 = CGVector(dx: p2.x - center.x, dy: p2.y - center.y)

        let dot  = v1.dx * v2.dx + v1.dy * v2.dy
        let mag1 = sqrt(v1.dx * v1.dx + v1.dy * v1.dy)
        let mag2 = sqrt(v2.dx * v2.dx + v2.dy * v2.dy)

        guard mag1 > 1e-6, mag2 > 1e-6 else { return 0 }

        // 使用点积公式，数值更稳定
        let cosAngle = max(-1.0, min(1.0, dot / (mag1 * mag2)))
        return acos(cosAngle) * 180.0 / .pi
    }

    // MARK: - 综合相似度评分 (0~100)
    /// - Parameters:
    ///   - current:    当前检测到的关节坐标
    ///   - preset:     预设姿势坐标
    ///   - isHalfBody: 是否为半身模式（跳过下半身关节）
    /// - Returns: 0~100 分，越高越接近预设姿势
    static func calculateSimilarity(
        current: [String: CGPoint],
        preset: [String: CGPoint],
        isHalfBody: Bool
    ) -> Double {
        var totalDiff: Double = 0
        var count = 0

        for (p1Key, centerKey, p2Key) in jointsToCompare {
            // 半身模式：跳过涉及下半身的三元组
            if isHalfBody {
                if lowerBodyJoints.contains(p1Key) ||
                   lowerBodyJoints.contains(centerKey) ||
                   lowerBodyJoints.contains(p2Key) { continue }
            }

            // 必须同时在当前帧和预设中都存在
            guard let cp1 = current[p1Key],   let cc  = current[centerKey], let cp2 = current[p2Key],
                  let pp1 = preset[p1Key],    let pc  = preset[centerKey],  let pp2 = preset[p2Key]
            else { continue }

            let currentAngle = calculateAngle(p1: cp1, center: cc, p2: cp2)
            let presetAngle  = calculateAngle(p1: pp1, center: pc, p2: pp2)

            // 容错门限：5° 以内误差忽略不计（减少噪声干扰）
            let rawDiff = abs(currentAngle - presetAngle)
            let diff = max(0, rawDiff - 5.0)

            totalDiff += diff
            count += 1
        }

        guard count > 0 else { return 0 }

        // 平均误差 / 90° 作为惩罚系数（90° = 满分扣完）
        let penalty = (totalDiff / Double(count)) / 90.0 * 100.0
        return max(0, min(100, 100 - penalty))
    }
}
