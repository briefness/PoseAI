# PoseAI — AI 拍照构图助手

> 让拍照小白也能拍出好构图 —— 基于 Vision + CoreML 的实时场景感知姿势引导 iOS App

---

## 产品理念

1. **先扫背景**：把手机对准拍摄环境，App 自动识别场景（咖啡馆 / 海边 / 森林 / 室内通用）
2. **给出方案**：根据背景推荐 2-3 套完整拍摄方案（姿势 + 构图位置 + 人物比例 + 原因说明）
3. **站进剪影**：按底部方案卡片选择，人物站入对应剪影位置，对齐后自动拍照

不需要懂摄影，跟着 App 引导，拍出有构图感的照片。

---

## 功能概览

| 功能 | 技术实现 |
|------|---------|
| 实时人体骨骼检测 | `VNDetectHumanBodyPoseRequest` (30fps) |
| 背景场景识别 | `MobileNetV2` CoreML + top-5 投票 + 关键词扩充 (2s 间隔) |
| 场景识别防抖 | 连续 2 帧一致才触发切换，避免背景变化误跳 |
| 姿势相似度评分 | 向量夹角算法 + 5° 容错门限 |
| 多套推荐方案 | 每个场景 3 套 ShootingPlan（姿势 + 构图 + 比例） |
| 动态构图剪影 | 剪影大小随 FrameRatio 变化，位置随 CompositionRule 偏移 |
| 三分法辅助线 | 透明度 8% 的构图引导线（不干扰主界面） |
| 半身模式自动切换 | 下半身关节置信度动态判定 |
| 防抖平滑 | 低通滤波 (旧值×0.7 + 新值×0.3) |
| 自动快门 | 匹配度 > 85% 稳定 0.8 秒后自动拍照 |
| 前后置镜头适配 | X 轴镜像自动修正 |
| 俯拍角度警告 | CoreMotion 检测，防止直男俯拍丑角度 |
| 识别降级容错 | 模型加载失败 → Mock；8 秒未识别 → 通用方案 |
| 内存管理 | `autoreleasepool` 逐帧释放 `CVPixelBuffer` |

---

## 项目结构

```
PoseAI/
├── PoseAI.xcodeproj/
└── PoseAI/
    ├── PoseAIApp.swift       # App 入口
    ├── ContentView.swift     # 主界面 + 所有 UI 组件
    │                         #   ├── PlanPickerView     底部方案卡片选择器
    │                         #   ├── SilhouetteGuideOverlay  动态剪影引导
    │                         #   ├── CompositionGuideLines   三分法辅助线
    │                         #   └── PoseGuideSheet     帮助面板
    ├── Models.swift          # 核心数据模型
    │                         #   ├── ShootingPlan       完整拍摄方案
    │                         #   ├── FrameRatio         人物比例（全身/半身/特写）
    │                         #   ├── CompositionRule    构图规则（居中/三分/黄金）
    │                         #   ├── SceneType          场景类型
    │                         #   └── PoseLibrary        9 套内置方案（3场景×3套）
    ├── PoseMatcher.swift     # 核心算法：向量夹角相似度
    ├── VisionService.swift   # AI 调度：姿态识别 + 场景分类 + 防抖
    ├── CameraManager.swift   # AVFoundation 摄像头 + CoreMotion 陀螺仪
    ├── Info.plist            # 摄像头 / 相册权限声明
    └── Assets.xcassets/
```

---

## 运行前准备

### 1. 必须：连接 iPhone 真机
Vision 框架的人体姿势检测**不支持模拟器**，必须使用 iPhone 真机（A12 及以上）。

### 2. 推荐：添加 MobileNetV2 场景识别模型
从 Apple Developer 官方页面下载：
```
https://developer.apple.com/machine-learning/models/
搜索：MobileNetV2
```
将 `MobileNetV2.mlmodel` 拖入 Xcode 项目 `PoseAI/` 文件夹，确认 Target Membership 已勾选。

> **无模型时的降级策略：**
> - 模型加载失败 → 自动切换为 Mock 场景提供者（依次轮换三个场景）
> - 摄像头无法识别背景（8 秒超时）→ 自动进入咖啡馆通用方案

### 3. 配置签名
Xcode → Target → Signing & Capabilities：
- 设置你的 **Team**
- 修改 **Bundle Identifier**（如：`com.yourname.poseai`）

---

## 编译 & 运行

```bash
open /path/to/PoseAI/PoseAI.xcodeproj
```

选择真机 → `⌘R` 运行。

---

## 使用流程

```
① 打开 App → 屏幕显示「正在分析背景」
       ↓
② 把手机对准背景（不需要人在画面里）
       ↓
③ 识别到场景 → 自动推荐方案 + 剪影淡入 + 语音播报
   （8 秒未识别 → 自动进入通用方案）
       ↓
④ 底部卡片选择心仪方案（左右滑动）
       ↓
⑤ 站入剪影位置，对准姿势
       ↓
⑥ 匹配度 > 85% 保持 0.8 秒 → 自动拍照！
```

### 底部方案卡片说明

每张卡片展示：
- **姿势名** + 描述（为什么这个姿势好看）
- **构图标签**：居中 / 三分左 / 三分右 / 黄金左 / 黄金右
- **比例标签**：全身 / 半身 / 特写

点击卡片后，剪影位置和大小会动画平滑切换，同时语音播报该方案的构图原因。

---

## 内置方案库

| 场景 | 方案 | 构图 | 比例 |
|------|------|------|------|
| 咖啡馆 | 侧身靠墙 | 黄金左 | 半身 |
| 咖啡馆 | 双手捧杯 | 居中 | 半身 |
| 咖啡馆 | 望向窗外 | 三分右 | 全身 |
| 海边 | 张开双臂 | 居中 | 全身 |
| 海边 | 单手遮阳 | 三分左 | 半身 |
| 海边 | 踮脚望远 | 黄金右 | 全身 |
| 森林 | 倚树而立 | 黄金右 | 全身 |
| 森林 | 蹲下仰拍 | 居中 | 半身 |
| 森林 | 穿越步伐 | 三分左 | 全身 |

---

## 架构要点

### 数据驱动：ShootingPlan

所有 UI 状态由当前选中的 `ShootingPlan` 驱动：

```swift
struct ShootingPlan {
    let poseName: String          // "侧身靠墙"
    let poseDescription: String   // "为什么好看"
    let composition: CompositionRule // 水平偏移量
    let frameRatio: FrameRatio    // 剪影高度比
    let voiceGuide: String        // TTS 播报话术
    let posePoints: [String: CGPoint] // 骨骼关键点（用于匹配）
}
```

### 场景识别：三层策略

```
top-5 置信度投票（关键词加权）
        ↓ 无命中
top-1 置信度兜底（> 0.05 → 咖啡馆通用）
        ↓ 8 秒超时
强制进入通用方案（用户可手动切换场景）
```

### 为什么用向量夹角而非坐标差？

坐标差受拍摄距离影响：距离近时关节点间距大 → 分数低。
夹角算法只关心肢体方向，与距离无关，更公平准确。

### 低通滤波参数

```swift
score = score × 0.7 + newScore × 0.3  // α = 0.3
```
响应速度与平滑度的最佳经验值，太小滞后，太大抖动。

### `autoreleasepool` 必要性

30fps 下每秒创建 30 个 `CVPixelBuffer`，不手动释放会在几十秒内内存暴涨被系统 Kill。

---

## 最低系统要求

- iOS 16.0+
- Xcode 15.0+
- iPhone（A12 仿生芯片或更新，Vision 人体姿态识别硬件要求）
