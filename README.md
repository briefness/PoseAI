# PoseAI — AI 摄影师姿势引导

> 基于 Vision + CoreML 的实时姿势匹配 iOS App

## 功能概览

| 功能 | 技术实现 |
|------|---------|
| 实时人体骨骼检测 | `VNDetectHumanBodyPoseRequest` (30fps) |
| 场景语义识别 | `MobileNetV2` CoreML 模型 (ImageNet 1000类, 0.5fps) |
| 姿势相似度评分 | 向量夹角算法 + 5° 容错门限 |
| 半身模式自动切换 | 下半身关节置信度动态判定 |
| 防抖平滑 | 低通滤波 (旧值×0.7 + 新值×0.3) |
| 前后置镜头适配 | X 轴镜像自动修正 |
| 触感反馈 | `UIImpactFeedbackGenerator` (1.5s 冷却) |
| 内存管理 | `autoreleasepool` 逐帧释放 `CVPixelBuffer` |

---

## 项目结构

```
PoseAI/
├── PoseAI.xcodeproj/
│   ├── project.pbxproj
│   └── xcshareddata/xcschemes/PoseAI.xcscheme
└── PoseAI/
    ├── PoseAIApp.swift       # App 入口
    ├── ContentView.swift     # 主界面：Canvas 骨骼绘制 + HUD
    ├── Models.swift          # Pose / SceneType / 场景分类协议
    ├── PoseMatcher.swift     # 核心算法：向量夹角相似度
    ├── VisionService.swift   # AI 调度：姿态识别 + 场景分类
    ├── CameraManager.swift   # AVFoundation 摄像头管理
    ├── Info.plist            # 摄像头权限声明
    └── Assets.xcassets/
```

---

## 运行前准备

### 1. 必须：连接 iPhone 真机
Vision 框架的人体姿势检测 **不支持模拟器**，必须使用 iPhone 真机。

### 2. 可选（推荐）：添加 MobileNetV2 场景识别模型
若不添加模型，App 会降级为 Mock 场景提供者（自动轮换场景，功能正常）。

从 Apple Developer 官方页面下载模型：
```
https://developer.apple.com/machine-learning/models/
搜索：MobileNetV2
```

将下载的 `MobileNetV2.mlmodel` 拖入 Xcode 项目的 `PoseAI/` 文件夹，
确认 **Target Membership → PoseAI** 已勾选。

### 3. 设置 Bundle ID
在 Xcode → Target → Signing & Capabilities 中：
- 设置你的 **Team**
- 修改 **Bundle Identifier**（如：`com.yourname.poseai`）

---

## 编译 & 运行

```bash
# 用 Xcode 打开（推荐）
open /Users/lucas/Desktop/photo/PoseAI/PoseAI.xcodeproj
```

选择真机设备 → `⌘R` 运行。

---

## 使用说明

1. 首次启动会请求摄像头权限，点击「允许」
2. 屏幕上半透明**白色骨骼**为推荐姿势，彩色骨骼为你的实时姿势
3. 右上角百分比 = 当前匹配度：
   - 🟢 绿色 > 80%：很好
   - 🟡 黄色 50~80%：继续调整
   - 🔴 红色 < 50%：参考白色轮廓
4. 匹配度 > 85% 时：快门按钮**高亮激活** + 震动提示
5. 左下角旋转按钮切换前后置摄像头
6. 右下角 scope 按钮手动切换场景（咖啡馆 / 海滩 / 森林）

---

## 架构要点

### 为什么用向量夹角而非坐标差？
坐标差受拍摄距离影响，近距离关节点间距大 → 分数低。
夹角算法只关心肢体方向，与用户距离摄像头的远近无关，更公平准确。

### 低通滤波参数选择
`score = score × 0.7 + newScore × 0.3`
- α = 0.3 响应速度与平滑度的最佳经验值
- 太小 (α=0.1)：平滑但反应慢，用户感知滞后
- 太大 (α=0.8)：即时但抖动，UX 体验差

### `autoreleasepool` 必要性
`CMSampleBuffer → CVPixelBuffer` 在 30fps 下每秒创建 30 个对象，
不手动释放会在几十秒内导致内存暴涨，最终被系统 Kill。

---

## 最低系统要求

- iOS 16.0+
- Xcode 15.0+
- iPhone（Vision 姿态识别需要 A12 仿生芯片或更新）
# PoseAI
