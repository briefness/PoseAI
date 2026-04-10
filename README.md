# PoseAI — AI 拍照构图助手

> 让拍照小白也能拍出好构图 —— 基于 Vision + CoreML 的实时场景感知姿势引导 iOS App

---

## 产品理念

1. **先扫背景**：把手机对准拍摄环境，App 自动识别场景（咖啡馆 / 海边 / 森林 / 城市街道 / 公园 / 室内家居 / 夜晚霓虹）
2. **给出方案**：根据背景推荐 3 套完整拍摄方案（姿势 + 构图位置 + 人物比例 + 原因说明）
3. **站进剪影**：人物站入对应剪影位置，剪影自动跟随用户实际体型缩放，对齐后自动拍照

不需要懂摄影，跟着 App 引导，拍出有构图感的照片。

---

## 功能概览

### 核心能力

| 功能 | 技术实现 |
|------|---------|
| 实时人体骨骼检测 | `VNDetectHumanBodyPoseRequest` (Vision, ~30fps) |
| 背景场景识别 | `MobileNetV2` CoreML + top-5 投票 + 关键词扩充（2s 节流） |
| 场景识别防抖 | 连续 2 帧一致才触发切换，避免背景变化误跳 |
| 姿势相似度评分 | **向量夹角算法**（体型无关）+ 5° 容错门限 |
| 剪影自适应体型 | Vision 实时包围盒驱动剪影大小 / 位置跟随用户实际身高 |
| 7 大场景 × 3 套方案 | 21 套 ShootingPlan（姿势 + 构图 + 比例），覆盖日常拍摄场景 |
| 动态构图剪影 | 剪影大小随 FrameRatio 变化，位置随 CompositionRule 偏移 |
| 三分法辅助线 | 透明度 6% 的构图引导线（Canvas 绘制，不干扰主界面） |
| 半身模式自动切换 | 下半身关节平均置信度动态判定 |
| 防抖平滑 | 低通滤波（旧值×0.7 + 新值×0.3） |
| 自动快门 | 匹配度 > 85% 稳定 0.8 秒后自动拍照 |
| 前后置镜头适配 | X 轴镜像自动修正（关节坐标 + 预览层） |
| 俯拍角度警告 | `CoreMotion` 检测俯仰角，防止俯拍出显矮角度 |
| 识别降级容错 | 模型加载失败 → Mock；8 秒未识别 → 自动进入咖啡馆通用方案 |
| 内存安全 | `autoreleasepool` 逐帧释放 `CVPixelBuffer`，防止 30fps 内存暴涨 |

### 拍摄增强

| 功能 | 说明 |
|------|------|
| 倒计时自拍 | 3s / 5s / 10s 循环切换，大字倒计时显示 |
| 连拍模式 | 匹配后自动连拍 3 张，进入横向选片回顾页 |
| 暗光环境提示 | 有效关节点 < 4 时触发黄色 Banner，5 秒节流 |
| 姿势智能推荐 | 0.5s 节流全方案打分，高出 8 分且 > 15 才切换（手动选择后 8s 冷却） |
| 拍摄历史回顾 | Session 内拍摄照片底部缩略图，随时翻看 |

### 分享 & 商业化

| 功能 | 说明 |
|------|------|
| 社交分享 | 一键分享带「Shot on PoseAI」品牌水印的照片，`UIActivityViewController` 全生态覆盖 |
| Onboarding 引导 | 首次启动 3 步动画引导，`AppStorage` 记录仅展示一次 |
| 隐私政策合规 | Onboarding 内置必读 & 必勾隐私协议，连接外部政策文档 |
| Pro 内购 | 免费版（单次连拍 + 强制水印）/ Pro 版（全场景解锁 + 阵发连拍 + 免水印），`PaywallView` 主动阻断 |

### UI 设计

磨砂玻璃底栏 + 暖金配色 + 弹簧动画 + 分数环渐变，打造精致拍摄体验。

---

## 项目结构

```
PoseAI/
├── PoseAI.xcodeproj/
├── README.md
├── tasks/
│   ├── todo.md                   # 开发路线图 & 执行记录
│   └── lessons.md                # 经验沉淀
└── PoseAI/
    ├── PoseAIApp.swift           # App 入口
    ├── ContentView.swift         # 主界面 + 所有 UI 组件
    │                             #   ├── Design               统一设计语言（颜色/圆角/材质）
    │                             #   ├── PlanPickerView        底部方案卡片选择器
    │                             #   ├── SilhouetteGuideOverlay 自适应剪影引导（跟随体型）
    │                             #   ├── ScanCornerLines       扫描框四角修饰线
    │                             #   ├── CompositionGuideLines 三分法辅助线
    │                             #   ├── PhotoPreviewView      拍摄预览 + 连拍选片
    │                             #   ├── PaywallView           Pro 内购全屏推广页
    │                             #   └── PoseGuideSheet        帮助面板
    ├── OnboardingView.swift      # 首次启动引导（3 步动画 + 隐私协议）
    ├── Models.swift              # 核心数据模型
    │                             #   ├── ShootingPlan          完整拍摄方案
    │                             #   ├── FrameRatio            人物比例（全身/半身/特写）
    │                             #   ├── CompositionRule       构图规则（居中/三分/黄金）
    │                             #   ├── SceneType             7 大场景类型 + 方案路由
    │                             #   ├── PoseLibrary           21 套内置方案（7场景×3套）
    │                             #   ├── MobileNetV2SceneProvider CoreML 场景分类
    │                             #   └── MockSceneProvider     模拟器降级方案
    ├── PoseMatcher.swift         # 核心算法：向量夹角相似度评分
    ├── VisionService.swift       # AI 调度：姿态识别 + 场景分类 + 防抖 + 包围盒输出
    ├── CameraManager.swift       # AVFoundation 摄像头 + CoreMotion 陀螺仪
    ├── MobileNetV2.mlmodel       # 场景识别模型（Apple 官方）
    ├── Poses.json                # 姿势骨骼数据定义（热更新支持）
    ├── Resources/                # 静态资源（音效、图片等）
    ├── Info.plist                # 摄像头 / 相册权限声明
    └── Assets.xcassets/
```

---

## 运行前准备

### 1. 必须：连接 iPhone 真机

Vision 框架的人体姿势检测**不支持模拟器**，必须使用 iPhone 真机（A12 仿生及以上）。

### 2. 推荐：配置 MobileNetV2 场景识别模型

从 Apple Developer 官方页面下载：
```
https://developer.apple.com/machine-learning/models/
搜索：MobileNetV2
```
将 `MobileNetV2.mlmodel` 拖入 Xcode 项目 `PoseAI/` 文件夹，确认 Target Membership 已勾选。

> **无模型时的降级策略：**
> - 模型加载失败 → 自动切换为 Mock 场景提供者（依次轮换场景）
> - 摄像头 8 秒内未识别背景 → 自动进入咖啡馆通用方案，用户可手动切换

### 3. 配置签名

Xcode → Target → Signing & Capabilities：
- 设置你的 **Team**
- 修改 **Bundle Identifier**（如：`com.yourname.poseai`）

---

## 编译 & 运行

```bash
open PoseAI.xcodeproj
```

选择真机 → `⌘R` 运行。

---

## 使用流程

```
① 首次打开 → Onboarding 三步引导 + 同意隐私政策
       ↓
② 进入拍摄 → 屏幕显示扫描动画「识别场景中…」
       ↓
③ 把手机对准背景（不需要人在画面里）
       ↓
④ 识别到场景 → 自动推荐方案 + 剪影淡入 + 语音播报
   （8 秒未识别 → 自动进入通用方案）
       ↓
⑤ 底部卡片选择心仪方案（左右滑动）
       ↓
⑥ 站入剪影位置 —— 剪影会自动跟随你的实际身高缩放
       ↓
⑦ 摆出目标姿势，右上角分数环升高
       ↓
⑧ 匹配度 > 85% 保持 0.8 秒 → 自动拍照（连拍模式自动 3 连拍）💥
       ↓
⑨ 预览照片 → 保存 / 重拍 / 带水印一键分享
```

### 底部方案卡片说明

每张卡片展示：
- **姿势** emoji + 名称 + 效果描述
- **构图标签**：居中 / 三分左 / 三分右 / 黄金左 / 黄金右
- **比例标签**：全身 / 半身 / 特写

点击卡片后，剪影位置、大小平滑切换，同时语音播报该方案的构图建议。

---

## 内置方案库（7 场景 × 3 套 = 21 套方案）

| 场景 | 方案 | 构图 | 比例 |
|------|------|------|------|
| ☕ 咖啡馆 | 侧身靠墙 | 黄金左 | 半身 |
| ☕ 咖啡馆 | 双手捧杯 | 居中   | 半身 |
| ☕ 咖啡馆 | 望向窗外 | 三分右 | 全身 |
| 🏖️ 海边   | 张开双臂 | 居中   | 全身 |
| 🏖️ 海边   | 单手遮阳 | 三分左 | 半身 |
| 🏖️ 海边   | 踮脚望远 | 黄金右 | 全身 |
| 🌲 森林   | 倚树而立 | 黄金右 | 全身 |
| 🌲 森林   | 蹲下仰拍 | 居中   | 半身 |
| 🌲 森林   | 穿越步伐 | 三分左 | 全身 |
| 🏙️ 城市街道 | — | — | — |
| 🌳 公园   | — | — | — |
| 🏠 室内家居 | — | — | — |
| 🌃 夜晚霓虹 | — | — | — |

> 新增 4 大场景（城市街道、公园、室内家居、夜晚霓虹）各含 3 套方案，完整数据详见 `Models.swift` 中的 `PoseLibrary`。

---

## 架构要点

### 数据驱动：ShootingPlan

所有 UI 状态由当前选中的 `ShootingPlan` 驱动：

```swift
struct ShootingPlan {
    let poseName: String                   // "侧身靠墙"
    let poseDescription: String            // "为什么好看"
    let composition: CompositionRule       // 水平偏移量（pt）
    let frameRatio: FrameRatio             // 剪影默认高度比
    let voiceGuide: String                 // TTS 播报话术
    let posePoints: [String: CGPoint]      // 骨骼关键点（用于匹配评分）
}
```

### 剪影如何处理高矮胖瘦

系统分两层应对体型差异：

#### 层 1 — 评分算法（天然体型无关）

`PoseMatcher` 使用**关节夹角**而非坐标距离：

```
坐标距离 → 受距离远近影响（站近分低，站远分高）✗
关节夹角 → 只关心肢体方向，与体型/距离无关     ✓
```

小个子和大个子做同一个姿势，肘关节夹角相同 → 得分相同。

#### 层 2 — 剪影（实时跟随体型缩放）

```
Vision 检测到关节点
       ↓
计算人体包围盒 (minX, minY, maxX, maxY)
       ↓
补偿头部留白（+10%）→ 映射为剪影实际像素高度
       ↓
限制在方案允许范围 [50%, 130%]（防止太近/太远失控）
       ↓
Spring 动画平滑过渡（防止抖动）
```

未检测到人 → 退回方案默认尺寸，不闪跳。

### 场景识别：三层策略

```
top-5 置信度加权投票（关键词扩充，覆盖 ImageNet 更多类别）
        ↓ 无命中
top-1 置信度兜底（> 0.05 → 咖啡馆通用）
        ↓ 8 秒超时
强制进入通用方案（用户可手动选择底部方案卡片）
```

### 线程模型

```
frameQueue     (userInteractive)  → 视频帧 I/O，delegate 回调
visionQueue    (userInitiated)    → Vision / CoreML 推理计算
DispatchQueue.main                → UI 回调（points / bbox / scene）
motionManager  → .main            → 俯仰角更新（0.2s 一次）
```

### 低通滤波参数

```swift
score = score × 0.7 + newScore × 0.3   // α = 0.3
```

响应速度与平滑度的最佳经验值：α 太小滞后，太大抖动。

### `autoreleasepool` 必要性

30fps 下每秒创建 30 个 `CVPixelBuffer`，不手动释放会在数十秒内内存暴涨被系统强杀。

---

## 开发路线图

| 阶段 | 状态 | 说明 |
|------|------|------|
| **P0** 上线合规 | ✅ 已完成 | 权限文案、设置引导、竖屏锁定、Onboarding |
| **P1** 核心体验 | ✅ 已完成 | 照片预览、倒计时自拍、暗光提示、智能推荐 |
| **P2** 差异化留存 | ✅ 已完成 | 连拍选片、拍摄历史、7 场景方案库、社交水印分享 |
| **P3** 商业化 | ✅ 已完成 | 隐私协议、Pro 内购 Paywall |
| **P4** 稳定加固 | 📋 待执行 | 后台暂停、性能降级、Review Prompt、关节平滑、剪影标注 |
| **P5** 出片质感 | 📋 待执行 | 快门音效、智能裁切、留白提醒、CIFilter 调色、曝光补偿 |

> 完整任务清单及执行记录详见 [`tasks/todo.md`](tasks/todo.md)

---

## 最低系统要求

- iOS 16.0+
- Xcode 15.0+
- iPhone（A12 仿生芯片或更新，Vision 人体姿态识别硬件要求）

---

## License

MIT
